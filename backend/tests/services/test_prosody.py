"""운율 분석 테스트.

합성 신호로 검증한다 — 실제 음성 파일을 저장소에 넣지 않기 위해서다.
"""

from __future__ import annotations

import math
import struct

import numpy as np
import pytest

from app.services.audio import prosody

SAMPLE_RATE = 24_000


def _tone(frequency: float, seconds: float, amplitude: float = 0.3) -> bytes:
    """지정 주파수의 사인파 PCM16 을 만든다."""
    count = int(SAMPLE_RATE * seconds)
    samples = [
        int(amplitude * 32767 * math.sin(2 * math.pi * frequency * i / SAMPLE_RATE))
        for i in range(count)
    ]
    return struct.pack(f"<{count}h", *samples)


def _silence(seconds: float) -> bytes:
    count = int(SAMPLE_RATE * seconds)
    return struct.pack(f"<{count}h", *([0] * count))


def _noise(seconds: float, amplitude: float = 0.3) -> bytes:
    rng = np.random.default_rng(seed=42)
    count = int(SAMPLE_RATE * seconds)
    samples = (rng.standard_normal(count) * amplitude * 32767).clip(-32768, 32767)
    return samples.astype("<i2").tobytes()


class TestPitchEstimation:
    @pytest.mark.parametrize("frequency", [100.0, 150.0, 220.0, 330.0])
    def test_recovers_fundamental_frequency(self, frequency: float) -> None:
        features = prosody.analyze(_tone(frequency, 1.0), sample_rate=SAMPLE_RATE)

        assert features.pitch_hz is not None
        # 포물선 보간까지 넣었으므로 3% 이내로 맞아야 한다.
        assert features.pitch_hz == pytest.approx(frequency, rel=0.03)

    def test_rejects_frequencies_outside_voice_range(self) -> None:
        # 30Hz 는 사람 목소리 대역 밖 — 피치로 잡히면 안 된다.
        features = prosody.analyze(_tone(30.0, 0.5), sample_rate=SAMPLE_RATE)
        assert features.pitch_hz is None

    def test_noise_has_no_stable_pitch(self) -> None:
        features = prosody.analyze(_noise(0.5), sample_rate=SAMPLE_RATE)
        # 백색잡음은 주기성이 없으므로 유성음 비율이 낮아야 한다.
        assert features.voiced_ratio < 0.5


class TestLoudness:
    def test_silence_reports_floor(self) -> None:
        features = prosody.analyze(_silence(0.5), sample_rate=SAMPLE_RATE)

        assert features.loudness_dbfs <= prosody.SILENCE_FLOOR_DBFS + 1
        assert features.intensity == 0.0

    def test_louder_signal_yields_higher_intensity(self) -> None:
        quiet = prosody.analyze(_tone(150.0, 0.5, amplitude=0.02), sample_rate=SAMPLE_RATE)
        loud = prosody.analyze(_tone(150.0, 0.5, amplitude=0.8), sample_rate=SAMPLE_RATE)

        assert loud.intensity > quiet.intensity
        assert 0.0 <= quiet.intensity <= 1.0
        assert 0.0 <= loud.intensity <= 1.0

    def test_intensity_is_always_bounded(self) -> None:
        # 클리핑 수준의 신호에서도 1.0 을 넘지 않아야 한다 (글자 크기 폭주 방지).
        features = prosody.analyze(_tone(150.0, 0.3, amplitude=1.0), sample_rate=SAMPLE_RATE)
        assert features.intensity <= 1.0


class TestSilenceDetection:
    def test_detects_silence(self) -> None:
        assert prosody.is_silent(_silence(0.5), sample_rate=SAMPLE_RATE, threshold_dbfs=-45.0)

    def test_detects_speech(self) -> None:
        assert not prosody.is_silent(
            _tone(150.0, 0.5, amplitude=0.3), sample_rate=SAMPLE_RATE, threshold_dbfs=-45.0
        )

    def test_empty_buffer_is_silent(self) -> None:
        assert prosody.is_silent(b"", sample_rate=SAMPLE_RATE, threshold_dbfs=-45.0)


class TestSpeechRate:
    def test_counts_korean_syllables(self) -> None:
        # "안녕하세요" = 5음절, 1초 → 5 음절/초
        rate = prosody.estimate_speech_rate("안녕하세요", 1.0)
        assert rate == pytest.approx(5.0)

    def test_counts_english_vowel_groups(self) -> None:
        rate = prosody.estimate_speech_rate("hello there", 1.0)
        assert rate is not None
        assert rate > 0

    def test_ignores_punctuation_and_spaces(self) -> None:
        assert prosody.estimate_speech_rate("가나다", 1.0) == pytest.approx(
            prosody.estimate_speech_rate("가, 나! 다?", 1.0)
        )

    def test_returns_none_for_empty_text(self) -> None:
        assert prosody.estimate_speech_rate("", 1.0) is None

    def test_returns_none_for_zero_duration(self) -> None:
        assert prosody.estimate_speech_rate("안녕", 0.0) is None


class TestEdgeCases:
    def test_empty_audio_returns_silent_features(self) -> None:
        features = prosody.analyze(b"", sample_rate=SAMPLE_RATE)
        assert features.intensity == 0.0
        assert features.pitch_hz is None

    def test_odd_byte_count_does_not_crash(self) -> None:
        # 프레임 경계에서 잘린 청크는 정상적으로 들어올 수 있다.
        features = prosody.analyze(_tone(150.0, 0.2) + b"\x00", sample_rate=SAMPLE_RATE)
        assert features.duration_seconds > 0

    def test_shorter_than_one_frame_does_not_crash(self) -> None:
        features = prosody.analyze(_tone(150.0, 0.005), sample_rate=SAMPLE_RATE)
        assert features.duration_seconds > 0
