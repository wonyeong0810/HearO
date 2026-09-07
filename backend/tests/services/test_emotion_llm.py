"""감정 분류의 LLM 경로 (DeepSeek V4 Flash).

제공자를 OpenAI 에서 DeepSeek 으로 옮기면서 응답 형식 계약이 약해졌다.
DeepSeek 은 strict `json_schema` 를 받지 않고 `json_object` 만 지원하므로,
"모델이 형식을 지킨다"는 보장이 API 에서 프롬프트로 내려왔다.

그래서 여기서 검증하는 것은 두 가지다.
  1. 요청이 DeepSeek 이 받아들이는 모양인가 (특히 thinking 비활성화 —
     기본값이 켜짐이라 그대로 두면 타임아웃을 매번 넘긴다)
  2. 응답이 흐트러졌을 때 자막이 멈추지 않고 운율 폴백으로 내려가는가
"""

from __future__ import annotations

import json
from typing import Any

import httpx
import pytest

from app.core.config import settings
from app.db.models import EmotionTone
from app.services.audio.prosody import ProsodyFeatures
from app.services.emotion.classifier import EmotionClassifier, ToneRequest

# ------------------------------------------------------------------ 준비물


def _prosody() -> ProsodyFeatures:
    return ProsodyFeatures(
        loudness_dbfs=-25.0,
        peak_dbfs=-18.0,
        intensity=0.5,
        pitch_hz=180.0,
        pitch_std_hz=15.0,
        loudness_std_db=4.0,
        zero_crossing_rate=0.1,
        voiced_ratio=0.8,
        duration_seconds=2.0,
        speech_rate=4.5,
    )


def _requests(*texts: str) -> list[ToneRequest]:
    return [ToneRequest(text=t, prosody=_prosody()) for t in texts]


def _completion(content: str) -> dict[str, Any]:
    return {"choices": [{"message": {"role": "assistant", "content": content}}]}


class _Recorder:
    """호출을 기록하고 미리 정한 응답을 돌려주는 가짜 엔드포인트."""

    def __init__(self, *responses: httpx.Response) -> None:
        self._responses = list(responses)
        self.requests: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if len(self._responses) == 1:
            return self._responses[0]
        return self._responses.pop(0)

    @property
    def payload(self) -> dict[str, Any]:
        return json.loads(self.requests[-1].content)


def _classifier(recorder: _Recorder) -> EmotionClassifier:
    client = httpx.AsyncClient(
        transport=httpx.MockTransport(recorder),
        base_url=settings.emotion_base_url,
    )
    return EmotionClassifier(client=client)


@pytest.fixture(autouse=True)
def _api_key(monkeypatch: pytest.MonkeyPatch) -> None:
    """키가 없으면 classify_batch 가 LLM 을 아예 부르지 않는다."""
    monkeypatch.setattr(settings, "emotion_api_key", "sk-test", raising=False)


# ------------------------------------------------------------------ 요청 모양


class TestRequestShape:
    async def test_uses_configured_model(self) -> None:
        rec = _Recorder(httpx.Response(200, json=_completion('{"results":[]}')))
        await _classifier(rec).classify_batch(_requests("오늘 진짜 고생했어"))

        assert rec.payload["model"] == settings.emotion_model

    async def test_posts_to_chat_completions_under_base_url(self) -> None:
        # base_url 에 /v1 이 이미 붙어 있어 경로가 겹치거나 빠지기 쉽다.
        # 틀리면 조용히 404 가 나고 감정만 운율로 떨어진다.
        rec = _Recorder(httpx.Response(200, json=_completion('{"results":[]}')))
        await _classifier(rec).classify_batch(_requests("오늘 진짜 고생했어"))

        assert str(rec.requests[-1].url) == "https://api.deepseek.com/v1/chat/completions"

    async def test_asks_for_json_object_not_json_schema(self) -> None:
        # DeepSeek 은 json_schema 를 거부한다. 보냈다면 400 이 돌아온다.
        rec = _Recorder(httpx.Response(200, json=_completion('{"results":[]}')))
        await _classifier(rec).classify_batch(_requests("오늘 진짜 고생했어"))

        assert rec.payload["response_format"] == {"type": "json_object"}

    async def test_thinking_is_disabled(self) -> None:
        """DeepSeek V4 는 사고 모드가 기본 켜짐이다.

        켜진 채로 두면 첫 토큰까지 수 초가 걸려 4초 타임아웃을 매번 넘긴다.
        그러면 감정이 전부 운율 추정으로 떨어지는데, 화면에는 여전히 감정이
        표시되므로 아무도 고장난 줄 모른다.
        """
        rec = _Recorder(httpx.Response(200, json=_completion('{"results":[]}')))
        await _classifier(rec).classify_batch(_requests("오늘 진짜 고생했어"))

        assert rec.payload["thinking"] == {"type": "disabled"}

    async def test_thinking_omitted_when_provider_does_not_support_it(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        # OpenAI 로 되돌리면 이 파라미터가 400 을 낸다.
        monkeypatch.setattr(settings, "emotion_disable_thinking", False, raising=False)
        rec = _Recorder(httpx.Response(200, json=_completion('{"results":[]}')))
        await _classifier(rec).classify_batch(_requests("오늘 진짜 고생했어"))

        assert "thinking" not in rec.payload

    async def test_prompt_mentions_json(self) -> None:
        """DeepSeek json 모드의 요구사항 — 프롬프트에 'json' 이 없으면 거부된다."""
        rec = _Recorder(httpx.Response(200, json=_completion('{"results":[]}')))
        await _classifier(rec).classify_batch(_requests("오늘 진짜 고생했어"))

        system = rec.payload["messages"][0]["content"]
        assert "json" in system.lower()
        # 형식 예시도 함께 줘야 한다 (스키마 강제가 없으니 예시가 계약이다).
        assert '"results"' in system

    async def test_batches_at_most_eight_per_call(self) -> None:
        rec = _Recorder(httpx.Response(200, json=_completion('{"results":[]}')))
        await _classifier(rec).classify_batch(_requests(*[f"발화 {i} 입니다" for i in range(20)]))

        assert len(rec.requests) == 3
        for request in rec.requests:
            body = json.loads(request.content)
            sent = json.loads(body["messages"][1]["content"])
            assert len(sent["utterances"]) <= 8

    async def test_short_utterances_are_not_sent(self) -> None:
        rec = _Recorder(httpx.Response(200, json=_completion('{"results":[]}')))
        results = await _classifier(rec).classify_batch(_requests("응", "네"))

        assert rec.requests == []
        assert all(r.from_prosody_only for r in results)


# ------------------------------------------------------------------ 응답 파싱


class TestResponseParsing:
    async def test_parses_well_formed_response(self) -> None:
        rec = _Recorder(
            httpx.Response(
                200,
                json=_completion('{"results":[{"index":0,"tone":"angry","confidence":0.8}]}'),
            )
        )
        results = await _classifier(rec).classify_batch(_requests("너 지금 뭐라고 했어"))

        assert results[0].tone is EmotionTone.ANGRY
        assert results[0].confidence == pytest.approx(0.8)
        assert results[0].from_prosody_only is False

    async def test_strips_markdown_code_fence(self) -> None:
        """스키마 강제가 없으면 모델이 펜스를 붙이는 일이 잦다."""
        fenced = '```json\n{"results":[{"index":0,"tone":"happy","confidence":0.7}]}\n```'
        rec = _Recorder(httpx.Response(200, json=_completion(fenced)))
        results = await _classifier(rec).classify_batch(_requests("이거 완전 대박이다"))

        assert results[0].tone is EmotionTone.HAPPY

    async def test_ignores_prose_around_json(self) -> None:
        noisy = (
            '분석 결과입니다:\n{"results":[{"index":0,"tone":"sad","confidence":0.6}]}\n감사합니다.'
        )
        rec = _Recorder(httpx.Response(200, json=_completion(noisy)))
        results = await _classifier(rec).classify_batch(_requests("그냥 좀 지치네요"))

        assert results[0].tone is EmotionTone.SAD

    async def test_accepts_bare_array(self) -> None:
        rec = _Recorder(
            httpx.Response(200, json=_completion('[{"index":0,"tone":"calm","confidence":0.5}]'))
        )
        results = await _classifier(rec).classify_batch(_requests("알겠습니다 그렇게 하죠"))

        assert results[0].tone is EmotionTone.CALM

    async def test_normalizes_sloppy_tone_values(self) -> None:
        rec = _Recorder(
            httpx.Response(
                200,
                json=_completion('{"results":[{"index":0,"tone":" Excited ","confidence":0.9}]}'),
            )
        )
        results = await _classifier(rec).classify_batch(_requests("빨리빨리 서둘러야 해"))

        assert results[0].tone is EmotionTone.EXCITED

    async def test_unknown_tone_falls_back_to_prosody(self) -> None:
        # 모델이 우리 목록에 없는 감정을 지어내면 무시한다. 화면에 없는
        # 감정 스타일을 그리려 들면 앱이 깨진다.
        rec = _Recorder(
            httpx.Response(
                200,
                json=_completion('{"results":[{"index":0,"tone":"frustrated","confidence":0.9}]}'),
            )
        )
        results = await _classifier(rec).classify_batch(_requests("아 진짜 답답하네"))

        assert results[0].from_prosody_only is True

    async def test_confidence_is_clamped(self) -> None:
        rec = _Recorder(
            httpx.Response(
                200,
                json=_completion('{"results":[{"index":0,"tone":"angry","confidence":9.9}]}'),
            )
        )
        results = await _classifier(rec).classify_batch(_requests("정말 화가 나는군요"))

        assert results[0].confidence == 1.0

    async def test_partial_results_keep_prosody_for_the_rest(self) -> None:
        """일부만 답해도 나머지는 운율 판정이 남아야 한다."""
        rec = _Recorder(
            httpx.Response(
                200,
                json=_completion('{"results":[{"index":1,"tone":"happy","confidence":0.7}]}'),
            )
        )
        results = await _classifier(rec).classify_batch(
            _requests("첫 번째 발화입니다", "두 번째 발화입니다")
        )

        assert results[0].from_prosody_only is True
        assert results[1].tone is EmotionTone.HAPPY


# ------------------------------------------------------------------ 실패 처리


class TestFailureHandling:
    async def test_empty_content_falls_back(self) -> None:
        """DeepSeek 문서가 json 모드에서 드물게 일어난다고 밝힌 상황."""
        rec = _Recorder(httpx.Response(200, json=_completion("")))
        results = await _classifier(rec).classify_batch(_requests("무슨 말이든 해보세요"))

        assert results[0].from_prosody_only is True

    async def test_garbage_content_falls_back(self) -> None:
        rec = _Recorder(httpx.Response(200, json=_completion("죄송하지만 답할 수 없습니다")))
        results = await _classifier(rec).classify_batch(_requests("무슨 말이든 해보세요"))

        assert results[0].from_prosody_only is True

    async def test_http_error_falls_back(self) -> None:
        rec = _Recorder(httpx.Response(400, json={"error": {"message": "bad request"}}))
        results = await _classifier(rec).classify_batch(_requests("무슨 말이든 해보세요"))

        assert results[0].from_prosody_only is True

    async def test_timeout_falls_back(self) -> None:
        def _timeout(request: httpx.Request) -> httpx.Response:
            raise httpx.ReadTimeout("too slow", request=request)

        client = httpx.AsyncClient(
            transport=httpx.MockTransport(_timeout), base_url=settings.emotion_base_url
        )
        results = await EmotionClassifier(client=client).classify_batch(
            _requests("무슨 말이든 해보세요")
        )

        assert results[0].from_prosody_only is True

    async def test_circuit_opens_after_repeated_failures(self) -> None:
        """빈 응답이 계속되면 호출을 끊는다 — 안 끊으면 돈만 나간다."""
        rec = _Recorder(httpx.Response(200, json=_completion("")))
        classifier = _classifier(rec)

        for _ in range(3):
            await classifier.classify_batch(_requests("무슨 말이든 해보세요"))
        assert len(rec.requests) == 3

        await classifier.classify_batch(_requests("무슨 말이든 해보세요"))
        assert len(rec.requests) == 3  # 더 부르지 않았다

    async def test_missing_api_key_skips_llm_entirely(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(settings, "emotion_api_key", "", raising=False)
        rec = _Recorder(httpx.Response(200, json=_completion('{"results":[]}')))
        results = await _classifier(rec).classify_batch(_requests("무슨 말이든 해보세요"))

        assert rec.requests == []
        assert results[0].from_prosody_only is True
