"""PCM16 ↔ WAV 변환.

OpenAI 전사 API 는 컨테이너가 있는 파일을 요구하므로, 클라이언트가 보내는
생 PCM 스트림을 청크 단위로 WAV 로 감싸 올린다. 파일을 디스크에 쓰지 않고
메모리에서만 다룬다 (오디오를 저장하지 않는다는 원칙).
"""

from __future__ import annotations

import io
import struct
import wave

WAV_HEADER_BYTES = 44


def pcm16_to_wav(
    pcm: bytes,
    *,
    sample_rate: int,
    channels: int = 1,
) -> bytes:
    """생 PCM16(LE) 바이트를 WAV 파일 바이트로 감싼다."""
    if len(pcm) % (2 * channels):
        # 샘플 경계가 안 맞으면 마지막 반쪽 샘플을 버린다.
        # (프레임 경계에서 잘린 청크가 들어오는 것은 정상 상황이다)
        usable = len(pcm) - (len(pcm) % (2 * channels))
        pcm = pcm[:usable]

    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(2)  # 16-bit
        wav.setframerate(sample_rate)
        wav.writeframes(pcm)
    return buffer.getvalue()


def wav_to_pcm16(data: bytes) -> tuple[bytes, int, int]:
    """WAV 바이트에서 (pcm, sample_rate, channels) 추출."""
    with wave.open(io.BytesIO(data), "rb") as wav:
        if wav.getsampwidth() != 2:
            raise ValueError("16-bit PCM WAV 만 지원합니다.")
        return wav.readframes(wav.getnframes()), wav.getframerate(), wav.getnchannels()


def duration_seconds(pcm: bytes, *, sample_rate: int, channels: int = 1) -> float:
    """PCM16 바이트 길이 → 초."""
    bytes_per_sample = 2 * channels
    if bytes_per_sample == 0 or sample_rate == 0:
        return 0.0
    return len(pcm) / bytes_per_sample / sample_rate


def seconds_to_bytes(seconds: float, *, sample_rate: int, channels: int = 1) -> int:
    """초 → PCM16 바이트 길이 (샘플 경계에 정렬)."""
    frame = 2 * channels
    raw = int(seconds * sample_rate) * frame
    return raw - (raw % frame)


def make_data_url(pcm: bytes, *, sample_rate: int, channels: int = 1) -> str:
    """OpenAI known_speaker_references 가 요구하는 data URL 형태로 만든다."""
    import base64

    wav_bytes = pcm16_to_wav(pcm, sample_rate=sample_rate, channels=channels)
    encoded = base64.b64encode(wav_bytes).decode("ascii")
    return f"data:audio/wav;base64,{encoded}"


def resample_linear(pcm: bytes, *, src_rate: int, dst_rate: int) -> bytes:
    """모노 PCM16 선형보간 리샘플링.

    고품질 리샘플러가 필요한 곳(전사)에는 쓰지 않는다. 프로소디 분석처럼
    정확한 스펙트럼이 필요 없는 경로에서 연산량을 줄이려고 쓴다.
    """
    if src_rate == dst_rate or not pcm:
        return pcm

    src_count = len(pcm) // 2
    if src_count < 2:
        return pcm

    samples = struct.unpack(f"<{src_count}h", pcm[: src_count * 2])
    ratio = src_rate / dst_rate
    dst_count = int(src_count / ratio)
    out: list[int] = []

    for i in range(dst_count):
        pos = i * ratio
        idx = int(pos)
        frac = pos - idx
        if idx + 1 < src_count:
            value = samples[idx] * (1 - frac) + samples[idx + 1] * frac
        else:
            value = samples[idx]
        out.append(max(-32768, min(32767, int(value))))

    return struct.pack(f"<{len(out)}h", *out)
