"""라이브 자막 WebSocket 엔드포인트.

프로토콜
────────
접속:  GET /api/v1/live/{session_id}/ws?ticket=<1회용 티켓>

클라이언트 → 서버
  - 바이너리 프레임: PCM16 LE, 24kHz, 모노 (설정과 일치해야 함)
  - 텍스트 프레임(JSON):
      {"type": "stop"}                    정상 종료 요청
      {"type": "ping"}                    연결 유지
      {"type": "rename_speaker", "key": "S1", "name": "엄마"}
      {"type": "recolor_speaker", "key": "S1", "color": "#FF0000"}

서버 → 클라이언트 (모두 JSON)
  {"type": "session.started",  "data": {...}}
  {"type": "caption.partial",  "data": {"text": "...", "sequence": 12}}
  {"type": "caption.final",    "data": {전체 발화 객체}}
  {"type": "caption.updated",  "data": {"sequence": 12, "speaker": {...}} }
  {"type": "speaker.added",    "data": {"key","label","color_hex","display_name"}}
  {"type": "status",           "data": {"state": "reconnecting"}}
  {"type": "error",            "data": {"code","message"}}
  {"type": "session.ended",    "data": {요약}}
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import time
import uuid
from typing import Any

from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.websockets import WebSocketState

from app.api.v1.auth import consume_ws_ticket
from app.core.config import settings
from app.core.logging import bind_contextvars, clear_contextvars, get_logger
from app.core.redis_client import acquire_live_slot, release_live_slot
from app.db.models import SessionStatus
from app.db.session import session_scope
from app.services.repositories.session_repo import (
    SessionRepository,
    SpeakerRepository,
    UtteranceRepository,
)
from app.services.stt.pipeline import LiveEvent, LivePipeline, LiveUtterance
from app.services.stt.speaker_registry import SpeakerProfile

router = APIRouter(prefix="/live", tags=["실시간 자막"])
log = get_logger(__name__)

# WebSocket 종료 코드 (RFC 6455 사설 대역 4000~4999)
WS_UNAUTHORIZED = 4001
WS_SESSION_NOT_FOUND = 4004
WS_TOO_MANY_SESSIONS = 4029
WS_SERVER_ERROR = 4500
WS_IDLE_TIMEOUT = 4408
WS_MAX_DURATION = 4409


class LiveConnection:
    """WS 연결 하나의 상태와 수명주기."""

    def __init__(
        self,
        websocket: WebSocket,
        *,
        user_id: uuid.UUID,
        session_id: uuid.UUID,
        diarize_client: Any,
        emotion_classifier: Any,
    ) -> None:
        self._ws = websocket
        self._user_id = user_id
        self._session_id = session_id
        self._diarize = diarize_client
        self._emotion = emotion_classifier

        self._pipeline: LivePipeline | None = None
        self._send_lock = asyncio.Lock()
        self._last_audio_at = time.monotonic()
        self._started_at = time.monotonic()
        self._closing = False
        # 화자 key → DB speaker id. 발화 저장 시 FK 를 채우는 데 쓴다.
        self._speaker_ids: dict[str, uuid.UUID] = {}
        self._bytes_received = 0

    # ================================================================ send

    async def send(self, event: LiveEvent) -> None:
        if self._closing or self._ws.client_state is not WebSocketState.CONNECTED:
            return
        async with self._send_lock:
            with contextlib.suppress(RuntimeError, WebSocketDisconnect):
                await self._ws.send_json(event.to_json())

    async def send_error(self, code: str, message: str) -> None:
        from app.services.stt.pipeline import LiveEventType

        await self.send(LiveEvent(LiveEventType.ERROR, {"code": code, "message": message}))

    # ================================================================ persist

    async def _persist_speaker(self, profile: SpeakerProfile) -> None:
        """새 화자를 DB 에 만들고 id 를 기억한다."""
        async with session_scope() as db:
            record = await SpeakerRepository(db).upsert(
                session_id=self._session_id,
                label=profile.label,
                color_hex=profile.color_hex,
                display_name=profile.display_name,
            )
            self._speaker_ids[profile.key] = record.id

    async def _persist_utterances(self, batch: list[LiveUtterance]) -> None:
        """발화 배치를 upsert 한다.

        같은 발화가 텍스트 확정 → 화자 확정 → 톤 확정 순으로 세 번 올라오므로
        PK 기준 upsert 로 처리한다.
        """
        if not batch:
            return

        rows = [
            {
                "id": u.id,
                "session_id": self._session_id,
                "speaker_id": self._speaker_ids.get(u.speaker_key) if u.speaker_key else None,
                "sequence": u.sequence,
                "text": u.text,
                "start_ms": u.start_ms,
                "end_ms": u.end_ms,
                "tone": u.tone,
                "tone_confidence": u.tone_confidence,
                "tone_basis": u.tone_basis,
                "intensity": u.intensity,
                "loudness_dbfs": u.loudness_dbfs,
                "pitch_hz": u.pitch_hz,
                "speech_rate": u.speech_rate,
                "is_final": True,
                "speaker_resolved": u.speaker_resolved,
                "is_bookmarked": False,
            }
            for u in batch
        ]

        async with session_scope() as db:
            await UtteranceRepository(db).upsert_many(rows)

    async def _finalize_session(self, db: AsyncSession, status: SessionStatus) -> None:
        if self._pipeline is None:
            return

        summary = self._pipeline._summary()

        # 한 줄도 안 잡혔으면 기록에 남길 것이 없다. 자막을 켰다 껐을 뿐인데
        # 빈 대화가 쌓이면 기록 목록이 금방 못 쓰게 된다.
        if summary.utterance_count == 0 and await SessionRepository(db).discard_if_empty(
            self._session_id
        ):
            log.info(
                "live_session_discarded_empty",
                session_id=str(self._session_id),
                duration_seconds=round(summary.duration_seconds, 1),
            )
            return

        await SessionRepository(db).finalize(
            self._session_id,
            utterance_count=summary.utterance_count,
            speaker_count=summary.speaker_count,
            duration_seconds=summary.duration_seconds,
            dominant_tone=summary.dominant_tone,
            preview_text=summary.preview_text,
            status=status,
        )

        # 화자별 집계도 채운다.
        speakers = SpeakerRepository(db)
        for profile in self._pipeline.speakers:
            speaker_id = self._speaker_ids.get(profile.key)
            if speaker_id is not None:
                await speakers.bump_stats(
                    speaker_id,
                    utterances=profile.utterance_count,
                    seconds=profile.total_speaking_seconds,
                )

    # ================================================================ run

    async def run(self) -> None:
        self._pipeline = LivePipeline(
            session_id=self._session_id,
            emit=self.send,
            diarize_client=self._diarize,
            emotion_classifier=self._emotion,
            persist_utterances=self._persist_utterances,
            persist_speaker=self._persist_speaker,
        )

        try:
            await self._pipeline.start()
        except Exception as exc:
            log.exception("pipeline_start_failed", error=str(exc))
            await self.send_error(
                "PIPELINE_START_FAILED",
                "음성 인식을 시작하지 못했습니다. 잠시 후 다시 시도해 주세요.",
            )
            await self._close(WS_SERVER_ERROR, "pipeline start failed")
            return

        watchdog = asyncio.create_task(self._watchdog(), name="live-watchdog")
        try:
            await self._receive_loop()
        finally:
            watchdog.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await watchdog

    async def _receive_loop(self) -> None:
        assert self._pipeline is not None

        while True:
            try:
                message = await self._ws.receive()
            except (WebSocketDisconnect, RuntimeError):
                log.info("live_client_disconnected", session_id=str(self._session_id))
                await self._teardown(SessionStatus.ABANDONED, graceful=False)
                return

            if message["type"] == "websocket.disconnect":
                await self._teardown(SessionStatus.ABANDONED, graceful=False)
                return

            if (payload := message.get("bytes")) is not None:
                if not await self._handle_audio(payload):
                    return
            elif (text := message.get("text")) is not None and not await self._handle_control(text):
                return

    async def _handle_audio(self, payload: bytes) -> bool:
        assert self._pipeline is not None

        if len(payload) > settings.max_audio_frame_bytes:
            log.warning(
                "live_frame_too_large",
                session_id=str(self._session_id),
                bytes=len(payload),
            )
            await self.send_error("FRAME_TOO_LARGE", "오디오 프레임이 너무 큽니다.")
            return True

        self._last_audio_at = time.monotonic()
        self._bytes_received += len(payload)

        try:
            await self._pipeline.push_audio(payload)
        except Exception as exc:  # noqa: BLE001 — 한 프레임 실패로 세션을 끊지 않는다
            log.warning("live_audio_push_failed", error=str(exc))
        return True

    async def _handle_control(self, raw: str) -> bool:
        assert self._pipeline is not None

        try:
            message: dict[str, Any] = json.loads(raw)
        except json.JSONDecodeError:
            await self.send_error("BAD_MESSAGE", "잘못된 메시지 형식입니다.")
            return True

        kind = message.get("type")

        if kind == "stop":
            await self._teardown(SessionStatus.ENDED, graceful=True)
            await self._close(1000, "session ended")
            return False

        if kind == "ping":
            from app.services.stt.pipeline import LiveEventType

            await self.send(LiveEvent(LiveEventType.STATUS, {"state": "pong"}))
            return True

        if kind == "rename_speaker":
            key, name = message.get("key"), message.get("name")
            if isinstance(key, str) and isinstance(name, str) and name.strip():
                await self._rename_speaker(key, name.strip()[:60])
            return True

        if kind == "recolor_speaker":
            key, color = message.get("key"), message.get("color")
            if isinstance(key, str) and isinstance(color, str):
                await self._recolor_speaker(key, color)
            return True

        await self.send_error("UNKNOWN_COMMAND", f"알 수 없는 명령입니다: {kind}")
        return True

    async def _rename_speaker(self, key: str, name: str) -> None:
        assert self._pipeline is not None
        profile = self._pipeline.speaker_for(key)
        if profile is None:
            return

        profile.display_name = name
        if speaker_id := self._speaker_ids.get(key):
            async with session_scope() as db:
                await SpeakerRepository(db).update(
                    speaker_id, self._user_id, {"display_name": name}
                )

        from app.services.stt.pipeline import LiveEventType

        await self.send(
            LiveEvent(
                LiveEventType.SPEAKER_ADDED,
                {
                    "key": profile.key,
                    "label": profile.label,
                    "color_hex": profile.color_hex,
                    "display_name": profile.display_name,
                },
            )
        )

    async def _recolor_speaker(self, key: str, color: str) -> None:
        import re

        if not re.fullmatch(r"#[0-9A-Fa-f]{6}", color):
            await self.send_error("BAD_COLOR", "색상 형식이 올바르지 않습니다 (#RRGGBB).")
            return

        assert self._pipeline is not None
        profile = self._pipeline.speaker_for(key)
        if profile is None:
            return

        profile.color_hex = color
        if speaker_id := self._speaker_ids.get(key):
            async with session_scope() as db:
                await SpeakerRepository(db).update(speaker_id, self._user_id, {"color_hex": color})

        from app.services.stt.pipeline import LiveEventType

        await self.send(
            LiveEvent(
                LiveEventType.SPEAKER_ADDED,
                {
                    "key": profile.key,
                    "label": profile.label,
                    "color_hex": color,
                    "display_name": profile.display_name,
                },
            )
        )

    # ================================================================ watchdog

    async def _watchdog(self) -> None:
        """오디오가 끊긴 세션과 지나치게 긴 세션을 정리한다.

        둘 다 비용 문제다 — 앱이 백그라운드에서 죽었는데 연결만 남아 있으면
        OpenAI 요금이 계속 나간다.
        """
        while True:
            await asyncio.sleep(10)

            idle = time.monotonic() - self._last_audio_at
            if idle > settings.live_session_idle_timeout_seconds:
                log.info(
                    "live_idle_timeout",
                    session_id=str(self._session_id),
                    idle_seconds=round(idle),
                )
                await self.send_error("IDLE_TIMEOUT", "오디오 입력이 없어 자막을 종료합니다.")
                await self._teardown(SessionStatus.ENDED, graceful=True)
                await self._close(WS_IDLE_TIMEOUT, "idle timeout")
                return

            elapsed = time.monotonic() - self._started_at
            if elapsed > settings.live_session_max_duration_seconds:
                log.info(
                    "live_max_duration",
                    session_id=str(self._session_id),
                    elapsed_seconds=round(elapsed),
                )
                await self.send_error(
                    "MAX_DURATION", "최대 녹음 시간에 도달했습니다. 새 대화를 시작해 주세요."
                )
                await self._teardown(SessionStatus.ENDED, graceful=True)
                await self._close(WS_MAX_DURATION, "max duration")
                return

    # ================================================================ teardown

    async def _teardown(self, status: SessionStatus, *, graceful: bool) -> None:
        if self._closing:
            return
        self._closing = True

        if self._pipeline is not None:
            try:
                if graceful:
                    await self._pipeline.stop()
                else:
                    await self._pipeline.abort()
            except Exception as exc:
                log.exception("pipeline_teardown_failed", error=str(exc))

        try:
            async with session_scope() as db:
                await self._finalize_session(db, status)
        except Exception as exc:
            log.exception("session_finalize_failed", error=str(exc))

        await release_live_slot(str(self._user_id), str(self._session_id))

        log.info(
            "live_session_closed",
            session_id=str(self._session_id),
            status=status.value,
            audio_mb=round(self._bytes_received / 1_048_576, 2),
        )

    async def _close(self, code: int, reason: str) -> None:
        with contextlib.suppress(RuntimeError, WebSocketDisconnect):
            if self._ws.client_state is WebSocketState.CONNECTED:
                await self._ws.close(code=code, reason=reason)


# ===================================================================== route


@router.websocket("/{session_id}/ws")
async def live_captions(
    websocket: WebSocket,
    session_id: uuid.UUID,
    ticket: str = Query(..., description="POST /auth/ws-ticket 으로 발급받은 1회용 티켓"),
) -> None:
    # 1) 티켓 검증 — accept 전에 끝낸다.
    user_id = await consume_ws_ticket(ticket)
    if user_id is None:
        await websocket.close(code=WS_UNAUTHORIZED, reason="invalid or expired ticket")
        return

    clear_contextvars()
    bind_contextvars(user_id=str(user_id), session_id=str(session_id))

    # 2) 세션 소유권 확인
    try:
        async with session_scope() as db:
            record = await SessionRepository(db).get(session_id, user_id)
            if record.status is not SessionStatus.ACTIVE:
                await websocket.close(code=WS_SESSION_NOT_FOUND, reason="session already ended")
                return
    except Exception:  # noqa: BLE001 - 조회 실패 원인과 무관하게 404 로 닫는다
        await websocket.close(code=WS_SESSION_NOT_FOUND, reason="session not found")
        return

    # 3) 동시 세션 수 제한 — 비용 폭주 방지
    slots = await acquire_live_slot(
        str(user_id), str(session_id), settings.live_session_max_duration_seconds
    )
    if slots > settings.max_concurrent_live_sessions_per_user:
        await release_live_slot(str(user_id), str(session_id))
        await websocket.close(code=WS_TOO_MANY_SESSIONS, reason="too many live sessions")
        return

    await websocket.accept()
    log.info("live_session_opened", session_id=str(session_id))

    connection = LiveConnection(
        websocket,
        user_id=user_id,
        session_id=session_id,
        diarize_client=websocket.app.state.diarize_client,
        emotion_classifier=websocket.app.state.emotion_classifier,
    )

    try:
        await connection.run()
    except Exception as exc:
        log.exception("live_session_crashed", error=str(exc))
        await connection._teardown(SessionStatus.ABANDONED, graceful=False)
        await connection._close(WS_SERVER_ERROR, "internal error")
    finally:
        await release_live_slot(str(user_id), str(session_id))
        clear_contextvars()
