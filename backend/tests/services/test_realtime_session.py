"""Realtime 세션 설정 페이로드 테스트.

이 페이로드가 틀리면 OpenAI 가 세션을 통째로 거부해서 **자막이 아예 시작되지
않는다.** 조용히 나빠지는 게 아니라 대놓고 죽는데, 정작 원인은 서버 쪽 오류
메시지에만 남아 앱에서는 "시작하지 못했습니다"로만 보인다.

실제로 `language` 에 리스트를 넣어 이렇게 죽은 적이 있다:
  Invalid type for 'session.audio.input.transcription.language'

gpt-live-transcribe 는 복수형 `languages`(배열)를 쓴다. 단수 `language` 는
문자열 하나만 받고, 둘을 같이 보내서도 안 된다.
"""

from __future__ import annotations

from typing import Any

import pytest

from app.core.config import settings
from app.services.stt.realtime_client import RealtimeTranscriber


@pytest.fixture
def transcriber(monkeypatch: pytest.MonkeyPatch) -> RealtimeTranscriber:
    # 생성자가 키를 요구한다. 연결은 하지 않으므로 값 자체는 의미 없다.
    monkeypatch.setattr(settings, "openai_api_key", "sk-test", raising=False)
    return RealtimeTranscriber(
        language_hints=["ko", "en"],
        keyword_hints=["HearO", "민방위"],
        context_prompt="병원 진료 상황",
    )


def _transcription(payload: dict[str, Any]) -> dict[str, Any]:
    return payload["session"]["audio"]["input"]["transcription"]


class TestSessionPayload:
    def test_uses_plural_languages_as_array(self, transcriber: RealtimeTranscriber) -> None:
        transcription = _transcription(transcriber._session_payload())

        assert transcription["languages"] == ["ko", "en"]
        assert isinstance(transcription["languages"], list)

    def test_never_sends_singular_language(self, transcriber: RealtimeTranscriber) -> None:
        # 단수형을 함께 보내면 세션이 거부된다.
        assert "language" not in _transcription(transcriber._session_payload())

    def test_keywords_stay_an_array(self, transcriber: RealtimeTranscriber) -> None:
        transcription = _transcription(transcriber._session_payload())
        assert transcription["keywords"] == ["HearO", "민방위"]

    def test_prompt_stays_a_string(self, transcriber: RealtimeTranscriber) -> None:
        transcription = _transcription(transcriber._session_payload())
        assert transcription["prompt"] == "병원 진료 상황"

    def test_hints_are_omitted_when_empty(self, monkeypatch: pytest.MonkeyPatch) -> None:
        # 빈 배열을 보내면 "힌트 없음"이 아니라 잘못된 값으로 읽힐 수 있다.
        monkeypatch.setattr(settings, "openai_api_key", "sk-test", raising=False)
        monkeypatch.setattr(settings, "stt_language_hints", [], raising=False)
        monkeypatch.setattr(settings, "stt_keyword_hints", [], raising=False)

        transcription = _transcription(RealtimeTranscriber()._session_payload())

        assert "languages" not in transcription
        assert "language" not in transcription
        assert "keywords" not in transcription
        assert transcription["model"] == settings.openai_realtime_model

    def test_audio_format_matches_what_the_app_sends(
        self, transcriber: RealtimeTranscriber
    ) -> None:
        # 앱이 24kHz PCM16 을 올린다. 여기가 어긋나면 전사가 통째로 깨지는 게
        # 아니라 미묘하게 나빠져서 원인을 찾기 어렵다.
        audio_input = transcriber._session_payload()["session"]["audio"]["input"]

        assert audio_input["format"] == {
            "type": "audio/pcm",
            "rate": settings.audio_sample_rate,
        }
        assert settings.audio_sample_rate == 24_000

    def test_turn_detection_is_disabled(self, transcriber: RealtimeTranscriber) -> None:
        # gpt-live-transcribe 는 turn_detection 을 받지 않는다. 값을 넣으면
        # 세션 설정이 통째로 거부되어 자막이 시작되지 않는다.
        audio_input = transcriber._session_payload()["session"]["audio"]["input"]

        assert "turn_detection" in audio_input
        assert audio_input["turn_detection"] is None

    def test_session_type_is_transcription(self, transcriber: RealtimeTranscriber) -> None:
        payload = transcriber._session_payload()
        assert payload["type"] == "session.update"
        assert payload["session"]["type"] == "transcription"

    def test_payload_is_json_serialisable(self, transcriber: RealtimeTranscriber) -> None:
        import json

        # 직렬화가 안 되는 값이 섞이면 연결 직후 죽는다.
        json.dumps(transcriber._session_payload())
