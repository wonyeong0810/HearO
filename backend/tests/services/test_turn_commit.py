"""발화 경계(turn commit) 테스트.

`gpt-live-transcribe` 는 `turn_detection` 을 거부해서 **서버 VAD 가 없다.**
아무도 `input_audio_buffer.commit` 을 보내지 않으면 모델은 delta 만 계속 흘리고
`input_audio_transcription.completed` 를 영영 보내지 않는다.

실제로 이 상태로 돌아간 적이 있다. 증상이 고약한 이유는 **고장처럼 안 보이기
때문이다** — 자막은 멀쩡히 흐르고(잠정), 인식도 잘 되고, 서버 로그에 에러도
없다. 다만 말을 멈춰도 기울임체가 안 풀리고, 세션이 끝나면
`utterances=0` 으로 통째로 사라진다.

여기서 지키는 것은 세 가지다.
  1. 말이 끝나고 무음이 이어지면 커밋한다
  2. 쉬지 않고 이어지는 말도 언젠가 끊는다
  3. 종료할 때 마지막 한 마디를 잃지 않는다
"""

from __future__ import annotations

import math
import struct
import uuid

import pytest

from app.core.config import settings
from app.services.stt.pipeline import LiveEvent, LivePipeline

_CHUNK_MS = 100


def _pcm(milliseconds: int, *, amplitude: int) -> bytes:
    """PCM16 mono 청크. amplitude 0 이면 완전한 무음."""
    count = int(settings.audio_sample_rate * milliseconds / 1000)
    if amplitude == 0:
        return b"\x00\x00" * count
    # 사인파 — 무음 판정(RMS 기반)을 확실히 넘기기 위한 신호.
    samples = (
        int(amplitude * math.sin(2 * math.pi * 440 * i / settings.audio_sample_rate))
        for i in range(count)
    )
    return struct.pack(f"<{count}h", *samples)


def _speech(milliseconds: int = _CHUNK_MS) -> bytes:
    return _pcm(milliseconds, amplitude=12000)


def _silence(milliseconds: int = _CHUNK_MS) -> bytes:
    return _pcm(milliseconds, amplitude=0)


class _FakeRealtime:
    """커밋 횟수만 세는 대역. 네트워크로 나가지 않는다."""

    def __init__(self) -> None:
        self.commits = 0
        self.audio_bytes = 0

    async def send_audio(self, pcm: bytes) -> bool:
        self.audio_bytes += len(pcm)
        return True

    async def commit(self) -> None:
        self.commits += 1


@pytest.fixture
def pipeline() -> LivePipeline:
    async def emit(_: LiveEvent) -> None:
        return None

    pipe = LivePipeline(
        session_id=uuid.uuid4(),
        emit=emit,
        diarize_client=object(),  # type: ignore[arg-type]  # 트랙 2 는 건드리지 않는다
        emotion_classifier=object(),  # type: ignore[arg-type]
    )
    pipe._running = True
    pipe._reset_turn_tracking()
    return pipe


@pytest.fixture
def realtime(pipeline: LivePipeline) -> _FakeRealtime:
    fake = _FakeRealtime()
    pipeline._realtime = fake  # type: ignore[assignment]
    return fake


async def _feed(pipeline: LivePipeline, chunks: list[bytes]) -> None:
    for chunk in chunks:
        await pipeline.push_audio(chunk)


class TestSilenceBoundary:
    async def test_silence_after_speech_commits(
        self, pipeline: LivePipeline, realtime: _FakeRealtime
    ) -> None:
        # 말 1초 → 무음 1초. 무음 임계(700ms)를 넘기므로 끊겨야 한다.
        await _feed(pipeline, [_speech()] * 10 + [_silence()] * 10)

        assert realtime.commits == 1

    async def test_speech_alone_does_not_commit(
        self, pipeline: LivePipeline, realtime: _FakeRealtime
    ) -> None:
        # 말하는 중에 끊으면 문장이 토막 난다.
        await _feed(pipeline, [_speech()] * 20)

        assert realtime.commits == 0

    async def test_silence_without_speech_does_not_commit(
        self, pipeline: LivePipeline, realtime: _FakeRealtime
    ) -> None:
        # 아무도 말하지 않은 무음을 커밋하면 빈 요청만 나간다 (돈과 지연).
        await _feed(pipeline, [_silence()] * 30)

        assert realtime.commits == 0

    async def test_short_pause_does_not_split_a_sentence(
        self, pipeline: LivePipeline, realtime: _FakeRealtime
    ) -> None:
        # 300ms 는 문장 안의 숨 고르기지 발화의 끝이 아니다.
        await _feed(pipeline, [_speech()] * 10 + [_silence()] * 3 + [_speech()] * 5)

        assert realtime.commits == 0

    async def test_two_utterances_commit_twice(
        self, pipeline: LivePipeline, realtime: _FakeRealtime
    ) -> None:
        await _feed(pipeline, [_speech()] * 5 + [_silence()] * 10)
        await _feed(pipeline, [_speech()] * 5 + [_silence()] * 10)

        assert realtime.commits == 2


class TestLongTurn:
    async def test_uninterrupted_speech_eventually_commits(
        self, pipeline: LivePipeline, realtime: _FakeRealtime
    ) -> None:
        """쉬지 않고 말해도 언젠가는 확정 자막이 나와야 한다.

        안 그러면 긴 발화가 통째로 잠정 상태에 갇혀서, 말이 길수록 화면이
        쓸모없어진다 — 정확히 반대로 동작해야 하는 상황이다.
        """
        seconds = int(settings.realtime_commit_max_turn_ms / 1000) + 1
        await _feed(pipeline, [_speech()] * (seconds * 10))

        assert realtime.commits >= 1


class TestFinalFlush:
    async def test_stop_commits_the_last_words(
        self, pipeline: LivePipeline, realtime: _FakeRealtime
    ) -> None:
        """종료 직전 한 마디를 잃지 않는다.

        사용자가 방금 한 말이라, 잃어버리면 가장 아쉬운 자리다.
        """
        await _feed(pipeline, [_speech()] * 5)
        assert realtime.commits == 0

        await pipeline._flush_pending_turn()

        assert realtime.commits == 1

    async def test_stop_without_speech_sends_nothing(
        self, pipeline: LivePipeline, realtime: _FakeRealtime
    ) -> None:
        await _feed(pipeline, [_silence()] * 5)
        await pipeline._flush_pending_turn()

        assert realtime.commits == 0

    async def test_stop_right_after_a_commit_sends_nothing(
        self, pipeline: LivePipeline, realtime: _FakeRealtime
    ) -> None:
        # 이미 끊긴 발화를 한 번 더 커밋하면 빈 버퍼로 거부당한다.
        await _feed(pipeline, [_speech()] * 5 + [_silence()] * 10)
        assert realtime.commits == 1

        await pipeline._flush_pending_turn()

        assert realtime.commits == 1


class TestTurnBounds:
    """커밋한 발화가 **오디오의 어디였는지** 정확히 남아야 한다.

    확정 자막은 커밋 뒤 API 왕복을 거쳐 도착한다. 도착 시점의 타임라인 위치를
    발화의 끝으로 삼고 글자 수로 시작점을 역산하면, 짧은 발화일수록 구간이
    통째로 **말이 끝난 뒤의 무음**에 얹힌다.

    그러면 화자분리 세그먼트와 시간이 하나도 안 겹쳐 화자가 영영 안 붙고,
    화면에는 `화자 확인 중…` 이 굳는다. 실제로 `어` 같은 한 음절만 골라서
    회색으로 남는 현상이 이것이었다 — 긴 문장은 역산 구간이 길어 우연히
    겹쳤을 뿐이다.
    """

    async def test_bounds_match_the_actual_audio(
        self, pipeline: LivePipeline, realtime: _FakeRealtime
    ) -> None:
        await _feed(pipeline, [_speech()] * 10 + [_silence()] * 10)

        assert len(pipeline._pending_turns) == 1
        start_ms, end_ms = pipeline._pending_turns[0]
        assert start_ms == pytest.approx(0, abs=150)
        assert end_ms == pytest.approx(1000, abs=150)

    async def test_trailing_silence_is_not_part_of_the_utterance(
        self, pipeline: LivePipeline, realtime: _FakeRealtime
    ) -> None:
        # 말 1초 + 무음 2초. 끝이 3초로 잡히면 구간의 3분의 2가 무음이 된다.
        await _feed(pipeline, [_speech()] * 10 + [_silence()] * 20)

        _, end_ms = pipeline._pending_turns[0]
        assert end_ms < 1500

    async def test_leading_silence_is_not_part_of_the_utterance(
        self, pipeline: LivePipeline, realtime: _FakeRealtime
    ) -> None:
        await _feed(pipeline, [_silence()] * 10 + [_speech()] * 10 + [_silence()] * 10)

        start_ms, end_ms = pipeline._pending_turns[0]
        assert start_ms == pytest.approx(1000, abs=150)
        assert end_ms == pytest.approx(2000, abs=150)

    async def test_a_one_syllable_utterance_still_gets_real_bounds(
        self, pipeline: LivePipeline, realtime: _FakeRealtime
    ) -> None:
        """`어` 처럼 짧은 말이 정확히 이 버그에 걸렸다."""
        await _feed(pipeline, [_speech(300)] + [_silence()] * 10)

        start_ms, end_ms = pipeline._pending_turns[0]
        assert end_ms - start_ms == pytest.approx(300, abs=150)
        assert start_ms == pytest.approx(0, abs=150)

    async def test_each_turn_is_recorded_separately(
        self, pipeline: LivePipeline, realtime: _FakeRealtime
    ) -> None:
        await _feed(pipeline, [_speech()] * 5 + [_silence()] * 10)
        await _feed(pipeline, [_speech()] * 5 + [_silence()] * 10)

        assert len(pipeline._pending_turns) == 2
        first, second = pipeline._pending_turns
        assert second[0] > first[1], "두 발화의 구간이 겹치면 화자가 뒤섞인다"


class TestMinimumBuffer:
    async def test_tiny_buffer_is_not_committed(
        self, pipeline: LivePipeline, realtime: _FakeRealtime
    ) -> None:
        """100ms 미만은 서버가 `input_audio_buffer_commit_empty` 로 거부한다.

        거부 자체는 치명적이지 않지만, 매 청크마다 오류가 돌아오면 로그가
        묻히고 진짜 문제를 못 보게 된다.
        """
        await _feed(pipeline, [_speech(20), _silence(50)])

        assert realtime.commits == 0

class TestNoisyRoom:
    """배경음이 계속 깔린 곳에서도 쉼을 찾아야 한다.

    절대 임계값 하나로만 판단하던 시절, 실제 측정에서 자막 대부분이 정확히
    길이 상한(그때는 15초)에 걸려 있었다. TV 가 켜진 방에서는 말 사이의 쉼조차
    임계값 위에 있어 **한 번도 쉼으로 안 잡혔기** 때문이다.

    그 결과 여러 사람의 말이 섞인 긴 오디오를 통째로 전사하게 되어 인식
    정확도가 눈에 띄게 떨어졌다. 배경음이 무엇이든 "말하다 멈추면 음량이 뚝
    떨어진다"는 사실은 변하지 않으므로, 최근 말소리 대비로도 판단한다.
    """

    async def test_pause_over_background_noise_is_found(
        self, pipeline: LivePipeline, realtime: _FakeRealtime
    ) -> None:
        # 배경음은 절대 임계값(-45dBFS)보다 훨씬 위에 있다.
        background = _pcm(_CHUNK_MS, amplitude=1200)

        await _feed(pipeline, [_speech()] * 10 + [background] * 10)

        assert realtime.commits == 1, "말소리보다 뚝 떨어졌으면 쉼이다"

    async def test_background_alone_does_not_commit(
        self, pipeline: LivePipeline, realtime: _FakeRealtime
    ) -> None:
        # 아무도 말하지 않은 배경음만으로 커밋하면 빈 요청이 계속 나간다.
        background = _pcm(_CHUNK_MS, amplitude=1200)

        await _feed(pipeline, [background] * 30)

        assert realtime.commits == 0

    async def test_quiet_speech_is_not_mistaken_for_a_pause(
        self, pipeline: LivePipeline, realtime: _FakeRealtime
    ) -> None:
        # 목소리가 조금 작아졌다고 문장을 자르면 안 된다. 문장 끝에서 힘이
        # 빠지는 것은 한국어에서 흔하다.
        await _feed(pipeline, [_speech()] * 10)
        await _feed(pipeline, [_pcm(_CHUNK_MS, amplitude=7000)] * 10)

        assert realtime.commits == 0

    async def test_long_turn_cap_bounds_the_provisional_line(self) -> None:
        # 잠정 줄이 화면을 넘길 만큼 길어지면 안 된다.
        assert settings.realtime_commit_max_turn_ms <= 15_000
