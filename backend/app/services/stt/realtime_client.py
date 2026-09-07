"""OpenAI Realtime 전사 클라이언트 (트랙 1 — 저지연 자막).

`gpt-live-transcribe` 는 WebSocket 으로 오디오를 받아 텍스트 델타를 즉시 뱉는다.
화자분리는 제공하지 않는다 — 그건 트랙 2(diarize_client)가 맡는다.

이 클라이언트가 책임지는 것:
  - 연결 수립과 세션 설정
  - PCM 을 base64 프레임으로 밀어넣기
  - 서버 이벤트를 우리 도메인 이벤트로 정규화
  - 끊기면 지수 백오프로 재연결 (자막이 영구히 멈추면 안 된다)
"""

from __future__ import annotations

import asyncio
import base64
import contextlib
import json
import random
from collections.abc import AsyncIterator, Callable
from dataclasses import dataclass
from enum import StrEnum
from typing import Any

import websockets
from websockets.asyncio.client import ClientConnection
from websockets.exceptions import ConnectionClosed, InvalidStatus

from app.core.config import settings
from app.core.errors import ConfigurationError, SpeechServiceUnavailableError
from app.core.logging import get_logger

log = get_logger(__name__)


class RealtimeEventType(StrEnum):
    PARTIAL = "partial"  # 잠정 텍스트 (계속 바뀜)
    FINAL = "final"  # 확정 텍스트
    SPEECH_STARTED = "speech_started"
    SPEECH_STOPPED = "speech_stopped"
    ERROR = "error"
    RECONNECTING = "reconnecting"
    CONNECTED = "connected"


@dataclass(slots=True)
class RealtimeEvent:
    type: RealtimeEventType
    text: str = ""
    item_id: str | None = None
    message: str | None = None
    raw: dict[str, Any] | None = None


class RealtimeTranscriber:
    """단일 라이브 세션에 대응하는 Realtime 전사 연결.

    사용법:
        async with RealtimeTranscriber() as rt:
            asyncio.create_task(pump_audio(rt))
            async for event in rt.events():
                ...
    """

    _MAX_RECONNECT_ATTEMPTS = 5
    _BASE_BACKOFF_SECONDS = 0.5
    _MAX_BACKOFF_SECONDS = 8.0
    # 오디오를 보내지 않아도 연결을 살려두는 핑 주기
    _PING_INTERVAL = 20.0

    def __init__(
        self,
        *,
        language_hints: list[str] | None = None,
        keyword_hints: list[str] | None = None,
        context_prompt: str | None = None,
        on_state_change: Callable[[str], None] | None = None,
    ) -> None:
        if not settings.openai_configured:
            raise ConfigurationError("OPENAI_API_KEY 가 설정되지 않았습니다.")

        self._language_hints = language_hints or settings.stt_language_hints
        self._keyword_hints = keyword_hints or settings.stt_keyword_hints
        self._context_prompt = context_prompt

        self._ws: ClientConnection | None = None
        self._events: asyncio.Queue[RealtimeEvent] = asyncio.Queue(maxsize=512)
        self._reader_task: asyncio.Task[None] | None = None
        self._closed = asyncio.Event()
        self._connected = asyncio.Event()
        self._reconnects = 0
        self._on_state_change = on_state_change
        # 재연결 중 유실을 줄이기 위한 최근 오디오. 길게 잡으면 중복 전사가 생긴다.
        self._send_lock = asyncio.Lock()

    # ------------------------------------------------------------- lifecycle

    async def __aenter__(self) -> RealtimeTranscriber:
        await self.connect()
        return self

    async def __aexit__(self, *exc_info: object) -> None:
        await self.close()

    @property
    def is_connected(self) -> bool:
        return self._connected.is_set() and self._ws is not None

    async def connect(self) -> None:
        await self._open_socket()
        self._reader_task = asyncio.create_task(self._read_loop(), name="realtime-reader")

    async def close(self) -> None:
        self._closed.set()
        if self._reader_task is not None:
            self._reader_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._reader_task
            self._reader_task = None
        await self._close_socket()

    async def _close_socket(self) -> None:
        self._connected.clear()
        if self._ws is not None:
            with contextlib.suppress(Exception):
                await self._ws.close()
            self._ws = None

    async def _open_socket(self) -> None:
        url = f"{settings.openai_realtime_url}?intent=transcription"
        try:
            self._ws = await websockets.connect(
                url,
                additional_headers=settings.openai_headers(),
                ping_interval=self._PING_INTERVAL,
                ping_timeout=20,
                close_timeout=5,
                max_size=8 * 1024 * 1024,
                open_timeout=15,
            )
        except InvalidStatus as exc:
            status = exc.response.status_code
            if status in (401, 403):
                log.error("realtime_auth_failed", status=status)
                raise ConfigurationError(
                    "OpenAI 인증에 실패했습니다. API 키와 Realtime 권한을 확인하세요."
                ) from exc
            log.error("realtime_handshake_failed", status=status)
            raise SpeechServiceUnavailableError from exc
        except (TimeoutError, OSError) as exc:
            log.error("realtime_connect_failed", error=str(exc))
            raise SpeechServiceUnavailableError from exc

        await self._send_session_config()
        self._connected.set()
        self._notify("connected")
        log.info("realtime_connected", model=settings.openai_realtime_model)

    def _notify(self, state: str) -> None:
        if self._on_state_change is not None:
            with contextlib.suppress(Exception):
                self._on_state_change(state)

    # ------------------------------------------------------------- config

    def _session_payload(self) -> dict[str, Any]:
        transcription: dict[str, Any] = {"model": settings.openai_realtime_model}

        # 한국어/영어 코드스위칭 상황에서 인식률을 올린다.
        #
        # 반드시 복수형 languages(배열)여야 한다. 단수 language 는 문자열 하나만
        # 받으므로 리스트를 넣으면 세션이 통째로 거부된다
        # ("Invalid type for 'session.audio.input.transcription.language'").
        # 자막이 아예 시작되지 않으므로 조용히 나빠지는 게 아니라 대놓고 죽는다.
        # 둘을 같이 보내서도 안 된다.
        if self._language_hints:
            transcription["languages"] = self._language_hints
        if self._keyword_hints:
            transcription["keywords"] = self._keyword_hints
        if self._context_prompt:
            transcription["prompt"] = self._context_prompt

        return {
            "type": "session.update",
            "session": {
                "type": "transcription",
                "audio": {
                    "input": {
                        "format": {
                            "type": "audio/pcm",
                            "rate": settings.audio_sample_rate,
                        },
                        "transcription": transcription,
                        # gpt-live-transcribe 는 turn_detection 을 받지 않는다.
                        # 넣으면 세션 설정이 통째로 거부된다
                        # ("Turn detection is not supported for this
                        # transcription model.").
                        #
                        # **그래서 서버 VAD 가 없다.** 발화를 끊어 주는 주체가
                        # 아무도 없으면 모델은 delta 만 계속 흘리고
                        # `input_audio_transcription.completed` 를 영영 보내지
                        # 않는다 — 화면에는 잠정 자막만 남고 저장되는 발화는
                        # 0건이 된다. `LivePipeline._maybe_commit_turn` 이
                        # 무음을 세어 `commit()` 을 보내는 것이 이 때문이다.
                        #
                        # 또 하나의 대가: speech_started 를 못 받아 발화 시작
                        # 시각을 알 수 없다. pipeline 이 텍스트 길이로 역산하므로
                        # 자막은 정상이지만 타임스탬프가 추정치가 된다.
                        "turn_detection": None,
                        # 마이크 잡음이 있는 실사용 환경을 가정
                        "noise_reduction": {"type": "near_field"},
                    }
                },
            },
        }

    async def _send_session_config(self) -> None:
        assert self._ws is not None
        await self._ws.send(json.dumps(self._session_payload()))

    # ------------------------------------------------------------- send

    async def send_audio(self, pcm: bytes) -> bool:
        """PCM16 청크 전송. 연결이 없으면 False (호출자가 버려도 되는 상황)."""
        if not pcm:
            return True

        async with self._send_lock:
            ws = self._ws
            if ws is None or not self._connected.is_set():
                return False
            payload = json.dumps(
                {
                    "type": "input_audio_buffer.append",
                    "audio": base64.b64encode(pcm).decode("ascii"),
                }
            )
            try:
                await ws.send(payload)
                return True
            except ConnectionClosed:
                self._connected.clear()
                return False

    async def commit(self) -> None:
        """서버 VAD 를 쓰지 않을 때 수동으로 발화 경계를 끊는다."""
        async with self._send_lock:
            if self._ws is not None and self._connected.is_set():
                with contextlib.suppress(ConnectionClosed):
                    await self._ws.send(json.dumps({"type": "input_audio_buffer.commit"}))

    # ------------------------------------------------------------- receive

    async def events(self) -> AsyncIterator[RealtimeEvent]:
        """정규화된 이벤트 스트림."""
        while not self._closed.is_set():
            try:
                event = await asyncio.wait_for(self._events.get(), timeout=1.0)
            except TimeoutError:
                continue
            yield event

    async def _read_loop(self) -> None:
        while not self._closed.is_set():
            ws = self._ws
            if ws is None:
                if not await self._reconnect():
                    return
                continue

            try:
                async for raw in ws:
                    if isinstance(raw, bytes):
                        continue
                    self._dispatch(json.loads(raw))
            except ConnectionClosed as exc:
                if self._closed.is_set():
                    return
                log.warning("realtime_closed", code=exc.code, reason=exc.reason)
                self._connected.clear()
                if not await self._reconnect():
                    return
            except json.JSONDecodeError as exc:
                log.warning("realtime_bad_json", error=str(exc))
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                log.exception("realtime_read_error", error=str(exc))
                self._connected.clear()
                if not await self._reconnect():
                    return

    def _dispatch(self, message: dict[str, Any]) -> None:
        kind = message.get("type", "")

        if kind.endswith("input_audio_transcription.delta"):
            text = message.get("delta") or message.get("text") or ""
            if text:
                self._emit(
                    RealtimeEvent(
                        type=RealtimeEventType.PARTIAL,
                        text=text,
                        item_id=message.get("item_id"),
                    )
                )

        elif kind.endswith("input_audio_transcription.completed"):
            self._emit(
                RealtimeEvent(
                    type=RealtimeEventType.FINAL,
                    text=message.get("transcript", ""),
                    item_id=message.get("item_id"),
                )
            )

        elif kind == "input_audio_buffer.speech_started":
            self._emit(RealtimeEvent(type=RealtimeEventType.SPEECH_STARTED))

        elif kind == "input_audio_buffer.speech_stopped":
            self._emit(RealtimeEvent(type=RealtimeEventType.SPEECH_STOPPED))

        elif kind == "error":
            error = message.get("error", {})
            log.error(
                "realtime_server_error",
                error_type=error.get("type"),
                code=error.get("code"),
                message=error.get("message"),
            )
            self._emit(
                RealtimeEvent(
                    type=RealtimeEventType.ERROR,
                    message=error.get("message", "알 수 없는 오류"),
                    raw=message,
                )
            )

        elif kind.endswith("transcription_session.created") or kind == "session.updated":
            log.debug("realtime_session_ready", kind=kind)

    def _emit(self, event: RealtimeEvent) -> None:
        try:
            self._events.put_nowait(event)
        except asyncio.QueueFull:
            # 소비자가 밀렸다. 가장 오래된 잠정 텍스트를 버린다 — 확정본은 지킨다.
            with contextlib.suppress(asyncio.QueueEmpty):
                self._events.get_nowait()
            with contextlib.suppress(asyncio.QueueFull):
                self._events.put_nowait(event)

    # ------------------------------------------------------------- reconnect

    async def _reconnect(self) -> bool:
        await self._close_socket()

        while self._reconnects < self._MAX_RECONNECT_ATTEMPTS and not self._closed.is_set():
            self._reconnects += 1
            delay = min(
                self._BASE_BACKOFF_SECONDS * (2 ** (self._reconnects - 1)),
                self._MAX_BACKOFF_SECONDS,
            )
            # 여러 세션이 동시에 재연결을 시도해 몰리는 것을 막는다.
            delay *= 0.75 + random.random() * 0.5  # noqa: S311 — 암호용이 아님

            log.info("realtime_reconnecting", attempt=self._reconnects, delay=round(delay, 2))
            self._emit(
                RealtimeEvent(
                    type=RealtimeEventType.RECONNECTING,
                    message=(
                        f"음성 인식 재연결 중… ({self._reconnects}/{self._MAX_RECONNECT_ATTEMPTS})"
                    ),
                )
            )
            self._notify("reconnecting")
            await asyncio.sleep(delay)

            try:
                await self._open_socket()
            except (SpeechServiceUnavailableError, ConfigurationError) as exc:
                if isinstance(exc, ConfigurationError):
                    # 키 문제는 재시도해도 소용없다.
                    self._emit(
                        RealtimeEvent(type=RealtimeEventType.ERROR, message=str(exc.message))
                    )
                    return False
                continue

            self._reconnects = 0
            self._emit(RealtimeEvent(type=RealtimeEventType.CONNECTED))
            return True

        log.error("realtime_reconnect_exhausted")
        self._emit(
            RealtimeEvent(
                type=RealtimeEventType.ERROR,
                message="음성 인식 서버에 연결하지 못했습니다. 네트워크를 확인해 주세요.",
            )
        )
        return False
