"""세션 내 화자 정체성 유지.

풀어야 할 문제: diarize 모델은 요청 사이에 화자를 기억하지 않는다. 12초짜리
창을 연달아 올리면 매번 "A", "B" 를 새로 배정하므로, 3번째 창의 A 가 1번째 창의
A 와 같은 사람이라는 보장이 없다. 자막 색이 대화 도중 뒤바뀌면 오히려 혼란을
주므로 반드시 고정해야 한다.

두 겹으로 해결한다.
  1) 참조 클립 고정 (주): 화자마다 깨끗한 2~8초 구간을 골라 두었다가 이후
     요청에 known_speaker_references 로 함께 올린다. 그러면 모델이 우리가 정한
     이름(S1, S2…)을 그대로 돌려준다. 모델 제약상 최대 4명까지.
  2) 겹침 대조 (보조): 참조가 아직 없거나 5번째 화자가 등장한 경우. 창 사이
     겹침 구간에 걸친 발화의 시간·텍스트를 대조해 이전 라벨과 이어붙인다.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from difflib import SequenceMatcher

from app.core.config import settings
from app.core.logging import get_logger
from app.services.stt.diarize_client import DiarizedSegment, SpeakerReference

log = get_logger(__name__)

# 색각이상(적록/청황)에서도 구분되는 팔레트.
# 기획서 예시(파랑/초록/보라)를 지키되, 명도까지 벌려 흑백에서도 구분되게 했다.
# 색만으로 화자를 구분하지 않는다 — 앱은 이름 라벨도 함께 표시한다.
SPEAKER_PALETTE: tuple[str, ...] = (
    "#2563EB",  # 파랑
    "#059669",  # 초록
    "#7C3AED",  # 보라
    "#EA580C",  # 주황
    "#0891B2",  # 청록
    "#DB2777",  # 자홍
    "#CA8A04",  # 황토
    "#4F46E5",  # 남색
)

# 참조 클립으로 쓸 구간이 만족해야 하는 조건
_MIN_REF_SECONDS = settings.speaker_reference_min_seconds
_MAX_REF_SECONDS = settings.speaker_reference_max_seconds

# 겹침 대조에서 같은 발화로 볼 텍스트 유사도 하한
_TEXT_MATCH_THRESHOLD = 0.62
# 겹침 대조에서 같은 발화로 볼 시간 오차(초)
_TIME_MATCH_TOLERANCE = 1.2

_WHITESPACE = re.compile(r"\s+")


def _normalize(text: str) -> str:
    return _WHITESPACE.sub(" ", text.strip().lower())


def _similarity(a: str, b: str) -> float:
    a_norm, b_norm = _normalize(a), _normalize(b)
    if not a_norm or not b_norm:
        return 0.0
    if a_norm == b_norm:
        return 1.0
    return SequenceMatcher(None, a_norm, b_norm).ratio()


@dataclass(slots=True)
class SpeakerProfile:
    """세션 전체에서 유효한 화자."""

    key: str  # "S1", "S2" … 모델에 넘기는 안정 식별자
    index: int  # 0-based 등장 순서
    color_hex: str
    display_name: str | None = None
    utterance_count: int = 0
    total_speaking_seconds: float = 0.0
    # 참조 클립 (등록되면 이후 요청에 계속 동봉된다)
    reference_pcm: bytes | None = None
    reference_quality: float = 0.0  # 클립 길이 기반 점수. 더 좋은 게 오면 교체.

    @property
    def label(self) -> str:
        """사용자에게 보이는 기본 라벨. 기획서의 '화자 A/B/C'."""
        return chr(ord("A") + self.index) if self.index < 26 else f"#{self.index + 1}"

    @property
    def has_reference(self) -> bool:
        return self.reference_pcm is not None


@dataclass(slots=True)
class _WindowMemory:
    """직전 창의 세그먼트 기억 (겹침 대조용).

    세그먼트는 **세션 절대 시간**으로 저장한다. 창 상대 시간으로 두면 다음 창과
    비교할 때 창 시작 오프셋을 매번 되짚어야 하고, 그 과정에서 오차가 생긴다.
    """

    segments: list[tuple[str, DiarizedSegment]] = field(default_factory=list)
    end_ms: int = 0


class SpeakerRegistry:
    """한 라이브 세션의 화자 상태.

    스레드 안전하지 않다 — 세션 하나당 인스턴스 하나, 단일 태스크에서만 만진다.
    """

    def __init__(self, *, sample_rate: int | None = None, channels: int | None = None) -> None:
        self._sample_rate = sample_rate or settings.audio_sample_rate
        self._channels = channels or settings.audio_channels
        self._profiles: dict[str, SpeakerProfile] = {}
        self._previous = _WindowMemory()
        self._next_index = 0

    # ----------------------------------------------------------------- state

    @property
    def profiles(self) -> list[SpeakerProfile]:
        return sorted(self._profiles.values(), key=lambda p: p.index)

    @property
    def speaker_count(self) -> int:
        return len(self._profiles)

    def get(self, key: str) -> SpeakerProfile | None:
        return self._profiles.get(key)

    def rename(self, key: str, display_name: str) -> None:
        if profile := self._profiles.get(key):
            profile.display_name = display_name

    def recolor(self, key: str, color_hex: str) -> None:
        if profile := self._profiles.get(key):
            profile.color_hex = color_hex

    def references(self) -> list[SpeakerReference]:
        """다음 요청에 동봉할 참조 클립 목록."""
        refs = [
            SpeakerReference(name=p.key, pcm=p.reference_pcm)
            for p in self.profiles
            if p.reference_pcm is not None
        ]
        return refs[: settings.speaker_reference_max]

    # ----------------------------------------------------------------- resolve

    def resolve_window(
        self,
        segments: list[DiarizedSegment],
        *,
        window_pcm: bytes,
        window_start_ms: int,
        overlap_ms: int,
    ) -> list[tuple[SpeakerProfile, DiarizedSegment]]:
        """창 하나의 세그먼트를 안정 화자에 묶는다.

        반환값의 세그먼트는 세션 시작 기준 절대 시간으로 이동되어 있다.
        """
        if not segments:
            return []

        mapping = self._build_mapping(segments, window_start_ms, overlap_ms)

        resolved: list[tuple[SpeakerProfile, DiarizedSegment]] = []
        memory: list[tuple[str, DiarizedSegment]] = []

        for segment in segments:
            profile = mapping.get(segment.speaker)
            if profile is None:
                # 매핑에 없는 라벨 — 새 화자로 등록
                profile = self._create_profile()
                mapping[segment.speaker] = profile

            absolute = segment.shifted(window_start_ms)
            memory.append((profile.key, absolute))

            # 겹침 구간의 세그먼트는 앞 창에서 이미 내보냈다. 이 결과가 곧
            # 자막 줄이 되므로, 다시 내보내면 같은 말이 두 줄로 뜬다.
            if overlap_ms > 0 and absolute.end_ms <= window_start_ms + overlap_ms:
                continue

            profile.utterance_count += 1
            profile.total_speaking_seconds += segment.duration
            resolved.append((profile, absolute))

            self._maybe_capture_reference(profile, segment, window_pcm)

        self._previous = _WindowMemory(
            segments=memory,
            end_ms=memory[-1][1].end_ms if memory else window_start_ms,
        )
        return resolved

    # ----------------------------------------------------------------- mapping

    def _build_mapping(
        self,
        segments: list[DiarizedSegment],
        window_start_ms: int,
        overlap_ms: int,
    ) -> dict[str, SpeakerProfile]:
        """모델이 이번 창에서 쓴 로컬 라벨 → 안정 프로필."""
        mapping: dict[str, SpeakerProfile] = {}
        local_labels = list(dict.fromkeys(s.speaker for s in segments))

        unmatched: list[str] = []
        for label in local_labels:
            # 1) 참조 클립을 넘겼다면 모델이 우리 키를 그대로 돌려준다.
            if profile := self._profiles.get(label):
                mapping[label] = profile
            else:
                unmatched.append(label)

        if not unmatched:
            return mapping

        # 2) 겹침 구간 대조
        if overlap_ms > 0 and self._previous.segments:
            linked = self._link_by_overlap(segments, unmatched, window_start_ms, overlap_ms)
            for label, profile in linked.items():
                # 이미 다른 로컬 라벨이 같은 프로필을 가져갔으면 충돌이므로 건너뛴다.
                if profile.key not in {p.key for p in mapping.values()}:
                    mapping[label] = profile

        # 3) 소거법 (겹침이 있어 창이 실제로 이어진 경우에만)
        if overlap_ms > 0 and self._previous.segments:
            self._link_by_elimination(mapping, local_labels)

        # 4) 그래도 남으면 새 화자
        for label in unmatched:
            if label not in mapping:
                mapping[label] = self._create_profile()

        return mapping

    def _link_by_elimination(
        self, mapping: dict[str, SpeakerProfile], local_labels: list[str]
    ) -> None:
        """남은 로컬 라벨 하나를 남은 기존 화자 하나에 소거법으로 잇는다.

        겹침 대조는 겹침 구간에 발화가 걸린 화자만 이어줄 수 있다. 이번 창에서
        처음 입을 연 사람은 대조할 상대가 없어 늘 새 화자가 되어버리는데, 이게
        참조 클립이 없는 상황에서 색이 계속 늘어나는 주된 원인이다.

        안전 조건을 걸어 보수적으로만 적용한다.
          - 앞 창과 실제로 겹쳐 있을 것 (호출부에서 검사). 겹침이 없다면 두 창
            사이에 시간 공백이 있다는 뜻이고, 그 사이 화자가 바뀌었을 수 있어
            "같은 사람들"이라는 전제 자체가 성립하지 않는다.
          - 이번 창의 화자 수가 이미 아는 화자 수와 정확히 같을 것
            (새 사람이 들어왔다면 수가 늘어난다)
          - 못 붙인 로컬 라벨이 정확히 하나, 안 쓰인 기존 화자도 정확히 하나
        조건이 하나라도 어긋나면 아무것도 하지 않고 새 화자를 만들게 둔다.
        같은 사람을 두 색으로 쪼개는 것보다, 다른 사람을 한 색으로 합치는 쪽이
        사용자에게 더 해롭기 때문이다.
        """
        if len(local_labels) != len(self._profiles):
            return

        remaining_labels = [label for label in local_labels if label not in mapping]
        if len(remaining_labels) != 1:
            return

        assigned_keys = {profile.key for profile in mapping.values()}
        remaining_profiles = [p for p in self.profiles if p.key not in assigned_keys]
        if len(remaining_profiles) != 1:
            return

        label, profile = remaining_labels[0], remaining_profiles[0]
        mapping[label] = profile
        log.debug("speaker_linked_by_elimination", local=label, stable=profile.key)

    def _link_by_overlap(
        self,
        segments: list[DiarizedSegment],
        unmatched: list[str],
        window_start_ms: int,
        overlap_ms: int,
    ) -> dict[str, SpeakerProfile]:
        """겹침 구간에 걸친 발화를 앞 창의 같은 발화와 대조해 라벨을 잇는다."""
        overlap_end = overlap_ms / 1000.0

        # 이번 창에서 겹침 구간에 걸친 세그먼트
        candidates = [s for s in segments if s.start < overlap_end and s.speaker in unmatched]
        if not candidates:
            return {}

        # 앞 창의 끝부분 세그먼트 (겹침 구간에 해당)
        previous_tail = self._previous.segments[-12:]
        if not previous_tail:
            return {}

        # (로컬 라벨, 안정 키) 쌍마다 점수를 모아 최댓값으로 결정한다.
        scores: dict[tuple[str, str], float] = {}

        for segment in candidates:
            # 이번 창의 상대시간 → 세션 절대시간
            abs_start = (window_start_ms + segment.start_ms) / 1000.0
            for prev_key, prev_seg in previous_tail:
                # 앞 창 세그먼트는 이미 절대 시간으로 저장되어 있다.
                prev_abs_start = prev_seg.start
                text_score = _similarity(segment.text, prev_seg.text)
                if text_score < _TEXT_MATCH_THRESHOLD:
                    continue
                time_delta = abs(abs_start - prev_abs_start)
                if time_delta > _TIME_MATCH_TOLERANCE:
                    # 시간이 크게 어긋나면 텍스트가 비슷해도 다른 발화로 본다
                    # (같은 인사말이 반복되는 상황 등).
                    continue
                score = text_score * (1.0 - time_delta / (_TIME_MATCH_TOLERANCE * 2))
                pair = (segment.speaker, prev_key)
                scores[pair] = max(scores.get(pair, 0.0), score)

        # 점수 높은 쌍부터 그리디 매칭 (1:1 유지)
        linked: dict[str, SpeakerProfile] = {}
        used_keys: set[str] = set()
        for (local_label, stable_key), _score in sorted(
            scores.items(), key=lambda kv: kv[1], reverse=True
        ):
            if local_label in linked or stable_key in used_keys:
                continue
            profile = self._profiles.get(stable_key)
            if profile is None:
                continue
            linked[local_label] = profile
            used_keys.add(stable_key)
            log.debug("speaker_linked_by_overlap", local=local_label, stable=stable_key)

        return linked

    def _create_profile(self) -> SpeakerProfile:
        index = self._next_index
        self._next_index += 1
        key = f"S{index + 1}"
        profile = SpeakerProfile(
            key=key,
            index=index,
            color_hex=SPEAKER_PALETTE[index % len(SPEAKER_PALETTE)],
        )
        self._profiles[key] = profile
        log.info("speaker_registered", key=key, label=profile.label, index=index)
        return profile

    # ----------------------------------------------------------------- reference

    def _maybe_capture_reference(
        self,
        profile: SpeakerProfile,
        segment: DiarizedSegment,
        window_pcm: bytes,
    ) -> None:
        """이 세그먼트가 참조 클립으로 쓸 만하면 저장한다.

        조건: 길이가 2~8초이고, 앞뒤로 다른 화자가 붙어있지 않은 깨끗한 구간.
        (세그먼트 경계는 화자 전환점이므로 세그먼트 자체가 곧 단일 화자 구간이다)
        """
        # 참조 슬롯이 이미 꽉 찼고 이 화자가 그 안에 없으면 등록하지 않는다.
        if (
            not profile.has_reference
            and sum(1 for p in self._profiles.values() if p.has_reference)
            >= settings.speaker_reference_max
        ):
            return

        duration = segment.duration
        if duration < _MIN_REF_SECONDS:
            return

        # 더 나은 클립이 아니면 교체하지 않는다.
        # 품질 점수는 4초에 가까울수록 높게 (너무 짧으면 정보 부족, 너무 길면 낭비).
        quality = 1.0 - abs(min(duration, _MAX_REF_SECONDS) - 4.0) / 4.0
        if profile.has_reference and quality <= profile.reference_quality + 0.1:
            return

        frame = 2 * self._channels
        start_byte = int(segment.start * self._sample_rate) * frame
        take_seconds = min(duration, _MAX_REF_SECONDS)
        length = int(take_seconds * self._sample_rate) * frame

        clip = window_pcm[start_byte : start_byte + length]
        actual_seconds = len(clip) / frame / self._sample_rate
        if actual_seconds < _MIN_REF_SECONDS:
            return

        profile.reference_pcm = clip
        profile.reference_quality = quality
        log.info(
            "speaker_reference_captured",
            key=profile.key,
            seconds=round(actual_seconds, 2),
            quality=round(quality, 2),
        )

    # ----------------------------------------------------------------- cleanup

    def discard_references(self) -> None:
        """세션 종료 시 성문에 해당하는 오디오를 즉시 폐기한다.

        참조 클립은 생체정보이므로 DB 에 남기지 않고 여기서 끝난다.
        """
        for profile in self._profiles.values():
            profile.reference_pcm = None
            profile.reference_quality = 0.0
