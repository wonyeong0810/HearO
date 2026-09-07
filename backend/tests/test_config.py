"""설정 로딩 테스트.

여기서 잡는 회귀는 실제로 한 번 터졌던 것이다: pydantic-settings 는 list 로
선언된 필드를 환경변수에서 읽을 때 JSON 으로 파싱하려 들기 때문에,
`ALLOWED_HOSTS=*` 처럼 평범한 값이 JSONDecodeError 를 내며 서버가 아예 부팅되지
않았다. `.env.example` 을 그대로 복사하면 바로 겪는 문제라 치명적이었다.
"""

from __future__ import annotations

import os
from collections.abc import Callable

import pytest

from app.core.config import Settings

# 테스트가 개발자 셸이나 .env 에 영향받지 않도록 지워야 하는 접두사들.
_MANAGED_PREFIXES = (
    "ENVIRONMENT",
    "DEBUG",
    "LOG_",
    "OPENAI_",
    "EMOTION_",
    "STT_",
    "POSTGRES_",
    "DATABASE_",
    "REDIS_",
    "JWT_",
    "CORS_",
    "ALLOWED_",
    "AUDIO_",
    "DIARIZE_",
    "SPEAKER_",
    "SILENCE_",
    "RATE_",
    "FCM_",
    "FIREBASE_",
)

BuildSettings = Callable[..., Settings]


@pytest.fixture
def build_settings(monkeypatch: pytest.MonkeyPatch) -> BuildSettings:
    """환경변수만으로 Settings 를 만든다.

    `.env` 파일은 읽지 않고(`_env_file=None`), 기존 환경변수도 지운 뒤 시작한다.
    그러지 않으면 개발자 셸에 남은 값 때문에 테스트 결과가 사람마다 달라진다.
    """
    for key in list(os.environ):
        if key.upper().startswith(_MANAGED_PREFIXES):
            monkeypatch.delenv(key, raising=False)

    def _build(**env: str) -> Settings:
        for key, value in env.items():
            monkeypatch.setenv(key, value)
        return Settings(_env_file=None)  # type: ignore[call-arg]

    return _build


class TestCsvListParsing:
    """쉼표로 구분된 환경변수가 리스트로 들어와야 한다."""

    def test_allowed_hosts_wildcard_does_not_crash(self, build_settings: BuildSettings) -> None:
        # 이 한 줄이 예전에 서버 부팅을 통째로 막았다.
        assert build_settings(ALLOWED_HOSTS="*").allowed_hosts == ["*"]

    def test_comma_separated_hosts(self, build_settings: BuildSettings) -> None:
        settings = build_settings(ALLOWED_HOSTS="api.example.com,www.example.com")
        assert settings.allowed_hosts == ["api.example.com", "www.example.com"]

    def test_cors_origins_with_urls(self, build_settings: BuildSettings) -> None:
        settings = build_settings(CORS_ORIGINS="http://localhost:3000,http://localhost:8080")
        assert settings.cors_origins == [
            "http://localhost:3000",
            "http://localhost:8080",
        ]

    def test_language_hints(self, build_settings: BuildSettings) -> None:
        assert build_settings(STT_LANGUAGE_HINTS="ko,en").stt_language_hints == ["ko", "en"]

    def test_whitespace_is_trimmed(self, build_settings: BuildSettings) -> None:
        assert build_settings(STT_LANGUAGE_HINTS=" ko , en ").stt_language_hints == ["ko", "en"]

    def test_empty_value_yields_empty_list(self, build_settings: BuildSettings) -> None:
        assert build_settings(STT_KEYWORD_HINTS="").stt_keyword_hints == []

    def test_defaults_when_unset(self, build_settings: BuildSettings) -> None:
        settings = build_settings()
        assert settings.stt_language_hints == ["ko", "en"]
        assert settings.allowed_hosts == ["*"]

    def test_single_value_becomes_one_element_list(self, build_settings: BuildSettings) -> None:
        assert build_settings(CORS_ORIGINS="https://app.example.com").cors_origins == [
            "https://app.example.com"
        ]


class TestDatabaseUrl:
    def test_assembled_from_parts(self, build_settings: BuildSettings) -> None:
        settings = build_settings(
            POSTGRES_USER="u",
            POSTGRES_PASSWORD="p",
            POSTGRES_HOST="h",
            POSTGRES_PORT="5432",
            POSTGRES_DB="d",
        )
        assert settings.database_url.startswith("postgresql+asyncpg://u:p@h:5432/d")

    def test_rejects_sync_driver(self, build_settings: BuildSettings) -> None:
        """동기 드라이버를 넣는 실수는 부팅 시점에 잡아야 한다."""
        with pytest.raises(ValueError, match="asyncpg"):
            build_settings(DATABASE_URL="postgresql://u:p@h/d")

    def test_explicit_url_wins(self, build_settings: BuildSettings) -> None:
        settings = build_settings(
            DATABASE_URL="postgresql+asyncpg://x:y@z/w",
            POSTGRES_HOST="ignored",
        )
        assert settings.database_url == "postgresql+asyncpg://x:y@z/w"


class TestBounds:
    def test_diarize_window_upper_bound(self, build_settings: BuildSettings) -> None:
        # 30초를 넘기면 OpenAI 가 chunking_strategy 를 강제한다.
        with pytest.raises(ValueError, match="4~28"):
            build_settings(DIARIZE_WINDOW_SECONDS="35")

    def test_speaker_reference_cap(self, build_settings: BuildSettings) -> None:
        # OpenAI 는 참조 클립을 최대 4개까지만 받는다.
        with pytest.raises(ValueError, match="1~4"):
            build_settings(SPEAKER_REFERENCE_MAX="8")

    def test_overlap_must_be_shorter_than_window(self, build_settings: BuildSettings) -> None:
        with pytest.raises(ValueError, match="겹침"):
            build_settings(
                DIARIZE_WINDOW_SECONDS="10",
                DIARIZE_WINDOW_OVERLAP_SECONDS="12",
            )

    def test_invalid_log_level(self, build_settings: BuildSettings) -> None:
        with pytest.raises(ValueError, match="log_level"):
            build_settings(LOG_LEVEL="VERBOSE")

    def test_log_level_is_uppercased(self, build_settings: BuildSettings) -> None:
        assert build_settings(LOG_LEVEL="debug").log_level == "DEBUG"


class TestProductionGuardrails:
    """운영 설정 실수는 런타임이 아니라 부팅 시점에 죽어야 한다."""

    @staticmethod
    def _production(**overrides: str) -> dict[str, str]:
        base = {
            "ENVIRONMENT": "production",
            "DEBUG": "false",
            "JWT_SECRET_KEY": "x" * 64,
            "OPENAI_API_KEY": "sk-test",
            "EMOTION_API_KEY": "sk-emotion-test",
            "POSTGRES_PASSWORD": "secret",
            "ALLOWED_HOSTS": "api.example.com",
        }
        base.update(overrides)
        return base

    def test_valid_production_config_boots(self, build_settings: BuildSettings) -> None:
        settings = build_settings(**self._production())
        assert settings.is_production
        assert not settings.debug

    def test_rejects_debug_true(self, build_settings: BuildSettings) -> None:
        with pytest.raises(ValueError, match="DEBUG=false"):
            build_settings(**self._production(DEBUG="true"))

    def test_rejects_wildcard_hosts(self, build_settings: BuildSettings) -> None:
        with pytest.raises(ValueError, match="ALLOWED_HOSTS"):
            build_settings(**self._production(ALLOWED_HOSTS="*"))

    def test_rejects_short_secret(self, build_settings: BuildSettings) -> None:
        with pytest.raises(ValueError, match="JWT_SECRET_KEY"):
            build_settings(**self._production(JWT_SECRET_KEY="short"))

    def test_rejects_missing_openai_key(self, build_settings: BuildSettings) -> None:
        with pytest.raises(ValueError, match="OPENAI_API_KEY"):
            build_settings(**self._production(OPENAI_API_KEY=""))

    def test_rejects_missing_emotion_key(self, build_settings: BuildSettings) -> None:
        """없어도 자막은 흐르지만 감정이 운율 추정으로만 떨어진다.

        화면에 감정 표시가 그대로 뜨기 때문에 눈으로는 고장을 알아챌 수 없다.
        운영에서 조용히 품질만 나빠지느니 부팅에서 막는다.
        """
        with pytest.raises(ValueError, match="EMOTION_API_KEY"):
            build_settings(**self._production(EMOTION_API_KEY=""))

    def test_local_generates_secret_when_missing(self, build_settings: BuildSettings) -> None:
        # 로컬에서는 키가 없어도 부팅되어야 한다 (문서 확인/테스트 편의).
        settings = build_settings(ENVIRONMENT="local", JWT_SECRET_KEY="")
        assert len(settings.jwt_secret_key) >= 32


class TestDerived:
    def test_bytes_per_second(self, build_settings: BuildSettings) -> None:
        # 24kHz mono PCM16 = 48000 bytes/s
        settings = build_settings(AUDIO_SAMPLE_RATE="24000", AUDIO_CHANNELS="1")
        assert settings.bytes_per_second == 48_000

    def test_openai_headers_omit_empty_org(self, build_settings: BuildSettings) -> None:
        headers = build_settings(OPENAI_API_KEY="sk-x").openai_headers()
        assert headers["Authorization"] == "Bearer sk-x"
        assert "OpenAI-Organization" not in headers

    def test_openai_headers_include_org_when_set(self, build_settings: BuildSettings) -> None:
        headers = build_settings(OPENAI_API_KEY="sk-x", OPENAI_ORG_ID="org-1").openai_headers()
        assert headers["OpenAI-Organization"] == "org-1"

    def test_openai_configured_flag(self, build_settings: BuildSettings) -> None:
        assert not build_settings(OPENAI_API_KEY="").openai_configured
        assert build_settings(OPENAI_API_KEY="sk-x").openai_configured


class TestEmotionProvider:
    """감정 분류는 STT 와 다른 제공자를 쓴다 — 두 설정이 섞이면 안 된다."""

    def test_defaults_to_deepseek(self, build_settings: BuildSettings) -> None:
        settings = build_settings()
        assert settings.emotion_model == "deepseek-v4-flash"
        assert settings.emotion_base_url == "https://api.deepseek.com/v1"

    def test_emotion_key_is_independent_of_openai_key(self, build_settings: BuildSettings) -> None:
        settings = build_settings(OPENAI_API_KEY="sk-openai", EMOTION_API_KEY="")
        assert settings.openai_configured
        assert not settings.emotion_configured

    def test_emotion_headers_omit_openai_org(self, build_settings: BuildSettings) -> None:
        # 감정 제공자는 다른 회사다. OpenAI 조직 헤더를 보내면 안 된다.
        headers = build_settings(
            EMOTION_API_KEY="sk-emotion", OPENAI_ORG_ID="org-1", OPENAI_PROJECT_ID="proj-1"
        ).emotion_headers()
        assert headers == {"Authorization": "Bearer sk-emotion"}

    def test_thinking_disabled_by_default(self, build_settings: BuildSettings) -> None:
        # DeepSeek V4 는 사고 모드가 기본 켜짐이라 명시적으로 꺼야 한다.
        assert build_settings().emotion_disable_thinking

    def test_placeholder_key_counts_as_missing(self, build_settings: BuildSettings) -> None:
        """`.env.example` 을 복사만 하고 키를 안 채운 상태.

        `<FILL_ME>` 는 truthy 라 그냥 두면 "설정됨"으로 보이고, 실제로는 매
        호출이 401 로 죽는다. 부팅 로그가 거짓말을 하면 진단이 훨씬 어려워진다.
        """
        settings = build_settings(EMOTION_API_KEY="<FILL_ME>", OPENAI_API_KEY="<FILL_ME>")
        assert not settings.emotion_configured
        assert not settings.openai_configured

    def test_rejects_absurd_timeout(self, build_settings: BuildSettings) -> None:
        # 길게 잡으면 이미 지나간 말의 감정이 뒤늦게 덮어써진다.
        with pytest.raises(ValueError, match="EMOTION_TIMEOUT_SECONDS"):
            build_settings(EMOTION_TIMEOUT_SECONDS="60")
