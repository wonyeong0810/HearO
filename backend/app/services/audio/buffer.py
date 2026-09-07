"""화자분리 트랙용 오디오 창 버퍼.

실시간 트랙은 오디오를 그대로 흘려보내지만, 화자분리 트랙은 파일 단위
API 이므로 오디오를 일정 길이로 잘라 모아야 한다. 이 클래스가 그 경계를 잡는다.

경계 전략:
  - **말이 끊기면 일찍 뱉는다.** 최소 길이(기본 5초)를 넘긴 뒤 충분한 쉼
    (기본 400ms)이 나오면 목표 길이를 기다리지 않고 창을 닫는다.
  - 목표 길이(기본 12초)에 도달하면, 쉼이 없어도 창을 하나 뱉는다.
  - 단, 말 중간에서 자르면 화자 라벨이 흔들리므로 무음 지점을 우선한다.
    목표 길이 이후 최대 3초까지 무음을 기다렸다가, 못 찾으면 그냥 자른다.
  - 창 사이에 약간의 겹침(기본 2초)을 둔다. 겹침 구간의 화자 라벨을 비교해
    이전 창과 이번 창의 라벨을 이어붙일 수 있다.

첫 번째 규칙이 화자 확정 지연을 좌우한다. 목표 길이만 기준으로 삼으면 창이
10초에 한 번(12초 - 2초 겹침)만 닫혀서, 방금 한 말의 화자가 붙기까지 평균
5초를 기다린다. 대화에는 원래 쉼이 있으므로 그걸 경계로 쓰면 훨씬 빨라진다.

대신 API 호출이 늘어난다. 최소 길이를 너무 낮추면 창이 짧아져 **화자를 가를
근거 자체가 부족해지고**, 호출 수만 늘어 비용이 오른다. 5초는 그 사이에서 고른
값이다.

메모리 상한이 있다 — 무음 대기 중에도 버퍼가 무한정 자라지 않는다.
"""

from __future__ import annotations

from dataclasses import dataclass

from app.services.audio import prosody
from app.services.audio.wav import duration_seconds, seconds_to_bytes


@dataclass(slots=True)
class AudioWindow:
    """전사에 넘길 오디오 한 조각."""

    pcm: bytes
    # 세션 시작 기준 이 창의 시작 오프셋(ms)
    start_ms: int
    end_ms: int
    # 앞 창과 겹치는 구간의 길이(ms). 라벨 이어붙이기에 쓴다.
    overlap_ms: int

    @property
    def duration_ms(self) -> int:
        return self.end_ms - self.start_ms


class WindowBuffer:
    """PCM 을 받아 창 단위로 뱉는 버퍼."""

    # 목표 길이를 넘긴 뒤 무음을 기다리는 최대 시간
    _SILENCE_GRACE_SECONDS = 3.0
    # 무음 탐색 시 훑는 조각 길이
    _SILENCE_PROBE_MS = 120

    def __init__(
        self,
        *,
        sample_rate: int,
        channels: int = 1,
        window_seconds: float = 12.0,
        overlap_seconds: float = 2.0,
        silence_threshold_dbfs: float = -45.0,
        min_window_seconds: float = 5.0,
        early_cut_silence_ms: int = 400,
    ) -> None:
        if overlap_seconds >= window_seconds:
            raise ValueError("overlap 은 window 보다 짧아야 합니다.")
        if min_window_seconds <= overlap_seconds:
            # 겹침보다 짧게 자르면 창이 앞으로 나아가지 못한다.
            raise ValueError("min_window 는 overlap 보다 길어야 합니다.")

        self._sample_rate = sample_rate
        self._channels = channels
        self._window_seconds = window_seconds
        self._overlap_seconds = overlap_seconds
        self._silence_threshold = silence_threshold_dbfs
        self._early_cut_silence_ms = early_cut_silence_ms

        self._target_bytes = seconds_to_bytes(
            window_seconds, sample_rate=sample_rate, channels=channels
        )
        self._min_bytes = seconds_to_bytes(
            min(min_window_seconds, window_seconds),
            sample_rate=sample_rate,
            channels=channels,
        )
        self._max_bytes = seconds_to_bytes(
            window_seconds + self._SILENCE_GRACE_SECONDS,
            sample_rate=sample_rate,
            channels=channels,
        )
        self._overlap_bytes = seconds_to_bytes(
            overlap_seconds, sample_rate=sample_rate, channels=channels
        )

        self._buffer = bytearray()
        # 현재 버퍼 첫 바이트가 세션 시작 기준 몇 ms 지점인지
        self._buffer_start_ms = 0
        # 이번 버퍼 앞부분 중 앞 창과 겹치는 길이
        self._pending_overlap_ms = 0
        self._total_bytes_seen = 0

    # ----------------------------------------------------------------- props

    @property
    def buffered_seconds(self) -> float:
        return duration_seconds(
            bytes(self._buffer), sample_rate=self._sample_rate, channels=self._channels
        )

    @property
    def total_seconds_seen(self) -> float:
        return duration_seconds(
            b"\x00" * self._total_bytes_seen,
            sample_rate=self._sample_rate,
            channels=self._channels,
        )

    # ----------------------------------------------------------------- write

    def push(self, pcm: bytes) -> list[AudioWindow]:
        """오디오를 넣고, 완성된 창이 있으면 돌려준다."""
        self._buffer.extend(pcm)
        self._total_bytes_seen += len(pcm)

        windows: list[AudioWindow] = []
        while True:
            window = self._try_emit()
            if window is None:
                break
            windows.append(window)
        return windows

    def flush(self) -> AudioWindow | None:
        """세션 종료 시 남은 오디오를 마지막 창으로 뱉는다.

        너무 짧으면(0.4초 미만) 전사할 게 없으므로 버린다.
        """
        if not self._buffer:
            return None

        min_bytes = seconds_to_bytes(0.4, sample_rate=self._sample_rate, channels=self._channels)
        if len(self._buffer) < min_bytes:
            self._buffer.clear()
            return None

        pcm = bytes(self._buffer)
        window = AudioWindow(
            pcm=pcm,
            start_ms=self._buffer_start_ms,
            end_ms=self._buffer_start_ms + self._bytes_to_ms(len(pcm)),
            overlap_ms=self._pending_overlap_ms,
        )
        self._buffer.clear()
        self._pending_overlap_ms = 0
        return window

    def reset(self) -> None:
        self._buffer.clear()
        self._buffer_start_ms = 0
        self._pending_overlap_ms = 0
        self._total_bytes_seen = 0

    # ----------------------------------------------------------------- internal

    def _bytes_to_ms(self, n: int) -> int:
        return int(
            duration_seconds(b"\x00" * n, sample_rate=self._sample_rate, channels=self._channels)
            * 1000
        )

    def _try_emit(self) -> AudioWindow | None:
        if len(self._buffer) < self._min_bytes:
            return None

        cut = self._find_cut_point()
        if cut is None:
            return None

        pcm = bytes(self._buffer[:cut])
        start_ms = self._buffer_start_ms
        end_ms = start_ms + self._bytes_to_ms(cut)
        overlap_ms = self._pending_overlap_ms

        # 겹침만큼 남기고 소비한다. 다음 창은 겹침 구간부터 시작한다.
        keep_from = max(0, cut - self._overlap_bytes)
        consumed = keep_from
        del self._buffer[:consumed]

        self._buffer_start_ms = start_ms + self._bytes_to_ms(consumed)
        self._pending_overlap_ms = self._bytes_to_ms(cut - keep_from)

        return AudioWindow(pcm=pcm, start_ms=start_ms, end_ms=end_ms, overlap_ms=overlap_ms)

    def _find_cut_point(self) -> int | None:
        """자를 바이트 위치를 고른다. 무음 지점을 우선한다."""
        # 상한을 넘었으면 무음이든 아니든 자른다.
        if len(self._buffer) >= self._max_bytes:
            return self._align(self._max_bytes)

        probe_bytes = seconds_to_bytes(
            self._SILENCE_PROBE_MS / 1000, sample_rate=self._sample_rate, channels=self._channels
        )
        if probe_bytes <= 0:
            if len(self._buffer) < self._target_bytes:
                return None
            return self._align(self._target_bytes)

        # 목표 길이 전이라면 **충분한 쉼**에서만 자른다. 짧은 무음 하나로 자르면
        # 숨 고르기마다 창이 쪼개져 API 호출만 늘고 화자 판단 근거는 얇아진다.
        if len(self._buffer) < self._target_bytes:
            return self._find_pause_cut(probe_bytes)

        # 목표 길이를 넘었다면 첫 무음 조각에서 바로 자른다.
        pos = self._target_bytes
        while pos + probe_bytes <= len(self._buffer):
            chunk = bytes(self._buffer[pos : pos + probe_bytes])
            if self._is_silent(chunk):
                # 무음 조각의 중간에서 자른다.
                return self._align(pos + probe_bytes // 2)
            pos += probe_bytes

        # 아직 무음을 못 찾았고 상한에도 안 닿았다 → 더 기다린다.
        return None

    def _find_pause_cut(self, probe_bytes: int) -> int | None:
        """최소 길이 이후 구간에서 `early_cut_silence_ms` 이상 이어지는 쉼을 찾는다.

        찾으면 그 쉼의 중간을 잘라 창을 일찍 닫는다 — 화자 라벨이 그만큼 빨리
        화면에 붙는다.
        """
        needed = max(1, self._early_cut_silence_ms // self._SILENCE_PROBE_MS)

        pos = self._min_bytes
        run_start: int | None = None
        run = 0

        while pos + probe_bytes <= len(self._buffer):
            if self._is_silent(bytes(self._buffer[pos : pos + probe_bytes])):
                if run_start is None:
                    run_start = pos
                run += 1
                if run >= needed:
                    assert run_start is not None
                    return self._align(run_start + (run * probe_bytes) // 2)
            else:
                run_start = None
                run = 0
            pos += probe_bytes

        return None

    def _is_silent(self, chunk: bytes) -> bool:
        return prosody.is_silent(
            chunk,
            sample_rate=self._sample_rate,
            threshold_dbfs=self._silence_threshold,
        )

    def _align(self, n: int) -> int:
        """샘플 경계에 맞춘다."""
        frame = 2 * self._channels
        n = min(n, len(self._buffer))
        return n - (n % frame)
