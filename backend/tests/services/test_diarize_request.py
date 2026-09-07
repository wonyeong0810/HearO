"""화자분리 요청의 전송 형식 테스트.

`known_speaker_references[]` 를 파일 파트로 올려서 API 가 창마다 400 으로
거부한 적이 있다.

    known_speaker_references[].0: Input should be a valid string

이게 오래 안 잡힌 이유는 **고장이 화면에 안 보이기 때문이다.** 참조 클립이
거부돼도 자막은 계속 흐르고(설계상 트랙이 분리돼 있다), 겹침 대조가 화자를
어느 정도는 이어 붙인다. 그래서 "가끔 색이 바뀌네" 정도로만 보이는데,
실제로는 화자 정체성 유지의 주력 방어가 통째로 빠진 상태다.

서버 로그를 열어야만 알 수 있는 종류의 고장이라 여기에 못박아 둔다.
"""

from __future__ import annotations

from typing import Any

import pytest

from app.core.config import settings
from app.services.stt.diarize_client import DiarizeClient, SpeakerReference


class _CapturedPost:
    """`_post_with_retry` 를 가로채 인자만 붙잡아 둔다."""

    def __init__(self) -> None:
        self.files: list[tuple[str, tuple[Any, ...]]] = []
        self.data: dict[str, Any] = {}

    async def __call__(
        self,
        *,
        files: list[tuple[str, tuple[Any, ...]]],
        data: dict[str, Any],
    ) -> dict[str, Any]:
        self.files = files
        self.data = data
        return {"segments": []}


@pytest.fixture
def captured(monkeypatch: pytest.MonkeyPatch) -> _CapturedPost:
    monkeypatch.setattr(settings, "openai_api_key", "sk-test", raising=False)
    return _CapturedPost()


@pytest.fixture
def client(captured: _CapturedPost, monkeypatch: pytest.MonkeyPatch) -> DiarizeClient:
    client = DiarizeClient()
    # 연결은 하지 않는다. HTTP 직전까지만 확인한다.
    monkeypatch.setattr(client, "_client", object(), raising=False)
    monkeypatch.setattr(client, "_post_with_retry", captured)
    return client


def _pcm(seconds: float = 2.0) -> bytes:
    return b"\x01\x00" * int(settings.audio_sample_rate * seconds)


class TestSpeakerReferences:
    async def test_references_are_sent_as_data_url_strings(
        self, client: DiarizeClient, captured: _CapturedPost
    ) -> None:
        await client.transcribe(
            _pcm(),
            references=[SpeakerReference(name="S1", pcm=_pcm())],
        )

        refs = captured.data["known_speaker_references[]"]
        assert isinstance(refs, list)
        assert all(isinstance(ref, str) for ref in refs), "문자열이 아니면 400 으로 거부된다"
        assert refs[0].startswith("data:audio/wav;base64,")

    async def test_references_never_go_into_the_files_part(
        self, client: DiarizeClient, captured: _CapturedPost
    ) -> None:
        # 이게 원래 버그였다. 파일 파트로 올리면 조용히 400 이 된다.
        await client.transcribe(
            _pcm(),
            references=[SpeakerReference(name="S1", pcm=_pcm())],
        )

        field_names = [name for name, _ in captured.files]
        assert "known_speaker_references[]" not in field_names
        assert field_names == ["file"]

    async def test_names_and_references_stay_in_the_same_order(
        self, client: DiarizeClient, captured: _CapturedPost
    ) -> None:
        # 순서가 어긋나면 모델이 다른 사람 목소리에 이름을 붙인다.
        await client.transcribe(
            _pcm(),
            references=[
                SpeakerReference(name="S1", pcm=_pcm()),
                SpeakerReference(name="S2", pcm=_pcm()),
                SpeakerReference(name="S3", pcm=_pcm()),
            ],
        )

        assert captured.data["known_speaker_names[]"] == ["S1", "S2", "S3"]
        assert len(captured.data["known_speaker_references[]"]) == 3

    async def test_reference_count_is_capped(
        self, client: DiarizeClient, captured: _CapturedPost
    ) -> None:
        """OpenAI 제약: 최대 4명. 넘겨 보내면 요청 전체가 거부된다."""
        await client.transcribe(
            _pcm(),
            references=[SpeakerReference(name=f"S{i}", pcm=_pcm()) for i in range(1, 8)],
        )

        assert len(captured.data["known_speaker_names[]"]) == settings.speaker_reference_max

    async def test_no_reference_keys_when_there_are_none(
        self, client: DiarizeClient, captured: _CapturedPost
    ) -> None:
        # 빈 배열을 보내면 "참조 없음"이 아니라 잘못된 값으로 읽힐 수 있다.
        await client.transcribe(_pcm())

        assert "known_speaker_names[]" not in captured.data
        assert "known_speaker_references[]" not in captured.data
