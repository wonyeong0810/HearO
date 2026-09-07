"""OpenAI 화자분리 전사 클라이언트 (트랙 2 — 화자 라벨 확정).

`gpt-4o-transcribe-diarize` 는 파일 단위 API 다. 실시간 엔드포인트를 지원하지
않으므로, WindowBuffer 가 잘라준 10여 초짜리 창을 WAV 로 감싸 올린다.

세션 내내 "화자 A"가 같은 사람을 가리키게 하는 것이 이 모듈의 핵심 난제다.
모델은 요청 간에 화자 정체성을 기억하지 않기 때문에, 창마다 라벨이 새로
배정된다. 해결책은 두 가지를 겹쳐 쓴다.
  1) known_speaker_references — 화자별 2~8초 참조 클립을 함께 올려
     "이 목소리는 A 다"라고 못박는다. (모델 제약: 최대 4명)
  2) 창 사이의 겹침 구간 대조 — 참조 클립이 아직 없거나 5명 이상인 경우의
     폴백. SpeakerRegistry 가 담당한다.
"""

from __future__ import annotations

import asyncio
import random
from dataclasses import dataclass
from typing import Any

import httpx

from app.core.config import settings
from app.core.errors import ConfigurationError, SpeechServiceUnavailableError, UpstreamError
from app.core.logging import get_logger
from app.services.audio.wav import make_data_url, pcm16_to_wav

log = get_logger(__name__)

# OpenAI 파일 크기 상한
_MAX_UPLOAD_BYTES = 25 * 1024 * 1024
# 30초를 넘기면 chunking_strategy 가 필수가 된다.
_CHUNKING_REQUIRED_SECONDS = 30.0


@dataclass(slots=True)
class DiarizedSegment:
    """화자가 붙은 전사 구간. 시간은 업로드한 창의 시작 기준(초)."""

    speaker: str
    text: str
    start: float
    end: float

    def shifted(self, offset_ms: int) -> DiarizedSegment:
        """세션 시작 기준 절대 시간으로 옮긴다."""
        return DiarizedSegment(
            speaker=self.speaker,
            text=self.text,
            start=self.start + offset_ms / 1000,
            end=self.end + offset_ms / 1000,
        )

    @property
    def start_ms(self) -> int:
        return int(self.start * 1000)

    @property
    def end_ms(self) -> int:
        return int(self.end * 1000)

    @property
    def duration(self) -> float:
        return max(0.0, self.end - self.start)


@dataclass(slots=True)
class SpeakerReference:
    """모델에게 넘길 화자 참조 클립."""

    name: str
    pcm: bytes


class DiarizeClient:
    """화자분리 전사 HTTP 클라이언트.

    커넥션 풀을 재사용하므로 앱 수명주기 동안 하나만 두고 공유한다.
    """

    _MAX_ATTEMPTS = 3
    _RETRY_STATUSES = frozenset({408, 429, 500, 502, 503, 504})

    def __init__(self, client: httpx.AsyncClient | None = None) -> None:
        self._client = client
        self._owns_client = client is None

    async def __aenter__(self) -> DiarizeClient:
        await self.start()
        return self

    async def __aexit__(self, *exc_info: object) -> None:
        await self.aclose()

    async def start(self) -> None:
        if self._client is None:
            self._client = httpx.AsyncClient(
                base_url=settings.openai_base_url,
                headers=settings.openai_headers(),
                timeout=httpx.Timeout(settings.openai_timeout_seconds, connect=10.0),
                limits=httpx.Limits(max_connections=20, max_keepalive_connections=10),
                http2=False,
            )

    async def aclose(self) -> None:
        if self._client is not None and self._owns_client:
            await self._client.aclose()
            self._client = None

    # ----------------------------------------------------------------- api

    async def transcribe(
        self,
        pcm: bytes,
        *,
        sample_rate: int | None = None,
        channels: int | None = None,
        references: list[SpeakerReference] | None = None,
        language: str | None = None,
        context_prompt: str | None = None,
    ) -> list[DiarizedSegment]:
        """한 창을 전사해 화자별 구간 목록을 돌려준다.

        실패해도 예외를 던지지 않고 빈 리스트를 주는 편이 나은 경우가 있지만,
        여기서는 던진다 — 호출자(pipeline)가 "화자 미확정" 상태를 유지할지
        재시도할지 판단해야 하기 때문이다.
        """
        if not settings.openai_configured:
            raise ConfigurationError("OPENAI_API_KEY 가 설정되지 않았습니다.")
        if self._client is None:
            await self.start()
        assert self._client is not None

        rate = sample_rate or settings.audio_sample_rate
        chans = channels or settings.audio_channels

        wav_bytes = pcm16_to_wav(pcm, sample_rate=rate, channels=chans)
        if len(wav_bytes) > _MAX_UPLOAD_BYTES:
            raise UpstreamError(
                "오디오 조각이 업로드 한도를 초과했습니다.",
                details={"bytes": len(wav_bytes)},
            )

        duration = len(pcm) / (2 * chans) / rate

        files: list[tuple[str, tuple[str | None, bytes | str, str | None]]] = [
            ("file", ("window.wav", wav_bytes, "audio/wav")),
        ]
        data: dict[str, str | list[str]] = {
            "model": settings.openai_diarize_model,
            "response_format": "diarized_json",
        }

        # 30초 초과 시 필수. 우리 창은 보통 짧지만, 설정을 바꿔 길게 잡을 수 있으므로
        # 방어적으로 넣는다.
        if duration > _CHUNKING_REQUIRED_SECONDS:
            data["chunking_strategy"] = "auto"

        if language:
            data["language"] = language
        if context_prompt:
            data["prompt"] = context_prompt

        # 참조 클립: 이름과 오디오를 같은 순서의 배열로 담는다.
        #
        # 오디오는 **파일 파트가 아니라 data URL 문자열**이어야 한다. 파일로
        # 올리면 API 가 창마다 400 으로 거부한다:
        #   known_speaker_references[].0: Input should be a valid string
        #
        # 이렇게 거부돼도 자막은 계속 흐르기 때문에 화면상으로는 멀쩡해 보이고,
        # 화자 라벨만 창마다 흔들린다 — 참조 클립 고정(4-2 의 주력 방어)이
        # 통째로 빠진 채 겹침 대조에만 의존하는 상태가 된다.
        reference_names: list[str] = []
        reference_urls: list[str] = []
        for ref in (references or [])[: settings.speaker_reference_max]:
            reference_names.append(ref.name)
            reference_urls.append(make_data_url(ref.pcm, sample_rate=rate, channels=chans))

        if reference_names:
            data["known_speaker_names[]"] = reference_names
            data["known_speaker_references[]"] = reference_urls

        payload = await self._post_with_retry(files=files, data=data)
        return self._parse(payload)

    # ----------------------------------------------------------------- http

    async def _post_with_retry(
        self,
        *,
        files: list[tuple[str, tuple[str | None, bytes | str, str | None]]],
        data: dict[str, str | list[str]],
    ) -> dict[str, Any]:
        assert self._client is not None
        last_error: Exception | None = None

        for attempt in range(1, self._MAX_ATTEMPTS + 1):
            try:
                response = await self._client.post("/audio/transcriptions", files=files, data=data)
            except httpx.TimeoutException as exc:
                last_error = exc
                log.warning("diarize_timeout", attempt=attempt)
            except httpx.HTTPError as exc:
                last_error = exc
                log.warning("diarize_transport_error", attempt=attempt, error=str(exc))
            else:
                if response.status_code == 200:
                    return dict(response.json())

                if response.status_code in (401, 403):
                    log.error("diarize_auth_failed", status=response.status_code)
                    raise ConfigurationError(
                        "OpenAI 인증에 실패했습니다. API 키 권한을 확인하세요."
                    )

                if response.status_code not in self._RETRY_STATUSES:
                    detail = self._error_message(response)
                    log.error("diarize_rejected", status=response.status_code, detail=detail)
                    raise UpstreamError(
                        "음성 전사 요청이 거부되었습니다.",
                        details={"status": response.status_code, "detail": detail},
                    )

                last_error = UpstreamError(f"HTTP {response.status_code}")
                # 429 는 서버가 알려준 대기 시간을 존중한다.
                retry_after = response.headers.get("retry-after")
                if retry_after and retry_after.isdigit():
                    await asyncio.sleep(min(float(retry_after), 10.0))
                    continue
                log.warning("diarize_retryable", status=response.status_code, attempt=attempt)

            if attempt < self._MAX_ATTEMPTS:
                backoff = 0.5 * (2 ** (attempt - 1))
                backoff *= 0.75 + random.random() * 0.5  # noqa: S311 — 암호용 아님
                await asyncio.sleep(backoff)

        log.error("diarize_exhausted", attempts=self._MAX_ATTEMPTS, error=str(last_error))
        raise SpeechServiceUnavailableError from last_error

    @staticmethod
    def _error_message(response: httpx.Response) -> str:
        try:
            body = response.json()
            if isinstance(body, dict):
                error = body.get("error")
                if isinstance(error, dict):
                    return str(error.get("message", ""))[:300]
        except ValueError:
            pass
        return response.text[:300]

    # ----------------------------------------------------------------- parse

    @staticmethod
    def _parse(payload: dict[str, Any]) -> list[DiarizedSegment]:
        raw_segments = payload.get("segments")
        if not isinstance(raw_segments, list):
            # 화자 없는 평문만 온 경우 — 단일 미상 화자로 취급한다.
            text = str(payload.get("text", "")).strip()
            if not text:
                return []
            return [DiarizedSegment(speaker="A", text=text, start=0.0, end=0.0)]

        segments: list[DiarizedSegment] = []
        for item in raw_segments:
            if not isinstance(item, dict):
                continue
            text = str(item.get("text", "")).strip()
            if not text:
                continue
            speaker = str(item.get("speaker") or "A").strip() or "A"
            try:
                start = float(item.get("start", 0.0))
                end = float(item.get("end", start))
            except (TypeError, ValueError):
                start = end = 0.0
            segments.append(
                DiarizedSegment(speaker=speaker, text=text, start=start, end=max(start, end))
            )

        segments.sort(key=lambda s: s.start)
        return segments
