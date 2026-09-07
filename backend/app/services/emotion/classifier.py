"""감정·톤 분류 (하이브리드).

기획 1-3 "음성의 감정/톤을 AI가 분석하여 시각적으로 표현" 을 담당한다.

두 신호를 합친다.
  - 운율(prosody): 음량·피치·변동성·발화속도. 오디오에서 직접 계산되며
    네트워크가 필요 없고 즉시 나온다.
  - 텍스트: 같은 "알겠어" 도 문맥에 따라 체념일 수도 수긍일 수도 있다.
    운율만으로는 절대 구분되지 않는 부분이라 LLM 이 필요하다.

LLM 호출이 실패하거나 느리면 운율만으로 판정한 결과를 쓴다. 자막에서 감정
표시가 통째로 사라지는 것보다, 덜 정확하더라도 항상 뜨는 편이 낫다.

여기 쓰는 LLM 은 STT 와 **별개 제공자**다 (`EMOTION_*` 설정). 실시간 전사와
화자분리는 OpenAI 고유 기능이라 옮길 수 없지만, 감정 분류는 평범한 chat
completions 라 더 싸고 빠른 모델을 쓸 수 있다. 기본값은 DeepSeek V4 Flash.
"""

from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass
from typing import Any

import httpx

from app.core.config import settings
from app.core.logging import get_logger
from app.db.models import EmotionTone
from app.services.audio.prosody import ProsodyFeatures

log = get_logger(__name__)

# 한 번에 묶어 보낼 발화 수. 호출 수를 줄여 비용과 지연을 함께 낮춘다.
_MAX_BATCH = 8

# 텍스트가 이보다 짧으면 LLM 에 물어도 의미가 없다 ("응", "네" 등).
_MIN_TEXT_LENGTH_FOR_LLM = 4

# 응답 상한. 발화 8건이면 항목당 ~25 토큰이라 200 이면 충분하지만, 중간에
# 잘린 JSON 은 통째로 못 읽으므로 넉넉히 잡는다.
_MAX_OUTPUT_TOKENS = 400

# 이보다 오래 걸린 호출은 남긴다. 제공자를 바꾼 뒤 타임아웃이 슬슬 물리기
# 시작하는 것을, 감정이 전부 운율로 떨어지고 나서야 알아채면 늦다.
_SLOW_CALL_LOG_MS = 2_000


@dataclass(slots=True)
class ToneResult:
    tone: EmotionTone
    confidence: float
    # 운율만으로 판정했는지(LLM 실패/생략) 표시. 관측용.
    from_prosody_only: bool = False

    @classmethod
    def neutral(cls) -> ToneResult:
        return cls(tone=EmotionTone.NEUTRAL, confidence=0.0, from_prosody_only=True)


@dataclass(slots=True)
class ToneRequest:
    text: str
    prosody: ProsodyFeatures
    # 직전 발화들 — 문맥 없이는 반어법·비꼼을 잡을 수 없다.
    context: list[str] | None = None


# --------------------------------------------------------------------- 운율 판정


def classify_by_prosody(features: ProsodyFeatures) -> ToneResult:
    """운율만으로 톤을 추정한다. LLM 폴백이자, LLM 판정의 사전 확률 역할.

    규칙은 음성학 상식에 기반한다.
      - 높은 음량 + 빠른 발화 + 큰 피치 변동 → 격앙/화남
      - 높은 피치 + 큰 변동 + 보통 음량      → 기쁨
      - 낮은 피치 + 낮은 음량 + 느린 발화    → 슬픔
      - 중간 음량 + 작은 변동                → 차분
    화남과 격앙됨의 구분은 운율만으로는 어렵다 — 그건 텍스트가 필요하다.
    여기서는 둘을 가르지 않고 EXCITED 로 두고, 신뢰도를 낮게 준다.
    """
    if features.voiced_ratio < 0.15 or features.duration_seconds < 0.2:
        return ToneResult.neutral()

    intensity = features.intensity
    pitch = features.pitch_hz
    pitch_var = features.pitch_std_hz or 0.0
    rate = features.speech_rate
    loudness_var = features.loudness_std_db

    # 각 톤에 점수를 매겨 최댓값을 고른다.
    scores: dict[EmotionTone, float] = dict.fromkeys(
        (EmotionTone.CALM, EmotionTone.EXCITED, EmotionTone.HAPPY, EmotionTone.SAD), 0.0
    )

    # --- 세기 ---
    if intensity > 0.7:
        scores[EmotionTone.EXCITED] += 0.45
        scores[EmotionTone.HAPPY] += 0.15
    elif intensity < 0.25:
        scores[EmotionTone.SAD] += 0.35
        scores[EmotionTone.CALM] += 0.2
    else:
        scores[EmotionTone.CALM] += 0.3

    # --- 피치 변동 (감정이 실릴수록 커진다) ---
    if pitch is not None and pitch > 0:
        relative_var = pitch_var / pitch
        if relative_var > 0.22:
            scores[EmotionTone.EXCITED] += 0.25
            scores[EmotionTone.HAPPY] += 0.25
        elif relative_var < 0.08:
            scores[EmotionTone.CALM] += 0.25
            scores[EmotionTone.SAD] += 0.15

        # 절대 피치는 개인차가 크므로 약하게만 반영한다.
        if pitch > 260:
            scores[EmotionTone.HAPPY] += 0.15
            scores[EmotionTone.EXCITED] += 0.1
        elif pitch < 110:
            scores[EmotionTone.SAD] += 0.2

    # --- 발화 속도 ---
    if rate is not None:
        if rate > 6.5:
            scores[EmotionTone.EXCITED] += 0.3
        elif rate < 3.0:
            scores[EmotionTone.SAD] += 0.25
            scores[EmotionTone.CALM] += 0.1
        else:
            scores[EmotionTone.CALM] += 0.15

    # --- 음량 기복 ---
    if loudness_var > 7.0:
        scores[EmotionTone.EXCITED] += 0.2
    elif loudness_var < 2.5:
        scores[EmotionTone.CALM] += 0.15

    tone, raw_score = max(scores.items(), key=lambda kv: kv[1])
    total = sum(scores.values()) or 1.0

    # 운율만으로는 확신할 수 없으므로 상한을 0.6 으로 묶는다.
    confidence = min(0.6, raw_score / total * 1.4)

    if confidence < 0.25:
        return ToneResult.neutral()
    return ToneResult(tone=tone, confidence=round(confidence, 2), from_prosody_only=True)


# --------------------------------------------------------------------- LLM 판정

_SYSTEM_PROMPT = """\
너는 청각장애인용 실시간 자막 앱의 감정 분석기다. 사용자는 소리를 듣지 못하므로,
네가 판정한 톤이 그들이 대화 분위기를 아는 유일한 단서다.

각 발화에 대해 다음 6개 중 하나를 고른다:
- calm: 차분함, 평범한 대화 톤
- excited: 격앙됨, 흥분, 다급함 (분노는 아님)
- angry: 화남, 짜증, 적대적
- happy: 기쁨, 즐거움, 웃음
- sad: 슬픔, 낙담, 우울
- neutral: 위 어디에도 확실히 속하지 않음

판정 규칙:
1. 텍스트의 의미와 운율 수치를 함께 본다. 운율은 참고자료이지 정답이 아니다.
2. 소리가 크고 빠르다고 무조건 angry 가 아니다. 시끄러운 곳에서는 누구나 크게 말한다.
   화남은 단어 선택과 어조에서 드러난다.
3. 확신이 없으면 neutral 과 낮은 confidence 를 쓴다. 틀린 감정을 자신 있게
   표시하는 것이, 모른다고 하는 것보다 사용자에게 훨씬 해롭다.
4. 짧은 응답("응", "네", "알겠어")은 문맥이 없으면 대부분 neutral 이다.
5. confidence 는 0.0~1.0 실수다.

출력 형식 — 이것만 지키면 된다:
JSON 객체 **하나**만 출력한다. 설명 문장도, 코드펜스도, 앞뒤 군더더기도 붙이지
않는다. 입력에 들어온 utterance 마다 정확히 한 항목을 넣고, index 는 입력에
적힌 index 를 그대로 쓴다.

json 출력 예시 (입력이 2건이었을 때):
{"results":[{"index":0,"tone":"calm","confidence":0.72},\
{"index":1,"tone":"angry","confidence":0.55}]}"""

# 허용 톤 값. 모델이 "Angry" 나 "excited " 처럼 흘려 써도 받아주기 위해
# 파서에서 정규화한 뒤 대조한다.
_VALID_TONES = {tone.value for tone in EmotionTone}


class _EmptyLlmResponseError(RuntimeError):
    """모델이 빈 내용을 돌려줬다.

    DeepSeek 문서가 json 모드에서 드물게 일어난다고 밝힌 상황이다. 폴백으로
    넘기되 실패로 세어, 계속 반복되면 서킷브레이커가 호출을 끊게 한다 —
    빈 응답을 무한정 다시 사거는 돈만 나간다.
    """


class _UnparsableLlmResponseError(RuntimeError):
    """응답에서 결과 배열을 못 찾았다.

    한 번은 모델이 흔들린 것이지만 계속되면 설정이 틀린 것이다 (json 모드를
    지원하지 않는 모델을 EMOTION_MODEL 에 넣은 경우 등). 역시 실패로 센다.
    """


class EmotionClassifier:
    """LLM + 운율 하이브리드 분류기.

    HTTP 클라이언트를 재사용하므로 앱 수명주기 동안 하나만 둔다.
    """

    def __init__(self, client: httpx.AsyncClient | None = None) -> None:
        self._client = client
        self._owns_client = client is None
        # 연속 실패 시 LLM 호출을 잠시 끊는 간이 서킷브레이커.
        self._consecutive_failures = 0
        self._circuit_open_until = 0.0

    async def start(self) -> None:
        if self._client is None:
            self._client = httpx.AsyncClient(
                base_url=settings.emotion_base_url,
                headers=settings.emotion_headers(),
                timeout=httpx.Timeout(settings.emotion_timeout_seconds, connect=3.0),
                limits=httpx.Limits(max_connections=10, max_keepalive_connections=5),
            )

    async def aclose(self) -> None:
        if self._client is not None and self._owns_client:
            await self._client.aclose()
            self._client = None

    # ----------------------------------------------------------------- api

    async def classify(self, request: ToneRequest) -> ToneResult:
        results = await self.classify_batch([request])
        return results[0] if results else ToneResult.neutral()

    async def classify_batch(self, requests: list[ToneRequest]) -> list[ToneResult]:
        """여러 발화를 한 번에 분류한다. 순서는 입력과 동일하다."""
        if not requests:
            return []

        # 항상 운율 판정을 먼저 구해둔다 — LLM 이 실패해도 이 값을 쓴다.
        fallbacks = [classify_by_prosody(r.prosody) for r in requests]

        if not settings.emotion_configured or self._circuit_is_open():
            return fallbacks

        # LLM 에 물어볼 가치가 있는 것만 추린다.
        askable = [
            i for i, r in enumerate(requests) if len(r.text.strip()) >= _MIN_TEXT_LENGTH_FOR_LLM
        ]
        if not askable:
            return fallbacks

        results = list(fallbacks)
        for start in range(0, len(askable), _MAX_BATCH):
            batch_indices = askable[start : start + _MAX_BATCH]
            batch = [requests[i] for i in batch_indices]
            try:
                llm_results = await self._ask_llm(batch)
            except Exception as exc:  # noqa: BLE001 — 감정 분석 실패로 자막이 멈추면 안 된다
                self._record_failure(exc)
                break

            self._consecutive_failures = 0
            for local_idx, tone_result in llm_results.items():
                if 0 <= local_idx < len(batch_indices):
                    results[batch_indices[local_idx]] = tone_result

        return results

    # ----------------------------------------------------------------- internal

    def _circuit_is_open(self) -> bool:
        if self._consecutive_failures < 3:
            return False
        loop_time = asyncio.get_running_loop().time()
        if loop_time < self._circuit_open_until:
            return True
        # 쿨다운이 끝났으니 한 번 더 시도해본다.
        self._consecutive_failures = 2
        return False

    def _record_failure(self, exc: Exception) -> None:
        self._consecutive_failures += 1
        if self._consecutive_failures >= 3:
            self._circuit_open_until = asyncio.get_running_loop().time() + 30.0
            log.warning(
                "emotion_llm_circuit_open",
                failures=self._consecutive_failures,
                cooldown_seconds=30,
            )
        log.warning("emotion_llm_failed", error=str(exc), error_type=type(exc).__name__)

    def _build_user_message(self, batch: list[ToneRequest]) -> str:
        items = []
        for i, req in enumerate(batch):
            entry: dict[str, Any] = {
                "index": i,
                "text": req.text,
                "prosody": req.prosody.to_prompt_dict(),
            }
            if req.context:
                entry["preceding_utterances"] = req.context[-3:]
            items.append(entry)
        return json.dumps({"utterances": items}, ensure_ascii=False)

    def _build_payload(self, batch: list[ToneRequest]) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "model": settings.emotion_model,
            "messages": [
                {"role": "system", "content": _SYSTEM_PROMPT},
                {"role": "user", "content": self._build_user_message(batch)},
            ],
            # strict json_schema 는 쓰지 않는다. DeepSeek 은 json_object 만
            # 받고, OpenAI 도 json_object 는 받는다 — 한쪽만 되는 경로를 두면
            # 실제로 도는 것과 테스트한 것이 갈린다. 스키마 강제가 없어진
            # 대신 프롬프트에 예시를 박고 파서를 방어적으로 짰다.
            "response_format": {"type": "json_object"},
            "temperature": 0.0,
            "max_tokens": _MAX_OUTPUT_TOKENS,
        }
        if settings.emotion_disable_thinking:
            payload["thinking"] = {"type": "disabled"}
        return payload

    async def _ask_llm(self, batch: list[ToneRequest]) -> dict[int, ToneResult]:
        if self._client is None:
            await self.start()
        assert self._client is not None

        loop = asyncio.get_running_loop()
        started = loop.time()
        response = await self._client.post("/chat/completions", json=self._build_payload(batch))
        response.raise_for_status()
        elapsed_ms = round((loop.time() - started) * 1000)

        if elapsed_ms > _SLOW_CALL_LOG_MS:
            log.info(
                "emotion_llm_slow",
                elapsed_ms=elapsed_ms,
                model=settings.emotion_model,
                batch_size=len(batch),
                timeout_ms=round(settings.emotion_timeout_seconds * 1000),
            )

        content = _message_content(response.json())
        if not content:
            raise _EmptyLlmResponseError(
                f"모델 {settings.emotion_model} 이 빈 응답을 돌려줬습니다."
            )

        items = _result_items(content)
        if items is None:
            raise _UnparsableLlmResponseError(
                f"모델 {settings.emotion_model} 응답에서 results 배열을 찾지 못했습니다: "
                f"{content[:200]!r}"
            )

        results: dict[int, ToneResult] = {}
        for item in items:
            parsed = _parse_item(item)
            if parsed is None:
                continue
            index, tone_result = parsed
            results[index] = tone_result
        return results


# ------------------------------------------------------------------ 응답 파싱
#
# strict 스키마가 없으니 형식이 어긋날 수 있다. 감정 표시 하나 때문에 자막이
# 멈추면 안 되므로, 건질 수 있는 만큼 건지고 나머지는 운율 폴백에 맡긴다.


def _message_content(payload: Any) -> str:
    try:
        message = payload["choices"][0]["message"]
    except (KeyError, IndexError, TypeError):
        return ""
    if not isinstance(message, dict):
        return ""
    return str(message.get("content") or "").strip()


def _loads_lenient(content: str) -> Any:
    """코드펜스나 앞뒤 설명이 붙어도 JSON 을 읽어낸다."""
    text = content.strip()
    if text.startswith("```"):
        text = text.strip("`").strip()
        if text[:4].lower() == "json":
            text = text[4:].strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass

    # 마지막 시도: 첫 '{' 부터 마지막 '}' 까지만 떼어 본다.
    start, end = text.find("{"), text.rfind("}")
    if start == -1 or end <= start:
        return None
    try:
        return json.loads(text[start : end + 1])
    except json.JSONDecodeError:
        return None


def _result_items(content: str) -> list[Any] | None:
    """결과 배열을 꺼낸다. 못 찾으면 None (빈 리스트와 구분해야 한다)."""
    data = _loads_lenient(content)
    if isinstance(data, list):
        # 감싸는 객체를 빼먹고 배열만 돌려주는 경우.
        return data
    if isinstance(data, dict):
        items = data.get("results")
        if isinstance(items, list):
            return items
    return None


def _parse_item(item: Any) -> tuple[int, ToneResult] | None:
    if not isinstance(item, dict):
        log.warning("emotion_llm_bad_item", item=item, error="객체가 아님")
        return None
    try:
        index = int(item["index"])
        # "Angry", "excited " 처럼 흘려 쓴 값도 받아준다.
        raw_tone = str(item["tone"]).strip().lower()
        confidence = float(item["confidence"])
    except (KeyError, TypeError, ValueError) as exc:
        log.warning("emotion_llm_bad_item", item=item, error=str(exc))
        return None

    if raw_tone not in _VALID_TONES:
        log.warning("emotion_llm_unknown_tone", tone=raw_tone)
        return None

    return index, ToneResult(
        tone=EmotionTone(raw_tone),
        confidence=max(0.0, min(1.0, confidence)),
        from_prosody_only=False,
    )


def blend(llm: ToneResult, prosody: ToneResult) -> ToneResult:
    """LLM 과 운율 판정이 엇갈릴 때의 조정.

    둘이 같으면 신뢰도를 올리고, 다르면 LLM 을 따르되 신뢰도를 깎는다.
    사용자에게는 신뢰도가 낮으면 애니메이션을 약하게 주는 식으로 반영된다.
    """
    if llm.tone == prosody.tone:
        return ToneResult(
            tone=llm.tone,
            confidence=min(1.0, llm.confidence + prosody.confidence * 0.3),
            from_prosody_only=False,
        )
    if llm.confidence < 0.4 and prosody.confidence > 0.45:
        # LLM 이 자신 없고 운율이 뚜렷하면 운율을 택한다.
        #
        # 이때 from_prosody_only 는 True 여야 한다. LLM 을 부르기는 했지만 채택된
        # 판정은 운율에서 나왔고, 화면에는 근거가 그대로 표시된다 — 문장 내용을
        # 봤다고 말해 놓고 실제로는 목소리만 본 것이면 사용자에게 거짓말이 된다.
        return ToneResult(
            tone=prosody.tone,
            confidence=prosody.confidence * 0.8,
            from_prosody_only=True,
        )
    return ToneResult(tone=llm.tone, confidence=llm.confidence * 0.85, from_prosody_only=False)
