"""감정 분류 테스트 (운율 경로 — LLM 호출 없이)."""

from __future__ import annotations

import pytest

from app.db.models import EmotionTone
from app.services.audio.prosody import ProsodyFeatures
from app.services.emotion.classifier import ToneResult, blend, classify_by_prosody


def _features(
    *,
    intensity: float = 0.5,
    pitch: float | None = 180.0,
    pitch_std: float | None = 15.0,
    rate: float | None = 4.5,
    loudness_std: float = 4.0,
    voiced_ratio: float = 0.8,
    duration: float = 2.0,
) -> ProsodyFeatures:
    return ProsodyFeatures(
        loudness_dbfs=-25.0,
        peak_dbfs=-18.0,
        intensity=intensity,
        pitch_hz=pitch,
        pitch_std_hz=pitch_std,
        loudness_std_db=loudness_std,
        zero_crossing_rate=0.1,
        voiced_ratio=voiced_ratio,
        duration_seconds=duration,
        speech_rate=rate,
    )


class TestProsodyClassification:
    def test_loud_fast_variable_reads_as_excited(self) -> None:
        result = classify_by_prosody(
            _features(intensity=0.9, pitch=220.0, pitch_std=60.0, rate=7.5, loudness_std=9.0)
        )
        assert result.tone is EmotionTone.EXCITED
        assert result.confidence > 0.25

    def test_quiet_slow_low_reads_as_sad(self) -> None:
        result = classify_by_prosody(
            _features(intensity=0.12, pitch=95.0, pitch_std=5.0, rate=2.2, loudness_std=1.5)
        )
        assert result.tone is EmotionTone.SAD

    def test_moderate_steady_reads_as_calm(self) -> None:
        result = classify_by_prosody(
            _features(intensity=0.45, pitch=160.0, pitch_std=8.0, rate=4.5, loudness_std=2.0)
        )
        assert result.tone is EmotionTone.CALM

    def test_unvoiced_audio_returns_neutral(self) -> None:
        result = classify_by_prosody(_features(voiced_ratio=0.05))
        assert result.tone is EmotionTone.NEUTRAL
        assert result.confidence == 0.0

    def test_too_short_returns_neutral(self) -> None:
        result = classify_by_prosody(_features(duration=0.1))
        assert result.tone is EmotionTone.NEUTRAL

    def test_prosody_confidence_is_capped(self) -> None:
        """운율만으로는 확신할 수 없으므로 신뢰도 상한이 있어야 한다."""
        result = classify_by_prosody(
            _features(intensity=1.0, pitch=300.0, pitch_std=90.0, rate=9.0, loudness_std=12.0)
        )
        assert result.confidence <= 0.6

    def test_never_returns_angry_from_prosody_alone(self) -> None:
        """화남과 격앙됨은 운율만으로 구분되지 않는다 — 텍스트가 필요하다.

        시끄러운 곳에서 크게 말했다는 이유로 '화남'을 띄우면, 사용자가 상대의
        감정을 완전히 오해하게 된다. 이건 실제 해가 되는 오류다.
        """
        loud_variants = [
            _features(intensity=1.0, pitch=250.0, pitch_std=80.0, rate=8.0, loudness_std=11.0),
            _features(intensity=0.85, pitch=140.0, pitch_std=45.0, rate=7.0, loudness_std=8.0),
            _features(intensity=0.95, pitch=300.0, pitch_std=100.0, rate=9.5, loudness_std=14.0),
        ]
        for features in loud_variants:
            assert classify_by_prosody(features).tone is not EmotionTone.ANGRY

    @pytest.mark.parametrize("intensity", [0.0, 0.25, 0.5, 0.75, 1.0])
    def test_confidence_always_in_range(self, intensity: float) -> None:
        result = classify_by_prosody(_features(intensity=intensity))
        assert 0.0 <= result.confidence <= 1.0


class TestBlending:
    def test_agreement_raises_confidence(self) -> None:
        llm = ToneResult(tone=EmotionTone.HAPPY, confidence=0.6)
        prosody = ToneResult(tone=EmotionTone.HAPPY, confidence=0.5, from_prosody_only=True)

        merged = blend(llm, prosody)
        assert merged.tone is EmotionTone.HAPPY
        assert merged.confidence > llm.confidence

    def test_disagreement_lowers_confidence(self) -> None:
        llm = ToneResult(tone=EmotionTone.CALM, confidence=0.7)
        prosody = ToneResult(tone=EmotionTone.EXCITED, confidence=0.4, from_prosody_only=True)

        merged = blend(llm, prosody)
        assert merged.tone is EmotionTone.CALM
        assert merged.confidence < llm.confidence

    def test_strong_prosody_overrides_unsure_llm(self) -> None:
        llm = ToneResult(tone=EmotionTone.NEUTRAL, confidence=0.2)
        prosody = ToneResult(tone=EmotionTone.SAD, confidence=0.55, from_prosody_only=True)

        merged = blend(llm, prosody)
        assert merged.tone is EmotionTone.SAD

    def test_blend_confidence_never_exceeds_one(self) -> None:
        llm = ToneResult(tone=EmotionTone.ANGRY, confidence=0.95)
        prosody = ToneResult(tone=EmotionTone.ANGRY, confidence=0.6, from_prosody_only=True)
        assert blend(llm, prosody).confidence <= 1.0


class TestBasisReporting:
    """판정 근거를 앱이 화면에 그대로 적는다 — 부풀리면 사용자가 과신한다.

    앱은 `from_prosody_only` 를 받아 "목소리 톤만으로 추정" 또는 "목소리 톤과
    문장 내용으로 추정" 을 배지 시트에 표시한다. 여기서 근거를 잘못 보고하면
    화면이 거짓말을 하고, 사용자는 그걸 검증할 방법이 없다 — 소리를 못 듣는다.
    """

    def test_prosody_verdict_reports_prosody_basis(self) -> None:
        result = classify_by_prosody(_features(intensity=0.85, rate=7.0))
        assert result.from_prosody_only is True

    def test_prosody_override_still_reports_prosody_basis(self) -> None:
        """LLM 을 불렀어도 **채택된 판정**이 운율에서 나왔으면 운율이라고 적는다.

        이 분기가 한동안 근거를 문장까지 본 것으로 보고했다. 실제로는 목소리만
        보고 정한 톤인데 "문장 내용도 봤다"고 표시되면, 사투리나 평소 목소리
        크기 때문에 생긴 오판을 사용자가 더 믿게 된다.
        """
        llm = ToneResult(tone=EmotionTone.NEUTRAL, confidence=0.2)
        prosody = ToneResult(tone=EmotionTone.SAD, confidence=0.55, from_prosody_only=True)

        merged = blend(llm, prosody)
        assert merged.tone is EmotionTone.SAD
        assert merged.from_prosody_only is True

    def test_llm_verdicts_report_text_basis(self) -> None:
        prosody = ToneResult(tone=EmotionTone.CALM, confidence=0.4, from_prosody_only=True)

        agreement = blend(ToneResult(tone=EmotionTone.CALM, confidence=0.7), prosody)
        disagreement = blend(ToneResult(tone=EmotionTone.ANGRY, confidence=0.7), prosody)

        assert agreement.from_prosody_only is False
        assert disagreement.from_prosody_only is False
