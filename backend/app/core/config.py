"""애플리케이션 설정.

모든 설정은 환경변수(.env)에서 온다. 값이 잘못되었거나 운영 환경에서 위험한
조합이면 부팅 시점에 죽는다 — 런타임에 조용히 잘못 동작하는 것보다 낫다.
"""

from __future__ import annotations

import secrets
from functools import lru_cache
from typing import Annotated, Literal

from pydantic import (
    Field,
    PostgresDsn,
    RedisDsn,
    ValidationInfo,
    field_validator,
    model_validator,
)
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict

Environment = Literal["local", "staging", "production"]

# pydantic-settings 는 list 로 선언된 필드를 환경변수에서 읽을 때 **JSON 으로**
# 파싱하려 든다. 그래서 `ALLOWED_HOSTS=*` 같은 평범한 값이 JSONDecodeError 를
# 내며 서버가 아예 부팅되지 않는다 (.env.example 을 그대로 복사하면 바로 겪는다).
#
# NoDecode 를 붙이면 JSON 디코딩을 건너뛰고 원본 문자열이 그대로 넘어와,
# 아래 `_split_csv` 검증기가 쉼표로 나눌 수 있다.
CsvList = Annotated[list[str], NoDecode]


def _csv(value: str | list[str] | None) -> list[str]:
    """ "a, b ,c" → ["a", "b", "c"]. 이미 리스트면 그대로."""
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [item.strip() for item in value.split(",") if item.strip()]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=(".env", "../.env"),
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    # ------------------------------------------------------------- runtime
    environment: Environment = "local"
    debug: bool = True
    log_level: str = "INFO"
    log_json: bool = False
    api_host: str = "0.0.0.0"  # noqa: S104 — 컨테이너 안에서는 의도된 바인딩
    api_port: int = 8000
    sentry_dsn: str | None = None

    project_name: str = "HearO"
    api_v1_prefix: str = "/api/v1"

    # ------------------------------------------------------------- openai
    openai_api_key: str = ""
    openai_org_id: str | None = None
    openai_project_id: str | None = None

    openai_realtime_model: str = "gpt-live-transcribe"
    openai_diarize_model: str = "gpt-4o-transcribe-diarize"

    openai_base_url: str = "https://api.openai.com/v1"
    openai_realtime_url: str = "wss://api.openai.com/v1/realtime"
    openai_timeout_seconds: float = 30.0

    stt_language_hints: Annotated[CsvList, Field(default_factory=lambda: ["ko", "en"])]
    stt_keyword_hints: Annotated[CsvList, Field(default_factory=list)]

    # ------------------------------------------------------------- emotion llm
    # 감정·톤 분류는 STT 와 제공자를 분리한다. 실시간 전사와 화자분리는 OpenAI
    # 고유 기능이라 옮길 수 없지만, 감정 분류는 평범한 chat completions 라
    # 더 싸고 빠른 모델로 갈아끼울 수 있다. 키도 base_url 도 별개다.
    #
    # 기본값 DeepSeek V4 Flash 는 OpenAI 호환 형식이라 클라이언트 코드가 같다.
    # 다만 응답 형식 지원 범위가 달라 classifier.py 가 json_object 모드를 쓴다.
    emotion_api_key: str = ""
    emotion_base_url: str = "https://api.deepseek.com/v1"
    emotion_model: str = "deepseek-v4-flash"

    # 이 시간 안에 답이 없으면 운율 판정으로 넘어간다. 자막은 실시간이라
    # 오래 기다릴 수 없다 — 늦게 정확한 것보다 제때 대략적인 편이 낫다.
    emotion_timeout_seconds: float = 4.0

    # DeepSeek V4 는 사고(thinking) 모드가 **기본 켜짐**이다. 켜둔 채로는 첫
    # 토큰까지 수 초가 걸려 위 타임아웃을 매번 넘기고, 그러면 감정 표시가
    # 통째로 운율 판정으로 떨어진다 — 조용히 품질만 나빠지는 형태의 고장이다.
    # 이 파라미터를 모르는 제공자(OpenAI 등)로 바꾸면 400 이 나므로 그때는 false.
    emotion_disable_thinking: bool = True

    # ------------------------------------------------------------- database
    postgres_user: str = "hearo"
    postgres_password: str = ""
    postgres_db: str = "hearo"
    postgres_host: str = "db"
    postgres_port: int = 5432
    database_url: str = ""

    db_pool_size: int = 10
    db_max_overflow: int = 20
    db_pool_recycle_seconds: int = 1800
    db_echo: bool = False

    # ------------------------------------------------------------- redis
    redis_url: RedisDsn = RedisDsn("redis://redis:6379/0")

    # ------------------------------------------------------------- auth
    jwt_secret_key: str = ""
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 30
    refresh_token_expire_days: int = 60

    cors_origins: Annotated[CsvList, Field(default_factory=list)]
    allowed_hosts: Annotated[CsvList, Field(default_factory=lambda: ["*"])]

    # ------------------------------------------------------------- push
    firebase_credentials_path: str | None = None
    fcm_enabled: bool = False

    # ------------------------------------------------------------- audio
    audio_sample_rate: int = 24_000
    audio_channels: int = 1

    diarize_window_seconds: float = 12.0
    diarize_window_overlap_seconds: float = 2.0
    # 말이 끊기면 목표 길이를 기다리지 않고 창을 닫는다 — 화자 라벨이 화면에
    # 붙는 속도를 좌우한다. 낮출수록 빨라지지만 창이 짧아져 화자를 가를 근거가
    # 줄고 API 호출이 늘어난다.
    diarize_min_window_seconds: float = 5.0
    diarize_early_cut_silence_ms: int = 400

    speaker_reference_max: int = 4
    speaker_reference_min_seconds: float = 2.0
    speaker_reference_max_seconds: float = 8.0

    silence_threshold_dbfs: float = -45.0

    # ------------------------------------------------- 발화 경계 (트랙 1)
    # `gpt-live-transcribe` 는 turn_detection 을 받지 않으므로 서버 VAD 가 없다.
    # 우리가 직접 무음을 세어 `input_audio_buffer.commit` 을 보내야 발화가
    # 확정된다 (안 보내면 잠정 자막만 계속 갱신되고 확정 자막이 영영 안 온다).
    realtime_commit_silence_ms: int = 700
    # 쉬지 않고 이어져도 이 길이에서는 한 번 끊는다.
    #
    # 이 커밋은 **화면 아래 잠정 줄을 끊어 주는 용도**다. 확정 자막은 화자분리
    # 트랙이 만들므로 여기서 어디를 자르든 최종 정확도에 영향이 없다. 잠정
    # 줄이 끝없이 길어지지만 않으면 된다.
    realtime_commit_max_turn_ms: int = 12_000
    # 쉼 판정을 **상대적으로** 한다. 최근 말소리보다 이만큼 아래로 떨어지면
    # 쉼으로 본다. 절대 임계값(silence_threshold_dbfs)만 쓰면 조용한 방에서는
    # 잘 되다가 카페나 TV 앞에서는 한 번도 안 걸린다.
    realtime_pause_drop_db: float = 14.0

    # ------------------------------------------------------------- retention
    default_log_retention_days: int = 90
    retention_sweep_interval_seconds: int = 21_600

    # ------------------------------------------------------------- limits
    rate_limit_enabled: bool = True
    rate_limit_per_minute: int = 120
    max_concurrent_live_sessions_per_user: int = 2

    # 라이브 WS 로 들어오는 오디오 프레임 한 건의 최대 바이트.
    # 24kHz mono PCM16 기준 1초 = 48000 bytes. 여유 있게 2초분.
    max_audio_frame_bytes: int = 96_000
    # 무전송 상태가 이보다 길면 라이브 세션을 정리한다.
    live_session_idle_timeout_seconds: int = 120
    # 단일 라이브 세션의 최대 지속 시간 (비용 폭주 방지).
    live_session_max_duration_seconds: int = 4 * 60 * 60

    # ================================================================ validators

    @field_validator(
        "stt_language_hints",
        "stt_keyword_hints",
        "cors_origins",
        "allowed_hosts",
        mode="before",
    )
    @classmethod
    def _split_csv(cls, v: object) -> list[str]:
        return _csv(v)  # type: ignore[arg-type]

    @field_validator("openai_api_key", "emotion_api_key", mode="before")
    @classmethod
    def _blank_placeholder_keys(cls, v: object) -> object:
        """`.env.example` 의 `<FILL_ME>` 를 빈 값으로 취급한다.

        놔두면 키가 채워진 것으로 보여 "configured" 로그가 뜨고, 실제로는 매
        호출이 401 로 죽는다. 없는 것과 잘못된 것 중에는 없는 쪽이 진단하기 쉽다.
        """
        if isinstance(v, str) and v.startswith("<") and v.endswith(">"):
            return ""
        return v

    @field_validator("log_level")
    @classmethod
    def _upper_log_level(cls, v: str) -> str:
        level = v.upper()
        if level not in {"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"}:
            raise ValueError(f"log_level 이 잘못됨: {v}")
        return level

    @field_validator("database_url")
    @classmethod
    def _assemble_db_url(cls, v: str, info: ValidationInfo) -> str:
        """DATABASE_URL 이 비어 있으면 POSTGRES_* 조각으로 조립한다."""
        if v:
            # 동기 드라이버를 넣는 실수가 잦아 여기서 잡는다.
            if v.startswith("postgresql://") or v.startswith("postgres://"):
                raise ValueError(
                    "DATABASE_URL 은 async 드라이버여야 합니다. "
                    "'postgresql+asyncpg://...' 형식으로 바꾸세요."
                )
            return v

        d = info.data
        dsn = PostgresDsn.build(
            scheme="postgresql+asyncpg",
            username=d.get("postgres_user"),
            password=d.get("postgres_password") or None,
            host=d.get("postgres_host"),
            port=d.get("postgres_port"),
            path=d.get("postgres_db") or "",
        )
        return str(dsn)

    @field_validator("emotion_timeout_seconds")
    @classmethod
    def _emotion_timeout_bounds(cls, v: float) -> float:
        # 자막 한 줄의 감정을 확정하는 데 쓰는 시간이다. 길게 잡으면 감정이
        # 한참 뒤에 덮어써져 사용자가 이미 지나간 말의 톤을 보게 된다.
        if not 0.5 <= v <= 15.0:
            raise ValueError("EMOTION_TIMEOUT_SECONDS 는 0.5~15초 사이여야 합니다.")
        return v

    @field_validator("diarize_window_seconds")
    @classmethod
    def _diarize_window_bounds(cls, v: float) -> float:
        # 30초를 넘으면 OpenAI 가 chunking_strategy 를 강제하고, 화자 라벨이
        # 청크 경계에서 흔들린다. 우리가 직접 창을 자르는 편이 안정적이다.
        if not 4.0 <= v <= 28.0:
            raise ValueError("DIARIZE_WINDOW_SECONDS 는 4~28초 사이여야 합니다.")
        return v

    @field_validator("speaker_reference_max")
    @classmethod
    def _speaker_ref_cap(cls, v: int) -> int:
        # OpenAI 제약: known_speaker_references 는 최대 4개.
        if not 1 <= v <= 4:
            raise ValueError("SPEAKER_REFERENCE_MAX 는 1~4 여야 합니다 (OpenAI 제한).")
        return v

    @model_validator(mode="after")
    def _validate_window_overlap(self) -> Settings:
        if self.diarize_window_overlap_seconds >= self.diarize_window_seconds:
            raise ValueError("겹침 구간이 창 길이보다 짧아야 합니다.")
        return self

    @model_validator(mode="after")
    def _production_guardrails(self) -> Settings:
        """운영 환경에서 절대 나가면 안 되는 설정을 부팅 시 차단한다."""
        if self.environment != "production":
            # 로컬에서는 키가 없어도 부팅되게 해준다 (테스트/문서 확인용).
            if not self.jwt_secret_key:
                self.jwt_secret_key = secrets.token_hex(32)
            return self

        problems: list[str] = []
        if not self.jwt_secret_key or len(self.jwt_secret_key) < 32:
            problems.append("JWT_SECRET_KEY 가 비었거나 32자 미만입니다.")
        if not self.openai_api_key:
            problems.append("OPENAI_API_KEY 가 비었습니다.")
        if not self.emotion_api_key:
            # 없어도 부팅은 되지만 감정 판정이 통째로 운율 폴백으로 떨어진다.
            # 그 상태는 화면상 정상으로 보여서 아무도 눈치채지 못한다.
            problems.append(
                "EMOTION_API_KEY 가 비었습니다 (감정 분류가 운율 추정으로만 동작합니다)."
            )
        if not self.postgres_password and "@" not in self.database_url:
            problems.append("POSTGRES_PASSWORD 가 비었습니다.")
        if self.debug:
            problems.append("production 에서는 DEBUG=false 여야 합니다.")
        if "*" in self.allowed_hosts:
            problems.append("production 에서는 ALLOWED_HOSTS 를 실제 도메인으로 지정하세요.")
        if self.fcm_enabled and not self.firebase_credentials_path:
            problems.append("FCM_ENABLED=true 인데 FIREBASE_CREDENTIALS_PATH 가 비었습니다.")

        if problems:
            raise ValueError("운영 설정 검증 실패:\n" + "\n".join(f"  - {p}" for p in problems))
        return self

    # ================================================================ helpers

    @property
    def is_production(self) -> bool:
        return self.environment == "production"

    @property
    def openai_configured(self) -> bool:
        return bool(self.openai_api_key)

    @property
    def emotion_configured(self) -> bool:
        return bool(self.emotion_api_key)

    @property
    def bytes_per_second(self) -> int:
        """PCM16 기준 초당 바이트 수."""
        return self.audio_sample_rate * self.audio_channels * 2

    def openai_headers(self) -> dict[str, str]:
        headers = {"Authorization": f"Bearer {self.openai_api_key}"}
        if self.openai_org_id:
            headers["OpenAI-Organization"] = self.openai_org_id
        if self.openai_project_id:
            headers["OpenAI-Project"] = self.openai_project_id
        return headers

    def emotion_headers(self) -> dict[str, str]:
        # OpenAI 조직/프로젝트 헤더는 붙이지 않는다. 감정 제공자는 다른 회사다.
        return {"Authorization": f"Bearer {self.emotion_api_key}"}


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
