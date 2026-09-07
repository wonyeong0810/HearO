"""확정 자막을 **누가 만드는가**에 대한 테스트.

예전에는 실시간 트랙(`gpt-live-transcribe`)이 자막 텍스트를 만들고, 화자분리
트랙(`gpt-4o-transcribe-diarize`)은 화자 라벨만 얹었다. 두 모델은 발화를 서로
다르게 끊으므로 "이 자막 줄이 저 화자 구간과 같은 말인가"를 시간과 텍스트
유사도로 짜맞춰야 했고, 그 짜맞추는 코드가 계속 틀렸다.

측정해 보니 근거가 분명했다 — 화자분리 트랙이 돌려준 문장이 실시간 트랙보다
정확했다. 12~15초 창을 화자 정보와 함께 통째로 보기 때문이다. 반면 실시간
트랙은 우리가 임의로 끊어 준 조각만 본다.

그래서 **확정 자막은 화자분리 트랙이 만든다.** 실시간 트랙은 화면 아래
잠정 줄만 담당한다.

다만 부분 실패가 전체 실패가 되면 안 된다. 화자분리가 죽거나 늦으면 실시간
텍스트로라도 자막을 띄운다 — 화자를 모르는 자막이 자막이 없는 것보다 낫다.
"""

from __future__ import annotations

import uuid
from typing import Any

import pytest

from app.services.stt.diarize_client import DiarizedSegment
from app.services.stt.pipeline import LiveEvent, LiveEventType, LivePipeline
from app.services.stt.speaker_registry import SpeakerProfile


def _segment(speaker: str, start: float, end: float, text: str) -> DiarizedSegment:
    return DiarizedSegment(speaker=speaker, text=text, start=start, end=end)


def _spans(
    pipeline: LivePipeline, *pairs: tuple[str, DiarizedSegment]
) -> list[tuple[SpeakerProfile, Any]]:
    """화자분리 결과 흉내. 실제 경로처럼 레지스트리에도 등록해 둔다."""
    keys = sorted({key for key, _ in pairs})
    profiles = {
        key: SpeakerProfile(key=key, index=i, color_hex="#2563EB")
        for i, key in enumerate(keys)
    }
    pipeline._registry._profiles.update(profiles)
    return [(profiles[key], segment) for key, segment in pairs]


@pytest.fixture
def events() -> list[LiveEvent]:
    return []


@pytest.fixture
def pipeline(events: list[LiveEvent]) -> LivePipeline:
    async def emit(event: LiveEvent) -> None:
        events.append(event)

    pipe = LivePipeline(
        session_id=uuid.uuid4(),
        emit=emit,
        diarize_client=object(),  # type: ignore[arg-type]
        emotion_classifier=object(),  # type: ignore[arg-type]
    )
    pipe._running = True
    return pipe


class TestDiarizeOwnsCaptions:
    async def test_each_segment_becomes_its_own_line(
        self, pipeline: LivePipeline, events: list[LiveEvent]
    ) -> None:
        await pipeline._publish_segments(
            _spans(
                pipeline,
                ("S1", _segment("A", 0.0, 3.0, "네 알겠습니다")),
                ("S2", _segment("B", 3.0, 6.0, "아니 그건 좀 아닌데요")),
            )
        )

        assert [u.text for u in pipeline._utterances] == [
            "네 알겠습니다",
            "아니 그건 좀 아닌데요",
        ]
        assert [u.speaker_key for u in pipeline._utterances] == ["S1", "S2"]

    async def test_speaker_is_set_from_the_start(
        self, pipeline: LivePipeline, events: list[LiveEvent]
    ) -> None:
        """`화자 확인 중…` 상태가 아예 생기지 않는다.

        화자와 텍스트가 같은 응답에서 함께 오므로 나중에 붙일 것이 없다.
        """
        await pipeline._publish_segments(
            _spans(pipeline, ("S1", _segment("A", 0.0, 3.0, "안녕하세요")))
        )

        assert pipeline._utterances[0].speaker_resolved is True
        assert events[0].type is LiveEventType.CAPTION_FINAL
        assert events[0].data["speaker"] is not None

    async def test_lines_come_out_in_spoken_order(
        self, pipeline: LivePipeline, events: list[LiveEvent]
    ) -> None:
        await pipeline._publish_segments(
            _spans(
                pipeline,
                ("S2", _segment("B", 5.0, 8.0, "나중")),
                ("S1", _segment("A", 0.0, 3.0, "먼저")),
            )
        )

        assert [u.text for u in pipeline._utterances] == ["먼저", "나중"]

    async def test_overlapping_speech_still_makes_two_lines(
        self, pipeline: LivePipeline, events: list[LiveEvent]
    ) -> None:
        # 겹쳐 말하면 모델이 시간이 겹치는 두 세그먼트를 돌려준다. 그대로
        # 두 줄이 된다 — 예전처럼 한 줄로 뭉치지 않는다.
        await pipeline._publish_segments(
            _spans(
                pipeline,
                ("S1", _segment("A", 0.0, 5.0, "그러니까 내 말은")),
                ("S2", _segment("B", 3.0, 8.0, "아니 잠깐만요")),
            )
        )

        assert len(pipeline._utterances) == 2
        assert [u.speaker_key for u in pipeline._utterances] == ["S1", "S2"]

    async def test_empty_segment_makes_no_line(
        self, pipeline: LivePipeline, events: list[LiveEvent]
    ) -> None:
        await pipeline._publish_segments(
            _spans(
                pipeline,
                ("S1", _segment("A", 0.0, 3.0, "안녕하세요")),
                ("S2", _segment("B", 3.0, 4.0, "   ")),
            )
        )

        assert len(pipeline._utterances) == 1


class TestFallbackWhenDiarizeFails:
    """화자분리가 죽어도 자막은 계속 흘러야 한다."""

    async def test_uncovered_text_is_published_as_unknown_speaker(
        self, pipeline: LivePipeline, events: list[LiveEvent]
    ) -> None:
        pipeline._provisional = [(0, 3000, "화자분리가 못 본 말")]

        await pipeline._flush_provisional(covered_to_ms=0, force=True)

        assert pipeline._utterances[0].text == "화자분리가 못 본 말"
        assert pipeline._utterances[0].speaker_key is None
        # 더 기다려도 화자는 안 오므로 회색으로 붙들지 않는다.
        assert pipeline._utterances[0].speaker_resolved is True

    async def test_covered_text_is_dropped(
        self, pipeline: LivePipeline, events: list[LiveEvent]
    ) -> None:
        # 화자분리가 그 구간을 이미 다뤘으면 같은 말이 두 줄로 뜨면 안 된다.
        pipeline._provisional = [(0, 3000, "이미 화자분리가 다룬 말")]

        await pipeline._flush_provisional(covered_to_ms=5000)

        assert pipeline._utterances == []
        assert pipeline._provisional == []

    async def test_recent_text_waits_for_diarize(
        self, pipeline: LivePipeline, events: list[LiveEvent]
    ) -> None:
        # 방금 한 말은 화자분리 결과를 기다린다. 성급히 띄우면 화자 있는 줄이
        # 뒤이어 나와 같은 말이 두 번 보인다.
        pipeline._timeline.push(b"\x00\x00" * 24_000)  # 1초 진행
        pipeline._provisional = [(0, 900, "방금 한 말")]

        await pipeline._flush_provisional(covered_to_ms=0)

        assert pipeline._utterances == []
        assert len(pipeline._provisional) == 1
