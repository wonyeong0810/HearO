"""프로소디(운율) 특징 추출.

여기서 뽑는 수치가 두 곳에 쓰인다.
  1) intensity → 클라이언트가 자막 글자 크기를 정하는 값 (기획 1-3 "말의 크기/세기")
  2) pitch / rate / 변동성 → 감정 분류기가 텍스트와 함께 보는 근거

numpy 만으로 구현한다. librosa/scipy 는 무겁고, 여기서 필요한 건
RMS·영교차율·자기상관 피치 정도라 직접 쓰는 편이 빠르고 예측 가능하다.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np

# 사람 목소리의 기본주파수 범위. 이 밖은 피치 후보에서 제외한다.
# (성인 남성 하한 ~70Hz, 아동/여성 상한 ~400Hz)
MIN_F0_HZ = 70.0
MAX_F0_HZ = 400.0

# 무음으로 간주할 하한. -60dBFS 는 사실상 정적.
SILENCE_FLOOR_DBFS = -60.0

# intensity 정규화 구간. 조용한 실내 대화(-40) ~ 고함(-8) 을 0~1 로 편다.
_QUIET_DBFS = -40.0
_LOUD_DBFS = -8.0


@dataclass(slots=True)
class ProsodyFeatures:
    """한 발화 구간의 운율 요약."""

    # 평균 음량 (dBFS, 음수)
    loudness_dbfs: float
    # 구간 내 최대 음량 — 짧은 고함을 놓치지 않기 위해 평균과 함께 본다
    peak_dbfs: float
    # 0.0~1.0 정규화 세기. 클라이언트 글자 크기 입력값.
    intensity: float
    # 평균 기본주파수(Hz). 유성음이 없으면 None.
    pitch_hz: float | None
    # 피치 표준편차(Hz). 단조로우면 낮고, 감정이 실리면 높다.
    pitch_std_hz: float | None
    # 음량 변동성 (dB 표준편차). 격앙된 말은 기복이 크다.
    loudness_std_db: float
    # 영교차율 평균. 마찰음/자음 비중 → 발화 속도의 대리 지표.
    zero_crossing_rate: float
    # 유성음 비율 0~1. 낮으면 잡음일 가능성이 크다.
    voiced_ratio: float
    # 분석 구간 길이(초)
    duration_seconds: float
    # 초당 추정 음절 수 (텍스트가 주어지면 정확도가 올라간다)
    speech_rate: float | None = None

    def to_prompt_dict(self) -> dict[str, float | str | None]:
        """감정 분류기 프롬프트에 넣기 좋은 형태로 요약."""
        return {
            "loudness_dbfs": round(self.loudness_dbfs, 1),
            "peak_dbfs": round(self.peak_dbfs, 1),
            "intensity_0_to_1": round(self.intensity, 2),
            "pitch_hz": round(self.pitch_hz, 1) if self.pitch_hz else None,
            "pitch_variability_hz": round(self.pitch_std_hz, 1) if self.pitch_std_hz else None,
            "loudness_variability_db": round(self.loudness_std_db, 1),
            "syllables_per_second": round(self.speech_rate, 2) if self.speech_rate else None,
            "voiced_ratio": round(self.voiced_ratio, 2),
        }

    @classmethod
    def silent(cls, duration: float = 0.0) -> ProsodyFeatures:
        return cls(
            loudness_dbfs=SILENCE_FLOOR_DBFS,
            peak_dbfs=SILENCE_FLOOR_DBFS,
            intensity=0.0,
            pitch_hz=None,
            pitch_std_hz=None,
            loudness_std_db=0.0,
            zero_crossing_rate=0.0,
            voiced_ratio=0.0,
            duration_seconds=duration,
        )


@dataclass(slots=True)
class _FrameStats:
    rms_db: list[float] = field(default_factory=list)
    pitches: list[float] = field(default_factory=list)
    zcr: list[float] = field(default_factory=list)
    voiced_frames: int = 0
    total_frames: int = 0


def _to_float_array(pcm: bytes) -> np.ndarray:
    """PCM16 LE → [-1, 1] float32 배열."""
    if len(pcm) < 2:
        return np.zeros(0, dtype=np.float32)
    usable = len(pcm) - (len(pcm) % 2)
    samples = np.frombuffer(pcm[:usable], dtype="<i2").astype(np.float32)
    return samples / 32768.0


def _rms_to_dbfs(rms: float) -> float:
    if rms <= 1e-10:
        return SILENCE_FLOOR_DBFS
    return max(SILENCE_FLOOR_DBFS, 20.0 * math.log10(rms))


# 탐색은 허용 범위보다 넓게 한다. 경계에서 나온 피크는 "진짜 주기가 범위 밖에
# 있다"는 신호이므로 버려야 하는데, 그러려면 경계 바깥도 볼 수 있어야 한다.
_SEARCH_MIN_F0_HZ = MIN_F0_HZ * 0.8  # 56Hz
_SEARCH_MAX_F0_HZ = MAX_F0_HZ * 1.25  # 500Hz


def _estimate_pitch(frame: np.ndarray, sample_rate: int) -> float | None:
    """자기상관 기반 F0 추정.

    FFT 로 자기상관을 구한 뒤 사람 목소리 대역에서 주기성 피크를 찾는다.
    유성음이 아니거나 피크가 약하면 None (무성음/잡음).
    """
    n = len(frame)
    if n < sample_rate // int(MIN_F0_HZ):
        return None

    # DC 제거 — 없으면 lag 0 부근이 지배해 피크를 못 찾는다.
    frame = frame - float(np.mean(frame))
    energy = float(np.dot(frame, frame))
    if energy < 1e-8:
        return None

    # 원형 자기상관 오염을 막기 위해 2배 길이로 제로패딩
    size = 1 << (2 * n - 1).bit_length()
    spectrum = np.fft.rfft(frame, size)
    autocorr = np.fft.irfft(spectrum * np.conjugate(spectrum), size)[:n]

    min_lag = int(sample_rate / _SEARCH_MAX_F0_HZ)
    max_lag = min(int(sample_rate / _SEARCH_MIN_F0_HZ), n - 1)
    if max_lag - min_lag < 3:
        return None

    window = autocorr[min_lag:max_lag]
    if window.size < 3:
        return None

    peak_idx = int(np.argmax(window))
    peak_value = float(window[peak_idx])

    # 정규화된 자기상관이 0.3 미만이면 주기성이 약하다고 보고 버린다.
    if autocorr[0] <= 0 or peak_value / autocorr[0] < 0.3:
        return None

    # 최댓값이 탐색 구간의 끝에 붙어 있으면 진짜 피크가 구간 밖에 있다는 뜻이다.
    # 초저주파(공조기 웅웅거림, 차량 진동)에서 자기상관은 이 구간 내내 단조
    # 감소하므로 항상 첫 인덱스가 최대가 되는데, 이걸 거르지 않으면 20Hz 소음이
    # 500Hz 목소리로 둔갑한다.
    if peak_idx == 0 or peak_idx == window.size - 1:
        return None

    lag = float(peak_idx + min_lag)

    # 포물선 보간으로 lag 를 소수점까지 다듬는다 (정수 lag 는 고음에서 오차가 크다).
    y0, y1, y2 = window[peak_idx - 1], window[peak_idx], window[peak_idx + 1]
    denom = y0 - 2 * y1 + y2
    if abs(denom) > 1e-12:
        lag += 0.5 * float(y0 - y2) / float(denom)

    if lag <= 0:
        return None

    f0 = sample_rate / lag
    # 탐색은 넓게 했지만 결과는 사람 목소리 대역만 인정한다.
    return f0 if MIN_F0_HZ <= f0 <= MAX_F0_HZ else None


def _normalize_intensity(mean_dbfs: float, peak_dbfs: float) -> float:
    """dBFS → 0~1.

    평균에 70%, 피크에 30% 가중. 평균만 쓰면 짧은 고함이 묻히고,
    피크만 쓰면 순간 잡음에 글자 크기가 튄다.
    """

    def scale(db: float) -> float:
        return (db - _QUIET_DBFS) / (_LOUD_DBFS - _QUIET_DBFS)

    blended = 0.7 * scale(mean_dbfs) + 0.3 * scale(peak_dbfs)
    return float(min(1.0, max(0.0, blended)))


def estimate_speech_rate(text: str, duration_seconds: float) -> float | None:
    """한국어 기준 초당 음절 수.

    한글은 1글자 = 1음절이라 음절 수를 정확히 셀 수 있다. 영어가 섞이면
    모음군을 음절로 근사한다. 정상 대화는 4~6 음절/초, 8 이상이면 매우 빠름.
    """
    if duration_seconds <= 0.1 or not text.strip():
        return None

    syllables = 0
    in_vowel_run = False
    for ch in text:
        code = ord(ch)
        if 0xAC00 <= code <= 0xD7A3:  # 한글 완성형
            syllables += 1
            in_vowel_run = False
        elif ch.lower() in "aeiou":
            if not in_vowel_run:
                syllables += 1
            in_vowel_run = True
        else:
            in_vowel_run = False

    if syllables == 0:
        return None
    return syllables / duration_seconds


def analyze(
    pcm: bytes,
    *,
    sample_rate: int,
    frame_ms: int = 25,
    hop_ms: int = 10,
    text: str | None = None,
) -> ProsodyFeatures:
    """PCM 구간의 운율 특징을 뽑는다.

    frame_ms/hop_ms 는 음성처리 관례값(25ms 창, 10ms 홉).
    """
    signal = _to_float_array(pcm)
    duration = len(signal) / sample_rate if sample_rate else 0.0

    if signal.size == 0 or duration <= 0:
        return ProsodyFeatures.silent()

    frame_len = max(1, int(sample_rate * frame_ms / 1000))
    hop_len = max(1, int(sample_rate * hop_ms / 1000))

    if signal.size < frame_len:
        # 프레임 하나도 안 되는 짧은 조각 — 전체를 한 프레임으로 본다.
        frame_len = signal.size
        hop_len = signal.size

    stats = _FrameStats()
    # 유성음 판정 임계값: 전체 RMS 의 절반 이상인 프레임만 피치를 신뢰한다.
    global_rms = float(np.sqrt(np.mean(signal**2)))
    voiced_threshold = max(global_rms * 0.5, 1e-4)

    for start in range(0, signal.size - frame_len + 1, hop_len):
        frame = signal[start : start + frame_len]
        stats.total_frames += 1

        rms = float(np.sqrt(np.mean(frame**2)))
        stats.rms_db.append(_rms_to_dbfs(rms))

        # 영교차율
        signs = np.signbit(frame)
        stats.zcr.append(float(np.count_nonzero(signs[1:] != signs[:-1])) / max(1, frame.size - 1))

        if rms >= voiced_threshold:
            pitch = _estimate_pitch(frame, sample_rate)
            if pitch is not None:
                stats.pitches.append(pitch)
                stats.voiced_frames += 1

    if not stats.rms_db:
        return ProsodyFeatures.silent(duration)

    rms_array = np.asarray(stats.rms_db, dtype=np.float32)
    # 무음 프레임은 평균을 끌어내리므로 발화 구간만 평균낸다.
    speech_frames = rms_array[rms_array > SILENCE_FLOOR_DBFS + 5.0]
    mean_dbfs = float(np.mean(speech_frames)) if speech_frames.size else float(np.mean(rms_array))
    peak_dbfs = float(np.max(rms_array))
    loudness_std = float(np.std(speech_frames)) if speech_frames.size > 1 else 0.0

    pitch_mean: float | None = None
    pitch_std: float | None = None
    if stats.pitches:
        pitch_array = np.asarray(stats.pitches, dtype=np.float32)
        # 옥타브 오검출(배음을 F0 로 잡는 경우)을 중앙값 필터로 눌러준다.
        median = float(np.median(pitch_array))
        inliers = pitch_array[np.abs(pitch_array - median) < median * 0.5]
        if inliers.size:
            pitch_mean = float(np.mean(inliers))
            pitch_std = float(np.std(inliers)) if inliers.size > 1 else 0.0

    return ProsodyFeatures(
        loudness_dbfs=mean_dbfs,
        peak_dbfs=peak_dbfs,
        intensity=_normalize_intensity(mean_dbfs, peak_dbfs),
        pitch_hz=pitch_mean,
        pitch_std_hz=pitch_std,
        loudness_std_db=loudness_std,
        zero_crossing_rate=float(np.mean(stats.zcr)) if stats.zcr else 0.0,
        voiced_ratio=stats.voiced_frames / stats.total_frames if stats.total_frames else 0.0,
        duration_seconds=duration,
        speech_rate=estimate_speech_rate(text, duration) if text else None,
    )


def level_dbfs(pcm: bytes) -> float:
    """구간의 평균 음량(dBFS). 조용할수록 작다 (무음은 SILENCE_FLOOR_DBFS)."""
    signal = _to_float_array(pcm)
    if signal.size == 0:
        return SILENCE_FLOOR_DBFS
    return _rms_to_dbfs(float(np.sqrt(np.mean(signal**2))))


def is_silent(pcm: bytes, *, sample_rate: int, threshold_dbfs: float) -> bool:
    """구간이 임계값보다 조용한가? 조용하면 전사 API 호출을 건너뛴다."""
    return level_dbfs(pcm) < threshold_dbfs
