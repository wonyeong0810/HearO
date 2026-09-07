"""창 버퍼 / 타임라인 버퍼 테스트."""

from __future__ import annotations

import itertools
import math
import struct

import pytest

from app.services.audio.buffer import WindowBuffer
from app.services.audio.timeline import TimelineBuffer
from app.services.audio.wav import (
    duration_seconds,
    pcm16_to_wav,
    seconds_to_bytes,
    wav_to_pcm16,
)

SAMPLE_RATE = 24_000


def _tone(seconds: float, amplitude: float = 0.3, frequency: float = 200.0) -> bytes:
    count = int(SAMPLE_RATE * seconds)
    samples = [
        int(amplitude * 32767 * math.sin(2 * math.pi * frequency * i / SAMPLE_RATE))
        for i in range(count)
    ]
    return struct.pack(f"<{count}h", *samples)


def _silence(seconds: float) -> bytes:
    count = int(SAMPLE_RATE * seconds)
    return b"\x00\x00" * count


class TestWav:
    def test_roundtrip_preserves_samples(self) -> None:
        original = _tone(0.1)
        wav = pcm16_to_wav(original, sample_rate=SAMPLE_RATE)
        recovered, rate, channels = wav_to_pcm16(wav)

        assert recovered == original
        assert rate == SAMPLE_RATE
        assert channels == 1

    def test_odd_byte_count_is_truncated_not_corrupted(self) -> None:
        wav = pcm16_to_wav(_tone(0.05) + b"\x01", sample_rate=SAMPLE_RATE)
        recovered, _, _ = wav_to_pcm16(wav)
        assert len(recovered) % 2 == 0

    def test_duration_matches_input(self) -> None:
        assert duration_seconds(_tone(0.5), sample_rate=SAMPLE_RATE) == pytest.approx(0.5)

    def test_seconds_to_bytes_is_sample_aligned(self) -> None:
        assert seconds_to_bytes(0.333, sample_rate=SAMPLE_RATE) % 2 == 0


class TestWindowBuffer:
    def _buffer(self, **kwargs: object) -> WindowBuffer:
        defaults: dict[str, object] = {
            "sample_rate": SAMPLE_RATE,
            "window_seconds": 4.0,
            "overlap_seconds": 1.0,
            "silence_threshold_dbfs": -45.0,
        }
        defaults.update(kwargs)
        return WindowBuffer(**defaults)  # type: ignore[arg-type]

    def test_rejects_overlap_longer_than_window(self) -> None:
        with pytest.raises(ValueError, match="overlap"):
            WindowBuffer(sample_rate=SAMPLE_RATE, window_seconds=2.0, overlap_seconds=3.0)

    def test_no_window_before_target_length(self) -> None:
        buffer = self._buffer()
        assert buffer.push(_tone(2.0)) == []

    def test_emits_window_at_silence_after_target(self) -> None:
        buffer = self._buffer()

        assert buffer.push(_tone(4.5)) == []
        # 목표(4초)를 넘긴 뒤 무음이 오면 그 지점에서 자른다.
        windows = buffer.push(_silence(0.5))

        assert len(windows) == 1
        assert windows[0].duration_ms >= 4000

    def test_force_cuts_when_no_silence_found(self) -> None:
        buffer = self._buffer()
        # 무음 없이 계속 소리만 들어오면 상한(창+3초)에서 강제로 자른다.
        windows = buffer.push(_tone(8.0))

        assert len(windows) >= 1
        assert windows[0].duration_ms <= 7100

    def test_windows_overlap_as_configured(self) -> None:
        buffer = self._buffer()
        buffer.push(_tone(4.5))
        first = buffer.push(_silence(0.4))[0]

        buffer.push(_tone(4.5))
        second = buffer.push(_silence(0.4))[0]

        # 두 번째 창은 첫 번째 창의 끝부분과 겹쳐 시작한다.
        assert second.start_ms < first.end_ms
        assert second.overlap_ms > 0

    # ------------------------------------------------------- 말이 끊기면 일찍
    #
    # 목표 길이만 기준으로 삼으면 창이 (목표 - 겹침)초에 한 번만 닫혀서, 방금
    # 한 말의 화자가 화면에 붙기까지 평균 그 절반을 기다린다. 대화에는 원래
    # 쉼이 있으므로 그걸 경계로 쓰면 훨씬 빨라진다.
    #
    # 다만 아무 무음에서나 자르면 안 된다. 숨 고르기마다 창이 쪼개지면 API
    # 호출만 늘고, 정작 화자를 가를 근거(창 안의 오디오)는 얇아진다.

    def _early(self, **kwargs: object) -> WindowBuffer:
        defaults: dict[str, object] = {
            "window_seconds": 12.0,
            "overlap_seconds": 2.0,
            "min_window_seconds": 5.0,
            "early_cut_silence_ms": 400,
        }
        defaults.update(kwargs)
        return self._buffer(**defaults)

    def test_pause_after_min_length_closes_window_early(self) -> None:
        buffer = self._early()

        assert buffer.push(_tone(5.5)) == []
        windows = buffer.push(_silence(0.5))

        assert len(windows) == 1
        # 목표(12초)를 한참 안 채우고도 닫혔다.
        assert 5000 <= windows[0].duration_ms < 12_000

    def test_short_breath_does_not_split_the_window(self) -> None:
        # 200ms 는 문장 안의 숨 고르기지 발화의 끝이 아니다.
        buffer = self._early()

        assert buffer.push(_tone(5.5)) == []
        assert buffer.push(_silence(0.2)) == []
        assert buffer.push(_tone(1.0)) == []

    def test_pause_before_min_length_is_ignored(self) -> None:
        # 너무 짧은 창은 화자를 가를 근거가 부족하다.
        buffer = self._early()

        assert buffer.push(_tone(2.0)) == []
        assert buffer.push(_silence(1.0)) == []

    def test_still_cuts_at_target_when_nobody_pauses(self) -> None:
        # 쉼이 없으면 기존 동작 그대로 — 목표 이후 첫 무음, 없으면 상한.
        buffer = self._early()

        windows = buffer.push(_tone(16.0))

        assert len(windows) >= 1
        assert windows[0].duration_ms >= 12_000

    def test_early_windows_still_overlap(self) -> None:
        # 겹침이 없으면 앞 창과 라벨을 이어붙일 수 없다 — 일찍 닫는 것보다
        # 화자가 뒤바뀌는 쪽이 훨씬 나쁘다.
        buffer = self._early()

        buffer.push(_tone(5.5))
        first = buffer.push(_silence(0.5))[0]
        buffer.push(_tone(5.5))
        second = buffer.push(_silence(0.5))[0]

        assert second.start_ms < first.end_ms
        assert second.overlap_ms > 0

    def test_rejects_min_window_shorter_than_overlap(self) -> None:
        # 겹침보다 짧게 자르면 창이 앞으로 나아가지 못하고 같은 구간을 맴돈다.
        with pytest.raises(ValueError, match="min_window"):
            WindowBuffer(
                sample_rate=SAMPLE_RATE,
                window_seconds=12.0,
                overlap_seconds=2.0,
                min_window_seconds=1.5,
            )

    def test_timeline_is_continuous_across_windows(self) -> None:
        buffer = self._buffer()
        windows = []
        for _ in range(3):
            buffer.push(_tone(4.5))
            windows.extend(buffer.push(_silence(0.4)))

        assert len(windows) >= 2
        for previous, current in itertools.pairwise(windows):
            # 겹침이 있으므로 다음 창은 이전 창 끝보다 앞에서 시작한다.
            assert current.start_ms <= previous.end_ms
            assert current.start_ms >= previous.start_ms

    def test_flush_returns_remainder(self) -> None:
        buffer = self._buffer()
        buffer.push(_tone(2.0))

        window = buffer.flush()
        assert window is not None
        assert window.duration_ms == pytest.approx(2000, abs=50)

    def test_flush_discards_tiny_remainder(self) -> None:
        buffer = self._buffer()
        buffer.push(_tone(0.1))
        assert buffer.flush() is None

    def test_flush_on_empty_buffer(self) -> None:
        assert self._buffer().flush() is None

    def test_reset_clears_state(self) -> None:
        buffer = self._buffer()
        buffer.push(_tone(3.0))
        buffer.reset()

        assert buffer.buffered_seconds == 0
        assert buffer.flush() is None


class TestTimelineBuffer:
    def test_position_tracks_total_audio(self) -> None:
        timeline = TimelineBuffer(sample_rate=SAMPLE_RATE)
        timeline.push(_tone(1.0))
        timeline.push(_tone(0.5))

        assert timeline.position_ms == pytest.approx(1500, abs=20)

    def test_slice_returns_requested_range(self) -> None:
        timeline = TimelineBuffer(sample_rate=SAMPLE_RATE)
        timeline.push(_tone(3.0))

        chunk = timeline.slice(1000, 2000)
        assert duration_seconds(chunk, sample_rate=SAMPLE_RATE) == pytest.approx(1.0, abs=0.02)

    def test_slice_spanning_multiple_pushes(self) -> None:
        timeline = TimelineBuffer(sample_rate=SAMPLE_RATE)
        for _ in range(4):
            timeline.push(_tone(0.5))

        chunk = timeline.slice(250, 1750)
        assert duration_seconds(chunk, sample_rate=SAMPLE_RATE) == pytest.approx(1.5, abs=0.02)

    def test_old_audio_is_evicted(self) -> None:
        timeline = TimelineBuffer(sample_rate=SAMPLE_RATE, retain_seconds=2.0)
        for _ in range(6):
            timeline.push(_tone(1.0))

        # 6초를 넣었지만 2초만 남는다.
        assert timeline.earliest_ms >= 3500
        assert timeline.slice(0, 1000) == b""

    def test_tail_returns_most_recent_audio(self) -> None:
        timeline = TimelineBuffer(sample_rate=SAMPLE_RATE)
        timeline.push(_tone(5.0))

        chunk = timeline.tail(1.0)
        assert duration_seconds(chunk, sample_rate=SAMPLE_RATE) == pytest.approx(1.0, abs=0.02)

    def test_invalid_range_returns_empty(self) -> None:
        timeline = TimelineBuffer(sample_rate=SAMPLE_RATE)
        timeline.push(_tone(1.0))
        assert timeline.slice(500, 500) == b""
        assert timeline.slice(800, 200) == b""

    def test_slice_is_sample_aligned(self) -> None:
        timeline = TimelineBuffer(sample_rate=SAMPLE_RATE)
        timeline.push(_tone(2.0))
        assert len(timeline.slice(333, 777)) % 2 == 0
