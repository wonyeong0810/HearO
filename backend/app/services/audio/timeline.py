"""시간 축으로 잘라 쓸 수 있는 롤링 오디오 버퍼.

실시간 트랙은 "방금 발화가 끝났다"만 알려주고 오디오는 주지 않는다. 그런데
운율 분석을 하려면 그 발화 구간의 PCM 이 필요하다. 그래서 최근 N초를 들고
있다가 [start_ms, end_ms] 로 잘라 쓴다.

오디오를 영구 보관하지 않는다는 원칙은 그대로다 — 이 버퍼는 상한이 있고,
지난 구간은 계속 밀려나 사라진다.
"""

from __future__ import annotations

from collections import deque

from app.services.audio.wav import seconds_to_bytes


class TimelineBuffer:
    """세션 시작 기준 밀리초로 인덱싱되는 오디오 버퍼."""

    def __init__(
        self,
        *,
        sample_rate: int,
        channels: int = 1,
        retain_seconds: float = 45.0,
    ) -> None:
        self._sample_rate = sample_rate
        self._channels = channels
        self._frame = 2 * channels
        self._max_bytes = seconds_to_bytes(
            retain_seconds, sample_rate=sample_rate, channels=channels
        )
        # (구간 시작 오프셋 ms, pcm) 조각들
        self._chunks: deque[tuple[int, bytes]] = deque()
        self._buffered_bytes = 0
        # 다음에 들어올 오디오가 놓일 위치
        self._write_offset_bytes = 0

    # ----------------------------------------------------------------- props

    @property
    def position_ms(self) -> int:
        """지금까지 받은 오디오의 총 길이(ms). 세션 내 '현재 시각'."""
        return self._bytes_to_ms(self._write_offset_bytes)

    @property
    def earliest_ms(self) -> int:
        """아직 남아 있는 가장 오래된 오디오의 시작 지점(ms)."""
        if not self._chunks:
            return self.position_ms
        return self._bytes_to_ms(self._chunks[0][0])

    # ----------------------------------------------------------------- write

    def push(self, pcm: bytes) -> None:
        if not pcm:
            return
        self._chunks.append((self._write_offset_bytes, pcm))
        self._buffered_bytes += len(pcm)
        self._write_offset_bytes += len(pcm)
        self._evict()

    def _evict(self) -> None:
        while self._buffered_bytes > self._max_bytes and self._chunks:
            _, chunk = self._chunks.popleft()
            self._buffered_bytes -= len(chunk)

    def clear(self) -> None:
        self._chunks.clear()
        self._buffered_bytes = 0
        self._write_offset_bytes = 0

    # ----------------------------------------------------------------- read

    def slice(self, start_ms: int, end_ms: int) -> bytes:
        """[start_ms, end_ms) 구간의 PCM. 이미 밀려난 부분은 빠진 채로 온다."""
        if end_ms <= start_ms or not self._chunks:
            return b""

        start_byte = self._ms_to_bytes(start_ms)
        end_byte = self._ms_to_bytes(end_ms)

        out = bytearray()
        for chunk_start, chunk in self._chunks:
            chunk_end = chunk_start + len(chunk)
            if chunk_end <= start_byte:
                continue
            if chunk_start >= end_byte:
                break
            take_from = max(0, start_byte - chunk_start)
            take_to = min(len(chunk), end_byte - chunk_start)
            if take_to > take_from:
                out.extend(chunk[take_from:take_to])

        # 샘플 경계 정렬
        usable = len(out) - (len(out) % self._frame)
        return bytes(out[:usable])

    def tail(self, seconds: float) -> bytes:
        """가장 최근 N초."""
        end = self.position_ms
        return self.slice(max(0, end - int(seconds * 1000)), end)

    # ----------------------------------------------------------------- convert

    def _bytes_to_ms(self, n: int) -> int:
        if self._sample_rate == 0:
            return 0
        return int(n / self._frame / self._sample_rate * 1000)

    def _ms_to_bytes(self, ms: int) -> int:
        raw = int(ms / 1000 * self._sample_rate) * self._frame
        return max(0, raw)
