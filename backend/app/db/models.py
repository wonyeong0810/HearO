"""도메인 모델.

프라이버시 원칙 (설계 결정):
  - 원본 오디오는 어디에도 저장하지 않는다. 전사가 끝나면 버퍼는 폐기된다.
  - 화자 식별용 참조 클립(성문에 해당하는 생체정보)도 DB 에 남기지 않는다.
    라이브 세션이 살아있는 동안만 메모리에 두고, 세션 종료와 함께 사라진다.
  - 남는 것은 텍스트, 타임스탬프, 감정 라벨, 프로소디 수치뿐이다.
"""

from __future__ import annotations

import enum
import uuid
from datetime import datetime

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    DateTime,
    Enum,
    Float,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base, TimestampMixin, UUIDPrimaryKeyMixin

# --------------------------------------------------------------------- enums


class EmotionTone(enum.StrEnum):
    """기획서의 톤 5분류 + 판정 불가 대비 NEUTRAL."""

    CALM = "calm"  # 차분
    EXCITED = "excited"  # 격앙됨
    ANGRY = "angry"  # 화남
    HAPPY = "happy"  # 기쁨
    SAD = "sad"  # 슬픔
    NEUTRAL = "neutral"  # 판정 보류 / 중립

    @property
    def label_ko(self) -> str:
        return {
            EmotionTone.CALM: "차분",
            EmotionTone.EXCITED: "격앙됨",
            EmotionTone.ANGRY: "화남",
            EmotionTone.HAPPY: "기쁨",
            EmotionTone.SAD: "슬픔",
            EmotionTone.NEUTRAL: "중립",
        }[self]


class ToneBasis(enum.StrEnum):
    """톤 판정이 **무엇을 근거로** 나왔는지.

    화면에 "화난 말투로 들림"이라고 띄우는 순간 사용자는 그걸 사실로 받아들인다.
    그런데 근거가 운율뿐이면 오판 확률이 크게 다르다 — 원래 목소리가 큰 사람,
    사투리, 신나서 흥분한 사람, 말투 특성이 다른 사람(자폐 스펙트럼 등),
    문화·연령 차이가 전부 운율에 그대로 섞여 들어오기 때문이다.

    그래서 판정 결과만 보내지 않고 근거도 함께 보낸다. 앱이 "목소리 톤만으로
    추정" 과 "목소리 + 문장 내용" 을 구분해 보여줄 수 있어야, 사용자가 이 표시를
    얼마나 믿을지 스스로 정할 수 있다.
    """

    VOICE = "voice"  # 운율(음량·피치·속도)만 봤다
    VOICE_TEXT = "voice_text"  # 운율 + 문장 내용(LLM)을 함께 봤다

    @property
    def label_ko(self) -> str:
        return {
            ToneBasis.VOICE: "목소리 톤만으로 추정",
            ToneBasis.VOICE_TEXT: "목소리 톤과 문장 내용으로 추정",
        }[self]


class AlertType(enum.StrEnum):
    """온디바이스 경보음 감지 모델의 클래스에서 매핑되는 위급 음향 종류."""

    FIRE_ALARM = "fire_alarm"  # 화재경보기
    SMOKE_DETECTOR = "smoke_detector"  # 연기감지기
    CIVIL_DEFENSE_SIREN = "civil_defense_siren"  # 민방위 경보
    EMERGENCY_VEHICLE = "emergency_vehicle"  # 구급차/소방차/경찰차 사이렌
    GENERAL_ALARM = "general_alarm"  # 그 외 경보음/버저

    @property
    def label_ko(self) -> str:
        return {
            AlertType.FIRE_ALARM: "화재경보",
            AlertType.SMOKE_DETECTOR: "연기감지기",
            AlertType.CIVIL_DEFENSE_SIREN: "민방위 경보",
            AlertType.EMERGENCY_VEHICLE: "긴급차량 사이렌",
            AlertType.GENERAL_ALARM: "경보음",
        }[self]

    @property
    def severity(self) -> int:
        """1(주의) ~ 3(즉시 대피). 클라이언트 경고 강도에 쓰인다."""
        return {
            AlertType.FIRE_ALARM: 3,
            AlertType.SMOKE_DETECTOR: 3,
            AlertType.CIVIL_DEFENSE_SIREN: 3,
            AlertType.EMERGENCY_VEHICLE: 2,
            AlertType.GENERAL_ALARM: 1,
        }[self]


class SessionStatus(enum.StrEnum):
    ACTIVE = "active"
    ENDED = "ended"
    # 앱이 강제종료되어 정상 종료 신호를 못 받은 세션
    ABANDONED = "abandoned"


def _enum_col(enum_cls: type[enum.Enum], name: str) -> Enum:
    # values_callable 을 주지 않으면 SQLAlchemy 가 멤버명(대문자)을 저장한다.
    # 우리는 소문자 값을 저장해 API 응답과 DB 를 일치시킨다.
    return Enum(
        enum_cls,
        name=name,
        values_callable=lambda e: [m.value for m in e],
        native_enum=True,
    )


# --------------------------------------------------------------------- tables


class User(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    __tablename__ = "users"

    email: Mapped[str] = mapped_column(String(320), unique=True, nullable=False, index=True)
    password_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    display_name: Mapped[str] = mapped_column(String(60), nullable=False)

    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    last_login_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    # 전체 기기 로그아웃용. 이 값보다 오래된 토큰은 거부한다.
    token_epoch: Mapped[int] = mapped_column(Integer, default=0, nullable=False)

    settings: Mapped[UserSettings] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
        uselist=False,
        lazy="selectin",
    )
    sessions: Mapped[list[ConversationSession]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
        passive_deletes=True,
    )
    alerts: Mapped[list[AlertEvent]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
        passive_deletes=True,
    )


class UserSettings(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """사용자별 앱 동작 설정. 기기를 바꿔도 따라가야 하므로 서버에 둔다."""

    __tablename__ = "user_settings"

    user_id: Mapped[uuid.UUID] = mapped_column(
        PGUUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        unique=True,
        nullable=False,
    )

    # ---- 로그 보관 ----
    # 0 = 무기한. 그 외에는 N일이 지난 세션을 워커가 삭제한다.
    log_retention_days: Mapped[int] = mapped_column(Integer, default=90, nullable=False)
    auto_delete_enabled: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)

    # ---- 자막 표시 ----
    # 1.0 = 기본 크기. 저시력 사용자를 위해 0.8~2.0 범위.
    caption_text_scale: Mapped[float] = mapped_column(Float, default=1.0, nullable=False)
    # 음량에 따른 글자 크기 변화 폭. 0 이면 크기 고정.
    loudness_scaling_enabled: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    emotion_animation_enabled: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    high_contrast_mode: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    # ---- 경보 ----
    alerts_enabled: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    alert_vibration_enabled: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    alert_flash_enabled: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    alert_torch_strobe_enabled: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    # 0.0~1.0. 낮출수록 민감(오탐↑), 높일수록 둔감(미탐↑).
    alert_sensitivity: Mapped[float] = mapped_column(Float, default=0.55, nullable=False)

    # ---- 위치 ----
    # 대화 기록에 위치를 붙일지 여부. 기본 꺼둔다(명시적 동의 원칙).
    location_tagging_enabled: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    user: Mapped[User] = relationship(back_populates="settings")

    __table_args__ = (
        CheckConstraint("log_retention_days >= 0", name="retention_non_negative"),
        CheckConstraint(
            "caption_text_scale >= 0.5 AND caption_text_scale <= 3.0",
            name="text_scale_range",
        ),
        CheckConstraint(
            "alert_sensitivity >= 0.0 AND alert_sensitivity <= 1.0",
            name="sensitivity_range",
        ),
    )


class ConversationSession(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """하나의 '대화' 단위. 앱에서 자막을 켠 순간부터 끈 순간까지."""

    __tablename__ = "conversation_sessions"

    user_id: Mapped[uuid.UUID] = mapped_column(
        PGUUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )

    title: Mapped[str | None] = mapped_column(String(200))
    status: Mapped[SessionStatus] = mapped_column(
        _enum_col(SessionStatus, "session_status"),
        default=SessionStatus.ACTIVE,
        nullable=False,
    )

    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    duration_seconds: Mapped[float] = mapped_column(Float, default=0.0, nullable=False)

    # ---- 위치 (설정에서 켠 경우에만 채워진다) ----
    location_label: Mapped[str | None] = mapped_column(String(200))
    latitude: Mapped[float | None] = mapped_column(Float)
    longitude: Mapped[float | None] = mapped_column(Float)

    # ---- 분류/검색 보조 ----
    is_favorite: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    utterance_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    speaker_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    # 목록 화면에서 본문을 안 읽고도 미리보기를 띄우기 위한 비정규화 필드
    preview_text: Mapped[str | None] = mapped_column(String(300))
    # 세션 전체를 대표하는 톤 (가장 많이 등장한 감정)
    dominant_tone: Mapped[EmotionTone | None] = mapped_column(
        _enum_col(EmotionTone, "emotion_tone")
    )

    user: Mapped[User] = relationship(back_populates="sessions")
    speakers: Mapped[list[Speaker]] = relationship(
        back_populates="session",
        cascade="all, delete-orphan",
        passive_deletes=True,
        order_by="Speaker.label",
    )
    utterances: Mapped[list[Utterance]] = relationship(
        back_populates="session",
        cascade="all, delete-orphan",
        passive_deletes=True,
        order_by="Utterance.sequence",
    )
    alerts: Mapped[list[AlertEvent]] = relationship(
        back_populates="session",
        passive_deletes=True,
    )

    __table_args__ = (
        # 기록 목록: "내 세션을 최신순으로"
        Index("ix_sessions_user_started", "user_id", "started_at"),
        # 즐겨찾기 필터 — 부분 인덱스로 크기를 줄인다
        Index(
            "ix_sessions_user_favorite",
            "user_id",
            "started_at",
            postgresql_where=(is_favorite.is_(True)),
        ),
        # 보관주기 워커가 훑는 경로
        Index("ix_sessions_retention_sweep", "status", "ended_at"),
        CheckConstraint("duration_seconds >= 0", name="duration_non_negative"),
        CheckConstraint(
            "(latitude IS NULL AND longitude IS NULL) "
            "OR (latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180)",
            name="valid_coordinates",
        ),
    )


class Speaker(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """세션 내 화자.

    label 은 diarize 모델이 돌려주는 'A', 'B', ... 이고, 세션 안에서만 유효하다.
    (같은 사람이 다른 세션에서 같은 라벨을 받는다는 보장은 없다 — 성문을 영구
    저장하지 않기로 한 결정의 대가이고, 의도된 트레이드오프다.)
    """

    __tablename__ = "speakers"

    session_id: Mapped[uuid.UUID] = mapped_column(
        PGUUID(as_uuid=True),
        ForeignKey("conversation_sessions.id", ondelete="CASCADE"),
        nullable=False,
    )

    label: Mapped[str] = mapped_column(String(16), nullable=False)
    # 사용자가 "엄마", "김 선생님" 처럼 직접 붙인 이름
    display_name: Mapped[str | None] = mapped_column(String(60))
    # #RRGGBB. 자동 배정되지만 사용자가 바꿀 수 있다.
    color_hex: Mapped[str] = mapped_column(String(7), nullable=False)
    # 사용자가 직접 고른 색인지(true) 자동 배정인지(false)
    color_is_custom: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    utterance_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    total_speaking_seconds: Mapped[float] = mapped_column(Float, default=0.0, nullable=False)

    session: Mapped[ConversationSession] = relationship(back_populates="speakers")
    utterances: Mapped[list[Utterance]] = relationship(back_populates="speaker")

    __table_args__ = (
        UniqueConstraint("session_id", "label", name="uq_speaker_session_label"),
        CheckConstraint(r"color_hex ~ '^#[0-9A-Fa-f]{6}$'", name="color_hex_format"),
    )


class Utterance(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """한 발화(자막 한 줄)."""

    __tablename__ = "utterances"

    session_id: Mapped[uuid.UUID] = mapped_column(
        PGUUID(as_uuid=True),
        ForeignKey("conversation_sessions.id", ondelete="CASCADE"),
        nullable=False,
    )
    # 실시간 트랙이 먼저 텍스트를 만들고, 화자분리 트랙이 나중에 채운다.
    # 그래서 nullable 이다 — 화자 미확정 상태가 정상적으로 존재한다.
    speaker_id: Mapped[uuid.UUID | None] = mapped_column(
        PGUUID(as_uuid=True),
        ForeignKey("speakers.id", ondelete="SET NULL"),
    )

    sequence: Mapped[int] = mapped_column(Integer, nullable=False)
    text: Mapped[str] = mapped_column(Text, nullable=False)

    # 세션 시작 기준 오프셋(ms)
    start_ms: Mapped[int] = mapped_column(Integer, nullable=False)
    end_ms: Mapped[int] = mapped_column(Integer, nullable=False)

    # ---- 감정/톤 ----
    tone: Mapped[EmotionTone] = mapped_column(
        _enum_col(EmotionTone, "emotion_tone"),
        default=EmotionTone.NEUTRAL,
        nullable=False,
    )
    tone_confidence: Mapped[float] = mapped_column(Float, default=0.0, nullable=False)
    # 무엇을 근거로 나온 판정인지. 기본값이 VOICE 인 이유는 발화가 만들어지는
    # 순간에는 운율 판정밖에 없기 때문이다 — LLM 결과는 나중에 덮어쓴다.
    # 기록 화면도 이 값을 읽어 "목소리 톤만으로 추정" 을 표시한다.
    tone_basis: Mapped[ToneBasis] = mapped_column(
        _enum_col(ToneBasis, "tone_basis"),
        default=ToneBasis.VOICE,
        nullable=False,
    )

    # ---- 프로소디 (글자 크기/애니메이션 강도 계산에 사용) ----
    # 평균 음량(dBFS, 보통 -60 ~ 0)
    loudness_dbfs: Mapped[float | None] = mapped_column(Float)
    # 0.0~1.0 으로 정규화한 세기. 클라이언트는 이 값만 보고 글자 크기를 정한다.
    intensity: Mapped[float] = mapped_column(Float, default=0.5, nullable=False)
    # 평균 기본주파수(Hz). 흥분/차분 판정 보조.
    pitch_hz: Mapped[float | None] = mapped_column(Float)
    # 초당 음절 수 추정치. 말이 빨라지면 격앙으로 기운다.
    speech_rate: Mapped[float | None] = mapped_column(Float)

    # ---- 상태 ----
    # 실시간 트랙의 잠정 텍스트인지, 확정본인지
    is_final: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    # 화자분리 트랙이 라벨을 붙였는지
    speaker_resolved: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    is_bookmarked: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    session: Mapped[ConversationSession] = relationship(back_populates="utterances")
    speaker: Mapped[Speaker | None] = relationship(back_populates="utterances")

    __table_args__ = (
        UniqueConstraint("session_id", "sequence", name="uq_utterance_session_sequence"),
        Index("ix_utterances_session_seq", "session_id", "sequence"),
        Index(
            "ix_utterances_bookmarked",
            "session_id",
            postgresql_where=(is_bookmarked.is_(True)),
        ),
        # 한국어 부분일치 검색용 트라이그램 인덱스.
        # 영어 stemming 기반 tsvector 는 한국어에서 사실상 무용하므로 pg_trgm 을 쓴다.
        Index(
            "ix_utterances_text_trgm",
            "text",
            postgresql_using="gin",
            postgresql_ops={"text": "gin_trgm_ops"},
        ),
        CheckConstraint("end_ms >= start_ms", name="valid_time_range"),
        CheckConstraint("intensity >= 0.0 AND intensity <= 1.0", name="intensity_range"),
        CheckConstraint(
            "tone_confidence >= 0.0 AND tone_confidence <= 1.0", name="tone_confidence_range"
        ),
    )


class AlertEvent(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """경보음 감지 기록.

    감지는 온디바이스(YAMNet)에서 일어나고, 앱이 사후에 여기로 올린다.
    네트워크가 끊겨 있어도 경보 자체는 동작하며, 연결되면 큐가 밀려 올라온다.
    """

    __tablename__ = "alert_events"

    user_id: Mapped[uuid.UUID] = mapped_column(
        PGUUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    session_id: Mapped[uuid.UUID | None] = mapped_column(
        PGUUID(as_uuid=True),
        ForeignKey("conversation_sessions.id", ondelete="SET NULL"),
    )

    alert_type: Mapped[AlertType] = mapped_column(
        _enum_col(AlertType, "alert_type"), nullable=False
    )
    confidence: Mapped[float] = mapped_column(Float, nullable=False)
    # 모델이 실제로 뱉은 클래스명. 오탐 분석에 필요하다.
    raw_class: Mapped[str | None] = mapped_column(String(120))

    detected_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, index=True
    )
    # 몇 프레임 연속으로 감지되었는지 (디바운스 근거)
    consecutive_frames: Mapped[int] = mapped_column(Integer, default=1, nullable=False)

    latitude: Mapped[float | None] = mapped_column(Float)
    longitude: Mapped[float | None] = mapped_column(Float)
    location_label: Mapped[str | None] = mapped_column(String(200))

    # 사용자가 경고를 확인(해제)한 시각. NULL 이면 미확인.
    acknowledged_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # 사용자가 "이건 오탐이었다" 로 표시. 임계값 튜닝 데이터로 쓴다.
    is_false_positive: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    user: Mapped[User] = relationship(back_populates="alerts")
    session: Mapped[ConversationSession | None] = relationship(back_populates="alerts")

    __table_args__ = (
        Index("ix_alerts_user_detected", "user_id", "detected_at"),
        CheckConstraint("confidence >= 0.0 AND confidence <= 1.0", name="confidence_range"),
    )
