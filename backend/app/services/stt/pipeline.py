"""라이브 자막 파이프라인 — 두 트랙의 오케스트레이션.

    마이크 PCM
        │
        ├─▶ 트랙 1: Realtime WS ──▶ 즉시 자막 (화자 미정, 회색)
        │                              │
        │                              ├─▶ 운율 분석 ──▶ 글자 크기 + 임시 톤
        │                              └─▶ LLM 분류 ──▶ 톤 확정 (patch)
        │
        └─▶ 트랙 2: 창 버퍼 ──▶ diarize API ──▶ 화자 라벨 (patch)

클라이언트는 같은 자막 줄을 세 번에 걸쳐 받는다: 잠정 텍스트 → 확정 텍스트
(+운율 톤) → 화자/톤 확정. 각 단계가 앞 단계를 덮어쓰는 방식이라, 어느 단계에서
실패해도 자막 자체는 계속 흐른다. 이게 이 설계의 핵심 이점이다.
"""

from __future__ import annotations

import asyncio
import contextlib
import time
import uuid
from collections import deque
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from enum import StrEnum
from typing import Any

from app.core.config import settings
from app.core.logging import get_logger
from app.db.models import EmotionTone, ToneBasis
from app.services.audio import prosody
from app.services.audio.buffer import AudioWindow, WindowBuffer
from app.services.audio.timeline import TimelineBuffer
from app.services.emotion.classifier import (
    EmotionClassifier,
    ToneRequest,
    ToneResult,
    classify_by_prosody,
)
from app.services.stt.diarize_client import DiarizeClient
from app.services.stt.realtime_client import (
    RealtimeEvent,
    RealtimeEventType,
    RealtimeTranscriber,
)
from app.services.stt.speaker_registry import SpeakerProfile, SpeakerRegistry

log = get_logger(__name__)

# 화자 매칭에서 같은 발화로 인정할 최소 시간 겹침 비율
_MIN_TIME_OVERLAP_RATIO = 0.35
# 시간이 애매할 때 텍스트 유사도로 구제하는 하한
_MIN_TEXT_SIMILARITY = 0.5
# 화자 미확정 자막을 언제까지 붙들고 있을지 (이후엔 미상으로 확정)
_SPEAKER_RESOLUTION_TIMEOUT_MS = 45_000
# LLM 톤 분류 배치를 모으는 시간
_TONE_BATCH_WINDOW_SECONDS = 0.6
# Realtime API 가 커밋을 받아 주는 최소 오디오 길이. 이보다 짧으면
# `input_audio_buffer_commit_empty` 로 거부된다.
_MIN_COMMIT_MS = 120.0
# 종료 직전 마지막 커밋의 확정 자막을 기다려 주는 시간
_FINAL_FLUSH_TIMEOUT_SECONDS = 3.0
# 커밋 구간이 이보다 오래됐으면 짝이 어긋난 것으로 보고 버린다
_TURN_BOUNDS_MAX_LAG_MS = 8_000
# 한 줄을 화자별로 나눌 때, 각 조각이 가져야 할 최소 길이와 최소 비중.
# 스쳐 지나간 맞장구("응", 기침)까지 줄을 쪼개면 오히려 읽기 나빠진다.
# 화자분리를 이만큼 기다려도 안 오면 실시간 텍스트로라도 자막을 띄운다.
_PROVISIONAL_GRACE_MS = 20_000
_MIN_SPLIT_PART_MS = 700
_MIN_SPLIT_COVERAGE = 0.2


class LiveEventType(StrEnum):
    SESSION_STARTED = "session.started"
    CAPTION_PARTIAL = "caption.partial"
    CAPTION_FINAL = "caption.final"
    CAPTION_UPDATED = "caption.updated"
    SPEAKER_ADDED = "speaker.added"
    STATUS = "status"
    ERROR = "error"
    SESSION_ENDED = "session.ended"


@dataclass(slots=True)
class LiveEvent:
    type: LiveEventType
    data: dict[str, Any] = field(default_factory=dict)

    def to_json(self) -> dict[str, Any]:
        return {"type": self.type.value, "data": self.data}


@dataclass(slots=True)
class LiveUtterance:
    """자막 한 줄의 서버 측 상태."""

    id: uuid.UUID
    sequence: int
    text: str
    start_ms: int
    end_ms: int

    intensity: float = 0.5
    loudness_dbfs: float | None = None
    pitch_hz: float | None = None
    speech_rate: float | None = None

    tone: EmotionTone = EmotionTone.NEUTRAL
    tone_confidence: float = 0.0
    # 발화가 만들어지는 순간에는 운율 판정뿐이다. LLM 이 답하면 그때 올라간다.
    tone_basis: ToneBasis = ToneBasis.VOICE

    speaker_key: str | None = None
    speaker_resolved: bool = False
    # DB 에 이미 썼는지
    persisted: bool = False

    @property
    def duration_ms(self) -> int:
        return max(0, self.end_ms - self.start_ms)


@dataclass(slots=True)
class SessionSummary:
    utterance_count: int
    speaker_count: int
    duration_seconds: float
    dominant_tone: EmotionTone | None
    preview_text: str | None


EventSink = Callable[[LiveEvent], Awaitable[None]]
PersistUtterances = Callable[[list[LiveUtterance]], Awaitable[None]]
PersistSpeaker = Callable[[SpeakerProfile], Awaitable[None]]


class LivePipeline:
    """라이브 세션 하나의 수명주기를 관리한다.

    단일 asyncio 태스크 컨텍스트에서만 push_audio 를 호출한다고 가정한다.
    """

    def __init__(
        self,
        *,
        session_id: uuid.UUID,
        emit: EventSink,
        diarize_client: DiarizeClient,
        emotion_classifier: EmotionClassifier,
        persist_utterances: PersistUtterances | None = None,
        persist_speaker: PersistSpeaker | None = None,
        context_prompt: str | None = None,
    ) -> None:
        self._session_id = session_id
        self._emit = emit
        self._diarize = diarize_client
        self._emotion = emotion_classifier
        self._persist_utterances = persist_utterances
        self._persist_speaker = persist_speaker
        self._context_prompt = context_prompt

        self._sample_rate = settings.audio_sample_rate
        self._channels = settings.audio_channels

        self._realtime: RealtimeTranscriber | None = None
        self._registry = SpeakerRegistry(sample_rate=self._sample_rate, channels=self._channels)
        self._windows = WindowBuffer(
            sample_rate=self._sample_rate,
            channels=self._channels,
            window_seconds=settings.diarize_window_seconds,
            overlap_seconds=settings.diarize_window_overlap_seconds,
            silence_threshold_dbfs=settings.silence_threshold_dbfs,
            min_window_seconds=settings.diarize_min_window_seconds,
            early_cut_silence_ms=settings.diarize_early_cut_silence_ms,
        )
        self._timeline = TimelineBuffer(
            sample_rate=self._sample_rate, channels=self._channels, retain_seconds=45.0
        )

        self._utterances: list[LiveUtterance] = []
        self._sequence = 0
        # 현재 발화의 시작 지점 (SPEECH_STARTED 시 기록)
        self._current_start_ms: int | None = None
        self._partial_text = ""

        # 발화 경계 판단용 (`_maybe_commit_turn`)
        self._uncommitted_ms = 0.0
        self._silence_ms = 0.0
        self._had_speech = False
        # 커밋한 발화의 확정 자막이 돌아왔는지 (`_flush_pending_turn` 이 기다린다)
        self._turn_finalized = asyncio.Event()
        # 커밋한 발화의 **실제 오디오 구간**. 커밋 순서와 confirmed 도착 순서가
        # 같으므로 FIFO 로 꺼내 쓴다.
        self._pending_turns: deque[tuple[int, int]] = deque(maxlen=8)
        self._speech_start_ms: int | None = None
        self._speech_end_ms: int | None = None
        # 최근 말소리의 음량 기준(EMA). 쉼을 상대적으로 판단하는 데 쓴다.
        self._speech_level_dbfs: float | None = None
        self._last_level_dbfs: float | None = None
        # 화자분리가 아직 다루지 않은 실시간 텍스트 (start_ms, end_ms, text)
        self._provisional: list[tuple[int, int, str]] = []

        self._diarize_queue: asyncio.Queue[AudioWindow | None] = asyncio.Queue(maxsize=8)
        self._tone_queue: asyncio.Queue[LiveUtterance | None] = asyncio.Queue(maxsize=64)
        self._persist_queue: asyncio.Queue[LiveUtterance | None] = asyncio.Queue(maxsize=256)

        self._tasks: list[asyncio.Task[None]] = []
        self._started_at = 0.0
        self._running = False
        self._tone_counts: dict[EmotionTone, int] = {}

    # ================================================================ lifecycle

    async def start(self) -> None:
        self._started_at = time.monotonic()
        self._running = True

        self._realtime = RealtimeTranscriber(
            language_hints=settings.stt_language_hints,
            keyword_hints=settings.stt_keyword_hints,
            context_prompt=self._context_prompt,
        )
        await self._realtime.connect()
        self._reset_turn_tracking()

        self._tasks = [
            asyncio.create_task(self._realtime_loop(), name="pipeline-realtime"),
            asyncio.create_task(self._diarize_loop(), name="pipeline-diarize"),
            asyncio.create_task(self._tone_loop(), name="pipeline-tone"),
            asyncio.create_task(self._persist_loop(), name="pipeline-persist"),
        ]

        await self._emit(
            LiveEvent(
                LiveEventType.SESSION_STARTED,
                {
                    "session_id": str(self._session_id),
                    "sample_rate": self._sample_rate,
                    "channels": self._channels,
                },
            )
        )
        log.info("pipeline_started", session_id=str(self._session_id))

    async def stop(self) -> SessionSummary:
        """정상 종료. 남은 오디오를 마저 처리하고 요약을 돌려준다."""
        if not self._running:
            return self._summary()
        self._running = False

        # 아직 안 끊긴 마지막 발화를 확정시킨다 (큐에 종료 신호를 보내기 전에).
        await self._flush_pending_turn()

        # 남은 창을 마지막으로 한 번 더 돌린다.
        if final_window := self._windows.flush():
            with contextlib.suppress(asyncio.QueueFull):
                self._diarize_queue.put_nowait(final_window)

        # 워커들에게 종료 신호를 보내고, 큐가 비워질 시간을 준다.
        for queue in (self._diarize_queue, self._tone_queue):
            with contextlib.suppress(asyncio.QueueFull):
                queue.put_nowait(None)

        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(self._drain(), timeout=20.0)

        # 화자 미확정으로 남은 자막을 정리한다.
        await self._flush_provisional(covered_to_ms=0, force=True)

        with contextlib.suppress(asyncio.QueueFull):
            self._persist_queue.put_nowait(None)
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(self._persist_queue.join(), timeout=10.0)

        await self._shutdown_tasks()

        if self._realtime is not None:
            await self._realtime.close()
            self._realtime = None

        # 성문에 해당하는 참조 클립을 즉시 폐기한다.
        self._registry.discard_references()
        self._timeline.clear()

        summary = self._summary()
        await self._emit(
            LiveEvent(
                LiveEventType.SESSION_ENDED,
                {
                    "utterance_count": summary.utterance_count,
                    "speaker_count": summary.speaker_count,
                    "duration_seconds": round(summary.duration_seconds, 1),
                    "dominant_tone": summary.dominant_tone.value if summary.dominant_tone else None,
                },
            )
        )
        log.info(
            "pipeline_stopped",
            session_id=str(self._session_id),
            utterances=summary.utterance_count,
            speakers=summary.speaker_count,
        )
        return summary

    async def abort(self) -> None:
        """비정상 종료 (클라이언트 연결 끊김 등). 최대한 저장하고 즉시 정리한다."""
        self._running = False
        await self._flush_provisional(covered_to_ms=0, force=True)
        await self._flush_pending_persist()
        await self._shutdown_tasks()
        if self._realtime is not None:
            await self._realtime.close()
            self._realtime = None
        self._registry.discard_references()
        self._timeline.clear()
        log.info("pipeline_aborted", session_id=str(self._session_id))

    async def _drain(self) -> None:
        await self._diarize_queue.join()
        await self._tone_queue.join()

    async def _shutdown_tasks(self) -> None:
        for task in self._tasks:
            task.cancel()
        for task in self._tasks:
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await task
        self._tasks.clear()

    def _summary(self) -> SessionSummary:
        dominant: EmotionTone | None = None
        meaningful = {t: c for t, c in self._tone_counts.items() if t != EmotionTone.NEUTRAL}
        if meaningful:
            dominant = max(meaningful.items(), key=lambda kv: kv[1])[0]

        preview = next((u.text for u in self._utterances if u.text.strip()), None)
        if preview and len(preview) > 300:
            preview = preview[:297] + "…"

        return SessionSummary(
            utterance_count=len(self._utterances),
            speaker_count=self._registry.speaker_count,
            duration_seconds=self._timeline.position_ms / 1000,
            dominant_tone=dominant,
            preview_text=preview,
        )

    # ================================================================ ingest

    async def push_audio(self, pcm: bytes) -> None:
        """클라이언트에서 온 PCM16 청크를 두 트랙에 나눠 넣는다."""
        if not pcm or not self._running:
            return

        self._timeline.push(pcm)

        # 트랙 1 — 실시간. 전송 실패해도 트랙 2 는 계속 간다.
        if self._realtime is not None:
            await self._realtime.send_audio(pcm)
            await self._maybe_commit_turn(pcm)

        # 트랙 2 — 창 버퍼
        for window in self._windows.push(pcm):
            try:
                self._diarize_queue.put_nowait(window)
            except asyncio.QueueFull:
                # 화자분리가 밀렸다. 자막(트랙 1)은 계속 나가므로 이 창은 버린다.
                # 화자 라벨만 일부 비게 되고, 사용자 경험은 크게 해치지 않는다.
                log.warning(
                    "diarize_queue_full_dropping_window",
                    session_id=str(self._session_id),
                    window_start_ms=window.start_ms,
                )

    async def _maybe_commit_turn(self, pcm: bytes) -> None:
        """무음이 이어지면 발화를 끊어 확정 자막을 받아 온다.

        `gpt-live-transcribe` 는 `turn_detection` 을 거부하므로(설정을 넣으면
        세션 자체가 거부된다) **서버 VAD 가 없다.** 아무도 끊어 주지 않으면
        모델은 delta 만 계속 흘리고 `input_audio_transcription.completed` 를
        영영 보내지 않는다 — 화면에서는 말이 끝났는데도 잠정 자막(기울임체)이
        그대로 남고, 저장되는 발화는 0건이 된다.

        그래서 무음 길이를 우리가 세어 `input_audio_buffer.commit` 을 보낸다.
        """
        assert self._realtime is not None

        # PCM16 mono 기준 샘플당 2바이트.
        chunk_ms = len(pcm) / 2 / self._sample_rate * 1000
        self._uncommitted_ms += chunk_ms
        # 타임라인은 이 청크까지 이미 밀어 넣은 뒤라, 청크의 시작은 한 칸 앞이다.
        chunk_start_ms = max(0, self._timeline.position_ms - int(chunk_ms))

        if self._is_pause(pcm):
            self._silence_ms += chunk_ms
            # 쉼이 시작된 지점 = 말이 끝난 지점.
            if self._had_speech and self._speech_end_ms is None:
                self._speech_end_ms = chunk_start_ms
        else:
            self._silence_ms = 0.0
            self._speech_end_ms = None
            if not self._had_speech:
                self._speech_start_ms = chunk_start_ms
            self._had_speech = True

        # 너무 짧은 버퍼는 서버가 거부한다 (100ms 미만).
        if self._uncommitted_ms < _MIN_COMMIT_MS:
            return

        speech_ended = (
            self._had_speech and self._silence_ms >= settings.realtime_commit_silence_ms
        )

        # 이 커밋은 **잠정 자막을 끊어 주는 용도**다. 확정 자막은 화자분리
        # 트랙이 만들므로, 여기서 어디를 자르든 최종 정확도에는 영향이 없다.
        # 화면 아래 잠정 줄이 끝없이 길어지지만 않으면 된다.
        turn_too_long = self._uncommitted_ms >= settings.realtime_commit_max_turn_ms

        if not (speech_ended or turn_too_long):
            return

        self._remember_turn_bounds()
        await self._realtime.commit()
        self._reset_turn_tracking()

    def _is_pause(self, pcm: bytes) -> bool:
        """이 조각이 말 사이의 쉼인가?

        절대 임계값 하나로는 안 된다. 조용한 방에서는 잘 걸리지만 TV 가 켜져
        있거나 카페에 있으면 배경음이 임계값 위에 계속 깔려서 **쉼이 한 번도
        안 잡힌다.** 그러면 발화가 길이 상한까지 끌려가고, 여러 사람의 말이
        섞인 긴 오디오를 통째로 전사하게 되어 인식 정확도가 떨어진다.
        실제 측정에서 자막 대부분이 정확히 상한값에 걸려 있었다.

        그래서 **최근 말소리 대비**로도 판단한다. 배경음이 무엇이든, 말하다가
        멈추면 음량이 뚝 떨어진다는 사실은 변하지 않는다.
        """
        level = prosody.level_dbfs(pcm)
        self._last_level_dbfs = level

        # 절대적으로 조용하면 더 볼 것 없다.
        if level < settings.silence_threshold_dbfs:
            return True

        # 최근 말소리 기준을 아직 못 잡았으면 절대 판정만 믿는다.
        if self._speech_level_dbfs is None:
            self._speech_level_dbfs = level
            return False

        if level < self._speech_level_dbfs - settings.realtime_pause_drop_db:
            return True

        # 말소리 기준을 천천히 따라가게 한다. 급히 따라가면 쉼 직전의 작은
        # 소리에 기준이 끌려 내려가 그 뒤로 아무것도 쉼이 아니게 된다.
        self._speech_level_dbfs += 0.1 * (level - self._speech_level_dbfs)
        return False

    def _remember_turn_bounds(self) -> None:
        """방금 커밋한 발화가 **오디오의 어디였는지** 기록해 둔다.

        확정 자막은 커밋 뒤 API 왕복을 거쳐 도착하므로, 도착 시점의 타임라인
        위치는 실제 발화보다 한참 뒤다. 그 위치에서 글자 수로 시작점을 역산하면
        짧은 발화일수록 구간이 통째로 **말이 끝난 뒤의 무음**에 얹힌다.

        그러면 화자분리 세그먼트와 시간이 하나도 안 겹쳐서 화자가 영영 안 붙는다
        — 화면에는 `화자 확인 중…` 으로 남는다. 긴 문장은 역산 구간이 길어
        우연히 겹치므로, **짧은 말만 골라서 안 붙는** 형태로 나타난다.
        """
        if not self._had_speech or self._speech_start_ms is None:
            return
        end_ms = self._speech_end_ms
        if end_ms is None:
            # 무음 없이 길이 상한으로 끊긴 경우 — 지금이 곧 발화의 끝이다.
            end_ms = self._timeline.position_ms
        if end_ms > self._speech_start_ms:
            self._pending_turns.append((self._speech_start_ms, end_ms))

    def _take_turn_bounds(self) -> tuple[int, int] | None:
        """방금 도착한 확정 자막에 해당하는 오디오 구간을 꺼낸다.

        커밋 하나에 확정 자막 하나가 원칙이지만, 모델이 자막을 아예 안 돌려주는
        커밋이 있을 수 있다. 그러면 큐가 밀린 채로 계속 가므로, **지나치게 오래된
        구간은 버리고** 꺼낸다. 어긋나도 한 줄에서 끝난다.
        """
        now_ms = self._timeline.position_ms
        while self._pending_turns:
            start_ms, end_ms = self._pending_turns.popleft()
            if now_ms - end_ms <= _TURN_BOUNDS_MAX_LAG_MS:
                return start_ms, end_ms
        return None

    def _reset_turn_tracking(self) -> None:
        self._uncommitted_ms = 0.0
        self._silence_ms = 0.0
        self._had_speech = False
        self._speech_start_ms = None
        self._speech_end_ms = None
        # _speech_level_dbfs 는 일부러 남긴다 — 발화가 바뀌어도 방의 음량
        # 특성은 그대로다. 매번 지우면 발화마다 기준을 처음부터 다시 잡는다.

    async def _flush_pending_turn(self) -> None:
        """종료 직전, 아직 끊기지 않은 마지막 발화를 확정시킨다.

        커밋 없이 세션을 닫으면 **마지막 한 마디가 잠정 상태로 사라진다.**
        사용자가 방금 한 말이라 잃어버리면 가장 아쉬운 자리다.
        """
        if self._realtime is None:
            return
        if not (self._had_speech or self._partial_text):
            return
        if self._uncommitted_ms < _MIN_COMMIT_MS:
            return

        self._remember_turn_bounds()
        self._turn_finalized.clear()
        await self._realtime.commit()
        self._reset_turn_tracking()

        # 확정 자막이 돌아올 시간을 준다. 안 오면 그냥 넘어간다 — 종료가
        # 무한정 늘어지는 쪽이 더 나쁘다.
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(
                self._turn_finalized.wait(), timeout=_FINAL_FLUSH_TIMEOUT_SECONDS
            )

    # ================================================================ track 1

    async def _realtime_loop(self) -> None:
        assert self._realtime is not None
        try:
            async for event in self._realtime.events():
                await self._handle_realtime_event(event)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            log.exception("realtime_loop_crashed", error=str(exc))
            await self._emit_error("STT_STREAM_FAILED", "실시간 자막이 중단되었습니다.")

    async def _handle_realtime_event(self, event: RealtimeEvent) -> None:
        if event.type is RealtimeEventType.SPEECH_STARTED:
            self._current_start_ms = self._timeline.position_ms
            self._partial_text = ""

        elif event.type is RealtimeEventType.PARTIAL:
            self._partial_text += event.text
            await self._emit(
                LiveEvent(
                    LiveEventType.CAPTION_PARTIAL,
                    {"text": self._partial_text, "sequence": self._sequence},
                )
            )

        elif event.type is RealtimeEventType.FINAL:
            self._remember_provisional(event.text)
            # 종료 중이라면 여기서 기다리고 있다 (`_flush_pending_turn`).
            self._turn_finalized.set()

        elif event.type is RealtimeEventType.RECONNECTING:
            await self._emit(
                LiveEvent(
                    LiveEventType.STATUS,
                    {"state": "reconnecting", "message": event.message},
                )
            )

        elif event.type is RealtimeEventType.CONNECTED:
            await self._emit(LiveEvent(LiveEventType.STATUS, {"state": "connected"}))

        elif event.type is RealtimeEventType.ERROR:
            await self._emit_error("STT_ERROR", event.message or "음성 인식 오류")

    def _remember_provisional(self, text: str) -> None:
        """실시간 트랙의 확정 텍스트를 **예비로만** 들고 있는다.

        확정 자막은 화자분리 트랙이 만든다 (`_publish_segments`). 실시간 트랙은
        화자를 모르고 발화 경계도 우리가 임의로 끊어 준 것이라, 그 텍스트를
        그대로 자막으로 굳히면 두 사람의 말이 한 줄에 섞이고 문장도 자주 깨진다.

        그래도 버리지는 않는다. 화자분리가 실패하거나 늦으면 이 텍스트라도
        띄워야 한다 — 화자를 모르는 자막이 자막이 없는 것보다 낫다.
        """
        text = text.strip()
        self._partial_text = ""
        self._current_start_ms = None
        if not text:
            return

        bounds = self._take_turn_bounds()
        if bounds is None:
            end_ms = self._timeline.position_ms
            bounds = (max(0, end_ms - 3000), end_ms)

        self._provisional.append((bounds[0], bounds[1], text))

    async def _publish_segments(
        self, resolved: list[tuple[SpeakerProfile, Any]]
    ) -> None:
        """화자분리 결과를 그대로 자막 줄로 만든다.

        이 모델은 텍스트와 화자를 **함께** 돌려준다. 발화 경계도 모델이 잡은
        것이라, 실시간 트랙의 텍스트와 화자 라벨을 시간으로 짜맞추던 예전
        방식보다 훨씬 정확하다. 짜맞추는 코드가 오늘 하루 버그의 근원이었다.
        """
        for profile, segment in sorted(resolved, key=lambda ps: ps[1].start_ms):
            text = str(segment.text).strip()
            if not text:
                continue

            self._sequence += 1
            utterance = LiveUtterance(
                id=uuid.uuid4(),
                sequence=self._sequence,
                text=text,
                start_ms=segment.start_ms,
                end_ms=segment.end_ms,
                speaker_key=profile.key,
                speaker_resolved=True,
            )
            await self._apply_prosody(utterance)
            self._utterances.append(utterance)

            await self._emit(
                LiveEvent(LiveEventType.CAPTION_FINAL, self._utterance_payload(utterance))
            )
            with contextlib.suppress(asyncio.QueueFull):
                self._tone_queue.put_nowait(utterance)
            self._enqueue_persist(utterance)

    async def _flush_provisional(self, *, covered_to_ms: int, force: bool = False) -> None:
        """화자분리가 끝내 못 다룬 구간은 실시간 텍스트로라도 띄운다.

        부분 실패가 전체 실패가 되면 안 된다 — 화자분리 API 가 죽어도 자막은
        계속 흘러야 한다. 다만 화자는 모르므로 미상으로 표시한다.
        """
        if not self._provisional:
            return

        now_ms = self._timeline.position_ms
        keep: list[tuple[int, int, str]] = []

        for start_ms, end_ms, text in self._provisional:
            if end_ms <= covered_to_ms:
                # 화자분리가 이 구간을 다뤘다. 그쪽 자막이 이미 나갔다.
                continue
            if not force and now_ms - end_ms < _PROVISIONAL_GRACE_MS:
                keep.append((start_ms, end_ms, text))
                continue

            self._sequence += 1
            utterance = LiveUtterance(
                id=uuid.uuid4(),
                sequence=self._sequence,
                text=text,
                start_ms=start_ms,
                end_ms=end_ms,
                speaker_resolved=True,  # 더 기다려도 화자는 안 온다
            )
            await self._apply_prosody(utterance)
            self._utterances.append(utterance)
            log.info(
                "caption_from_realtime_fallback",
                session_id=str(self._session_id),
                sequence=utterance.sequence,
            )
            await self._emit(
                LiveEvent(LiveEventType.CAPTION_FINAL, self._utterance_payload(utterance))
            )
            with contextlib.suppress(asyncio.QueueFull):
                self._tone_queue.put_nowait(utterance)
            self._enqueue_persist(utterance)

        self._provisional = keep

    async def _apply_prosody(self, utterance: LiveUtterance) -> None:
        """발화 구간의 오디오로 세기·톤을 채운다.

        numpy 연산이라 이벤트 루프를 잡아먹지 않게 스레드로 뺀다.
        """
        pcm = self._timeline.slice(utterance.start_ms, utterance.end_ms)
        if not pcm:
            return

        features = await asyncio.to_thread(
            prosody.analyze,
            pcm,
            sample_rate=self._sample_rate,
            text=utterance.text,
        )
        utterance.intensity = features.intensity
        utterance.loudness_dbfs = features.loudness_dbfs
        utterance.pitch_hz = features.pitch_hz
        utterance.speech_rate = features.speech_rate

        # 운율 기반 임시 톤 — 즉시 화면에 반영된다.
        provisional = classify_by_prosody(features)
        utterance.tone = provisional.tone
        utterance.tone_confidence = provisional.confidence
        utterance.tone_basis = ToneBasis.VOICE

    # ================================================================ track 2

    async def _diarize_loop(self) -> None:
        while True:
            window = await self._diarize_queue.get()
            try:
                if window is None:
                    return
                await self._process_window(window)
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001 — 한 창이 실패해도 세션은 계속된다
                log.warning(
                    "diarize_window_failed",
                    session_id=str(self._session_id),
                    error=str(exc),
                    error_type=type(exc).__name__,
                )
            finally:
                self._diarize_queue.task_done()

            # 화자분리가 오래 못 따라오면 실시간 텍스트로라도 띄운다.
            with contextlib.suppress(Exception):
                await self._flush_provisional(covered_to_ms=0)

    async def _process_window(self, window: AudioWindow) -> None:
        # 무음 창은 API 를 부르지 않는다 — 비용과 오탐을 둘 다 아낀다.
        if prosody.is_silent(
            window.pcm,
            sample_rate=self._sample_rate,
            threshold_dbfs=settings.silence_threshold_dbfs,
        ):
            await self._flush_provisional(covered_to_ms=window.end_ms)
            return

        # 화자 확정 지연은 창 길이와 API 왕복의 합이다. 어느 쪽이 큰지 모르면
        # 튜닝이 추측이 되므로 둘 다 남긴다.
        started = time.monotonic()
        segments = await self._diarize.transcribe(
            window.pcm,
            sample_rate=self._sample_rate,
            channels=self._channels,
            references=self._registry.references(),
            context_prompt=self._context_prompt,
        )
        log.info(
            "diarize_window_done",
            session_id=str(self._session_id),
            window_ms=window.duration_ms,
            api_ms=int((time.monotonic() - started) * 1000),
            queued=self._diarize_queue.qsize(),
            segments=len(segments),
            # 모델이 실제로 돌려준 화자 라벨. 화자 수가 안 늘어날 때, 모델이
            # 못 가른 것인지 우리가 합친 것인지를 이 값으로만 구분할 수 있다.
            labels=sorted({s.speaker for s in segments}),
            known=[p.key for p in self._registry.profiles],
        )
        if not segments:
            await self._flush_provisional(covered_to_ms=window.end_ms)
            return

        known_before = {p.key for p in self._registry.profiles}

        resolved = self._registry.resolve_window(
            segments,
            window_pcm=window.pcm,
            window_start_ms=window.start_ms,
            overlap_ms=window.overlap_ms,
        )

        # 새로 등장한 화자를 알린다 (클라이언트가 색상 범례를 갱신한다).
        for profile in self._registry.profiles:
            if profile.key not in known_before:
                await self._announce_speaker(profile)

        await self._publish_segments(resolved)
        await self._flush_provisional(covered_to_ms=window.end_ms)

    async def _announce_speaker(self, profile: SpeakerProfile) -> None:
        await self._emit(
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
        if self._persist_speaker is not None:
            with contextlib.suppress(Exception):
                await self._persist_speaker(profile)

    async def _tone_loop(self) -> None:
        """짧은 시간 창으로 발화를 모아 한 번에 LLM 에 묻는다."""
        while True:
            first = await self._tone_queue.get()
            if first is None:
                self._tone_queue.task_done()
                return

            batch = [first]
            deadline = asyncio.get_running_loop().time() + _TONE_BATCH_WINDOW_SECONDS
            sentinel_seen = False

            while len(batch) < 8:
                remaining = deadline - asyncio.get_running_loop().time()
                if remaining <= 0:
                    break
                try:
                    item = await asyncio.wait_for(self._tone_queue.get(), timeout=remaining)
                except TimeoutError:
                    break
                if item is None:
                    sentinel_seen = True
                    self._tone_queue.task_done()
                    break
                batch.append(item)

            try:
                await self._classify_batch(batch)
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001 — 톤 실패는 자막을 막지 않는다
                log.warning("tone_batch_failed", error=str(exc))
            finally:
                for _ in batch:
                    self._tone_queue.task_done()

            if sentinel_seen:
                return

    async def _classify_batch(self, batch: list[LiveUtterance]) -> None:
        # 직전 대화 맥락을 함께 넘긴다 — 반어법·짧은 대답 판정에 필요하다.
        context = [u.text for u in self._utterances[-6:]]

        requests = [
            ToneRequest(
                text=u.text,
                prosody=prosody.ProsodyFeatures(
                    loudness_dbfs=u.loudness_dbfs or -40.0,
                    peak_dbfs=u.loudness_dbfs or -40.0,
                    intensity=u.intensity,
                    pitch_hz=u.pitch_hz,
                    pitch_std_hz=None,
                    loudness_std_db=0.0,
                    zero_crossing_rate=0.0,
                    voiced_ratio=1.0,
                    duration_seconds=u.duration_ms / 1000,
                    speech_rate=u.speech_rate,
                ),
                context=context,
            )
            for u in batch
        ]

        results: list[ToneResult] = await self._emotion.classify_batch(requests)

        for utterance, result in zip(batch, results, strict=False):
            basis = ToneBasis.VOICE if result.from_prosody_only else ToneBasis.VOICE_TEXT
            changed = (
                result.tone != utterance.tone
                or abs(result.confidence - utterance.tone_confidence) > 0.05
                # 톤이 그대로여도 근거가 올라갔으면 화면 문구가 바뀌어야 한다
                # ("목소리 톤만으로 추정" → "목소리 톤과 문장 내용으로 추정").
                or basis != utterance.tone_basis
            )
            utterance.tone = result.tone
            utterance.tone_confidence = result.confidence
            utterance.tone_basis = basis
            self._tone_counts[result.tone] = self._tone_counts.get(result.tone, 0) + 1

            if changed:
                await self._emit(
                    LiveEvent(
                        LiveEventType.CAPTION_UPDATED,
                        {
                            "sequence": utterance.sequence,
                            "id": str(utterance.id),
                            "tone": utterance.tone.value,
                            "tone_confidence": round(utterance.tone_confidence, 2),
                            "tone_basis": utterance.tone_basis.value,
                        },
                    )
                )
            self._enqueue_persist(utterance)

    # ================================================================ persist

    def _enqueue_persist(self, utterance: LiveUtterance) -> None:
        with contextlib.suppress(asyncio.QueueFull):
            self._persist_queue.put_nowait(utterance)

    async def _persist_loop(self) -> None:
        """DB 쓰기를 모아서 처리한다. 발화마다 커밋하면 DB 가 못 버틴다."""
        if self._persist_utterances is None:
            # 저장 콜백이 없으면 큐만 비운다 (테스트/드라이런).
            while True:
                item = await self._persist_queue.get()
                self._persist_queue.task_done()
                if item is None:
                    return

        pending: dict[uuid.UUID, LiveUtterance] = {}
        while True:
            try:
                item = await asyncio.wait_for(self._persist_queue.get(), timeout=2.0)
            except TimeoutError:
                if pending:
                    await self._write(list(pending.values()))
                    pending.clear()
                continue

            if item is None:
                self._persist_queue.task_done()
                if pending:
                    await self._write(list(pending.values()))
                return

            # 같은 발화가 여러 번 갱신되면 마지막 상태만 쓴다.
            pending[item.id] = item
            self._persist_queue.task_done()

            if len(pending) >= 20:
                await self._write(list(pending.values()))
                pending.clear()

    async def _write(self, batch: list[LiveUtterance]) -> None:
        if self._persist_utterances is None or not batch:
            return
        try:
            await self._persist_utterances(batch)
            for utterance in batch:
                utterance.persisted = True
        except Exception as exc:  # noqa: BLE001 — 저장 실패로 자막을 끊지 않는다
            log.error(
                "utterance_persist_failed",
                session_id=str(self._session_id),
                count=len(batch),
                error=str(exc),
            )

    async def _flush_pending_persist(self) -> None:
        batch: list[LiveUtterance] = [u for u in self._utterances if not u.persisted]
        if batch:
            await self._write(batch)

    # ================================================================ payloads

    def _speaker_payload(self, profile: SpeakerProfile | None) -> dict[str, Any] | None:
        if profile is None:
            return None
        return {
            "key": profile.key,
            "label": profile.label,
            "color_hex": profile.color_hex,
            "display_name": profile.display_name,
        }

    def _utterance_payload(self, utterance: LiveUtterance) -> dict[str, Any]:
        profile = self._registry.get(utterance.speaker_key) if utterance.speaker_key else None
        return {
            "id": str(utterance.id),
            "sequence": utterance.sequence,
            "text": utterance.text,
            "start_ms": utterance.start_ms,
            "end_ms": utterance.end_ms,
            "intensity": round(utterance.intensity, 3),
            "loudness_dbfs": round(utterance.loudness_dbfs, 1)
            if utterance.loudness_dbfs is not None
            else None,
            "tone": utterance.tone.value,
            "tone_confidence": round(utterance.tone_confidence, 2),
            "tone_basis": utterance.tone_basis.value,
            "speaker": self._speaker_payload(profile),
            "speaker_resolved": utterance.speaker_resolved,
        }

    async def _emit_error(self, code: str, message: str) -> None:
        await self._emit(LiveEvent(LiveEventType.ERROR, {"code": code, "message": message}))

    # ================================================================ accessors

    @property
    def utterances(self) -> list[LiveUtterance]:
        return self._utterances

    @property
    def speakers(self) -> list[SpeakerProfile]:
        return self._registry.profiles

    def speaker_for(self, key: str | None) -> SpeakerProfile | None:
        return self._registry.get(key) if key else None
