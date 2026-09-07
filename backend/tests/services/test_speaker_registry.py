"""화자 레지스트리 테스트 — 세션 내 화자 정체성 유지가 핵심."""

from __future__ import annotations

import struct

from app.services.stt.diarize_client import DiarizedSegment
from app.services.stt.speaker_registry import SPEAKER_PALETTE, SpeakerRegistry

SAMPLE_RATE = 24_000


def _pcm(seconds: float) -> bytes:
    count = int(SAMPLE_RATE * seconds)
    return struct.pack(f"<{count}h", *([1000] * count))


def _segment(speaker: str, start: float, end: float, text: str) -> DiarizedSegment:
    return DiarizedSegment(speaker=speaker, text=text, start=start, end=end)


class TestSpeakerAssignment:
    def test_first_window_creates_profiles(self) -> None:
        registry = SpeakerRegistry(sample_rate=SAMPLE_RATE)

        resolved = registry.resolve_window(
            [
                _segment("A", 0.0, 3.0, "안녕하세요"),
                _segment("B", 3.5, 6.0, "네 반갑습니다"),
            ],
            window_pcm=_pcm(8.0),
            window_start_ms=0,
            overlap_ms=0,
        )

        assert len(resolved) == 2
        assert registry.speaker_count == 2
        assert [p.label for p in registry.profiles] == ["A", "B"]

    def test_colors_are_distinct_and_from_palette(self) -> None:
        registry = SpeakerRegistry(sample_rate=SAMPLE_RATE)
        registry.resolve_window(
            [
                _segment("A", 0.0, 2.0, "하나"),
                _segment("B", 2.0, 4.0, "둘"),
                _segment("C", 4.0, 6.0, "셋"),
            ],
            window_pcm=_pcm(8.0),
            window_start_ms=0,
            overlap_ms=0,
        )

        colors = [p.color_hex for p in registry.profiles]
        assert len(set(colors)) == 3
        assert all(c in SPEAKER_PALETTE for c in colors)

    def test_absolute_time_offset_is_applied(self) -> None:
        registry = SpeakerRegistry(sample_rate=SAMPLE_RATE)

        resolved = registry.resolve_window(
            [_segment("A", 1.0, 3.0, "테스트")],
            window_pcm=_pcm(8.0),
            window_start_ms=10_000,
            overlap_ms=0,
        )

        _, segment = resolved[0]
        assert segment.start_ms == 11_000
        assert segment.end_ms == 13_000

    def test_known_speaker_key_maps_to_existing_profile(self) -> None:
        """참조 클립을 넘기면 모델이 우리 키(S1)를 그대로 돌려준다."""
        registry = SpeakerRegistry(sample_rate=SAMPLE_RATE)
        registry.resolve_window(
            [_segment("A", 0.0, 4.0, "첫 발화입니다 안녕하세요")],
            window_pcm=_pcm(8.0),
            window_start_ms=0,
            overlap_ms=0,
        )
        original = registry.profiles[0]

        # 두 번째 창에서 모델이 "S1" 을 돌려준 상황
        resolved = registry.resolve_window(
            [_segment(original.key, 0.0, 3.0, "두 번째 발화")],
            window_pcm=_pcm(8.0),
            window_start_ms=11_000,
            overlap_ms=0,
        )

        assert registry.speaker_count == 1
        assert resolved[0][0].key == original.key


class TestOverlapLinking:
    def test_links_labels_across_windows_via_overlap(self) -> None:
        """참조 클립이 없을 때, 겹침 구간의 같은 발화로 라벨을 잇는다."""
        registry = SpeakerRegistry(sample_rate=SAMPLE_RATE)

        registry.resolve_window(
            [
                _segment("A", 0.0, 3.0, "오늘 날씨가 정말 좋네요"),
                _segment("B", 3.0, 5.0, "그러게요 산책하기 좋겠어요"),
            ],
            window_pcm=_pcm(8.0),
            window_start_ms=0,
            overlap_ms=0,
        )
        first_pass = {p.key for p in registry.profiles}
        assert len(first_pass) == 2

        # 다음 창: 모델이 라벨을 뒤집어 배정했다 (A↔B). 겹침 구간의 텍스트가
        # 같으므로 레지스트리가 이를 바로잡아야 한다.
        registry.resolve_window(
            [
                _segment("B", 0.0, 2.0, "그러게요 산책하기 좋겠어요"),
                _segment("A", 2.5, 5.0, "점심 뭐 드실래요"),
            ],
            window_pcm=_pcm(8.0),
            window_start_ms=3_000,
            overlap_ms=2_000,
        )

        # 새 화자가 생기지 않아야 한다 — 라벨이 제대로 이어졌다는 뜻.
        assert registry.speaker_count == 2

    def test_unmatched_label_creates_new_speaker(self) -> None:
        registry = SpeakerRegistry(sample_rate=SAMPLE_RATE)
        registry.resolve_window(
            [_segment("A", 0.0, 3.0, "첫 번째 사람")],
            window_pcm=_pcm(8.0),
            window_start_ms=0,
            overlap_ms=0,
        )
        registry.resolve_window(
            [_segment("Z", 0.0, 3.0, "완전히 다른 내용의 발화")],
            window_pcm=_pcm(8.0),
            window_start_ms=12_000,
            overlap_ms=0,
        )

        assert registry.speaker_count == 2

    def test_overlap_segments_are_not_counted_twice(self) -> None:
        """겹침 구간은 통계에 두 번 들어가면 안 된다."""
        registry = SpeakerRegistry(sample_rate=SAMPLE_RATE)
        registry.resolve_window(
            [_segment("A", 0.0, 4.0, "먼저 나온 발화")],
            window_pcm=_pcm(8.0),
            window_start_ms=0,
            overlap_ms=0,
        )

        registry.resolve_window(
            [
                # 겹침 구간에 완전히 들어가는 세그먼트 — 이미 세었다.
                _segment("A", 0.0, 1.5, "먼저 나온 발화"),
                _segment("A", 2.0, 4.0, "새로운 발화"),
            ],
            window_pcm=_pcm(8.0),
            window_start_ms=3_000,
            overlap_ms=2_000,
        )

        profile = registry.profiles[0]
        assert profile.utterance_count == 2, "겹침 세그먼트를 다시 세면 안 된다"

    def test_overlap_segments_are_not_emitted_twice(self) -> None:
        """겹침 구간은 앞 창에서 이미 내보냈다.

        화자분리 결과가 그대로 자막 줄이 되므로, 다시 내보내면 같은 말이 두
        줄로 뜬다.
        """
        registry = SpeakerRegistry(sample_rate=SAMPLE_RATE)
        registry.resolve_window(
            [_segment("A", 0.0, 4.0, "먼저 나온 발화")],
            window_pcm=_pcm(8.0),
            window_start_ms=0,
            overlap_ms=0,
        )

        resolved = registry.resolve_window(
            [
                _segment("A", 0.0, 1.5, "먼저 나온 발화"),
                _segment("A", 2.0, 4.0, "새로운 발화"),
            ],
            window_pcm=_pcm(8.0),
            window_start_ms=3_000,
            overlap_ms=2_000,
        )

        texts = [segment.text for _, segment in resolved]
        assert texts == ["새로운 발화"]


class TestReferenceCapture:
    def test_captures_reference_for_long_enough_segment(self) -> None:
        registry = SpeakerRegistry(sample_rate=SAMPLE_RATE)
        registry.resolve_window(
            [_segment("A", 0.0, 5.0, "충분히 긴 발화입니다")],
            window_pcm=_pcm(8.0),
            window_start_ms=0,
            overlap_ms=0,
        )

        references = registry.references()
        assert len(references) == 1
        assert references[0].name == registry.profiles[0].key
        assert len(references[0].pcm) > 0

    def test_skips_reference_for_too_short_segment(self) -> None:
        registry = SpeakerRegistry(sample_rate=SAMPLE_RATE)
        registry.resolve_window(
            [_segment("A", 0.0, 0.8, "짧아요")],
            window_pcm=_pcm(8.0),
            window_start_ms=0,
            overlap_ms=0,
        )

        assert registry.references() == []

    def test_reference_count_respects_openai_limit(self) -> None:
        """OpenAI 는 known_speaker_references 를 최대 4개까지만 받는다."""
        registry = SpeakerRegistry(sample_rate=SAMPLE_RATE)
        registry.resolve_window(
            [_segment(chr(ord("A") + i), i * 3.0, i * 3.0 + 2.5, f"발화 {i}") for i in range(6)],
            window_pcm=_pcm(20.0),
            window_start_ms=0,
            overlap_ms=0,
        )

        assert registry.speaker_count == 6
        assert len(registry.references()) <= 4

    def test_discard_references_wipes_biometric_audio(self) -> None:
        registry = SpeakerRegistry(sample_rate=SAMPLE_RATE)
        registry.resolve_window(
            [_segment("A", 0.0, 5.0, "참조로 쓰일 발화")],
            window_pcm=_pcm(8.0),
            window_start_ms=0,
            overlap_ms=0,
        )
        assert registry.references()

        registry.discard_references()

        assert registry.references() == []
        assert all(p.reference_pcm is None for p in registry.profiles)


class TestCustomization:
    def test_rename_and_recolor(self) -> None:
        registry = SpeakerRegistry(sample_rate=SAMPLE_RATE)
        registry.resolve_window(
            [_segment("A", 0.0, 3.0, "안녕")],
            window_pcm=_pcm(8.0),
            window_start_ms=0,
            overlap_ms=0,
        )
        key = registry.profiles[0].key

        registry.rename(key, "엄마")
        registry.recolor(key, "#FF0000")

        profile = registry.get(key)
        assert profile is not None
        assert profile.display_name == "엄마"
        assert profile.color_hex == "#FF0000"

    def test_empty_segments_returns_empty(self) -> None:
        registry = SpeakerRegistry(sample_rate=SAMPLE_RATE)
        assert registry.resolve_window([], window_pcm=b"", window_start_ms=0, overlap_ms=0) == []
