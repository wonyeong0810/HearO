"""대화 세션 / 화자 / 발화 스키마."""

from __future__ import annotations

import re
import uuid
from datetime import datetime
from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from app.db.models import AlertType, EmotionTone, SessionStatus, ToneBasis
from app.schemas.common import APIModel

HEX_COLOR = re.compile(r"^#[0-9A-Fa-f]{6}$")
ColorHex = Annotated[str, Field(pattern=r"^#[0-9A-Fa-f]{6}$")]


# --------------------------------------------------------------------- speaker


class SpeakerResponse(APIModel):
    id: uuid.UUID
    label: str
    display_name: str | None
    color_hex: str
    color_is_custom: bool
    utterance_count: int
    total_speaking_seconds: float


class SpeakerUpdate(APIModel):
    display_name: Annotated[str | None, Field(default=None, max_length=60)]
    color_hex: ColorHex | None = None

    @model_validator(mode="after")
    def _at_least_one(self) -> SpeakerUpdate:
        if self.display_name is None and self.color_hex is None:
            raise ValueError("변경할 항목이 없습니다.")
        return self


# --------------------------------------------------------------------- utterance


class UtteranceResponse(APIModel):
    id: uuid.UUID
    sequence: int
    text: str
    start_ms: int
    end_ms: int

    tone: EmotionTone
    tone_confidence: float
    # 판정 근거. 앱이 "목소리 톤만으로 추정" 과 "목소리 톤과 문장 내용으로 추정"
    # 을 구분해 보여준다 — 전자는 사투리·평소 목소리 크기·말투 특성에 훨씬 약하다.
    tone_basis: ToneBasis
    # 클라이언트가 글자 크기를 정하는 값 (0.0~1.0)
    intensity: float
    loudness_dbfs: float | None
    pitch_hz: float | None
    speech_rate: float | None

    speaker_id: uuid.UUID | None
    speaker_label: str | None = None
    speaker_color: str | None = None
    speaker_name: str | None = None

    is_final: bool
    speaker_resolved: bool
    is_bookmarked: bool


class UtteranceUpdate(APIModel):
    is_bookmarked: bool | None = None
    # 오인식된 자막을 사용자가 고칠 수 있게 한다.
    text: Annotated[str | None, Field(default=None, max_length=5000)]

    @model_validator(mode="after")
    def _at_least_one(self) -> UtteranceUpdate:
        if self.is_bookmarked is None and self.text is None:
            raise ValueError("변경할 항목이 없습니다.")
        return self


# --------------------------------------------------------------------- session


class SessionCreate(APIModel):
    title: Annotated[str | None, Field(default=None, max_length=200)]
    location_label: Annotated[str | None, Field(default=None, max_length=200)]
    latitude: Annotated[float | None, Field(default=None, ge=-90, le=90)]
    longitude: Annotated[float | None, Field(default=None, ge=-180, le=180)]
    # 인식률을 올리기 위한 상황 힌트 ("병원 진료", "회사 회의" 등)
    context_hint: Annotated[str | None, Field(default=None, max_length=300)]

    @model_validator(mode="after")
    def _coordinates_paired(self) -> SessionCreate:
        if (self.latitude is None) != (self.longitude is None):
            raise ValueError("위도와 경도는 함께 지정해야 합니다.")
        return self


class SessionUpdate(APIModel):
    title: Annotated[str | None, Field(default=None, max_length=200)]
    is_favorite: bool | None = None
    location_label: Annotated[str | None, Field(default=None, max_length=200)]

    @model_validator(mode="after")
    def _at_least_one(self) -> SessionUpdate:
        if self.title is None and self.is_favorite is None and self.location_label is None:
            raise ValueError("변경할 항목이 없습니다.")
        return self


class SessionSummaryResponse(APIModel):
    """목록 화면용 — 발화 본문을 싣지 않는다."""

    id: uuid.UUID
    title: str | None
    status: SessionStatus
    started_at: datetime
    ended_at: datetime | None
    duration_seconds: float
    location_label: str | None
    latitude: float | None
    longitude: float | None
    is_favorite: bool
    utterance_count: int
    speaker_count: int
    preview_text: str | None
    dominant_tone: EmotionTone | None


class SessionDetailResponse(SessionSummaryResponse):
    """상세 화면용 — 화자와 발화 전체를 싣는다."""

    speakers: list[SpeakerResponse]
    utterances: list[UtteranceResponse]


# --------------------------------------------------------------------- search


SortField = Literal["started_at", "duration", "utterance_count"]


class SessionSearchParams(APIModel):
    """기획 3-2 '날짜별 / 위치별 / 화자별 분류 + 검색'."""

    # 자유 텍스트 — 제목, 미리보기, 발화 본문에서 찾는다.
    q: Annotated[str | None, Field(default=None, max_length=200)]

    date_from: datetime | None = None
    date_to: datetime | None = None

    location: Annotated[str | None, Field(default=None, max_length=200)]
    # 화자 이름으로 필터 (사용자가 붙인 display_name)
    speaker_name: Annotated[str | None, Field(default=None, max_length=60)]

    favorites_only: bool = False
    tone: EmotionTone | None = None

    sort: SortField = "started_at"
    order: Literal["asc", "desc"] = "desc"

    limit: Annotated[int, Field(default=20, ge=1, le=100)]
    offset: Annotated[int, Field(default=0, ge=0)]

    @model_validator(mode="after")
    def _valid_range(self) -> SessionSearchParams:
        if self.date_from and self.date_to and self.date_from > self.date_to:
            raise ValueError("시작일이 종료일보다 늦을 수 없습니다.")
        return self

    @field_validator("q", "location", "speaker_name")
    @classmethod
    def _blank_to_none(cls, v: str | None) -> str | None:
        return v or None


class UtteranceSearchResult(APIModel):
    """전문 검색 결과 — 어느 대화의 몇 번째 줄인지까지 준다."""

    session_id: uuid.UUID
    session_title: str | None
    session_started_at: datetime
    utterance_id: uuid.UUID
    sequence: int
    text: str
    start_ms: int
    tone: EmotionTone
    speaker_label: str | None
    speaker_name: str | None
    speaker_color: str | None


# --------------------------------------------------------------------- alerts


class AlertCreate(APIModel):
    """온디바이스에서 감지된 경보를 서버에 기록한다.

    오프라인에서 쌓였다가 한꺼번에 올라올 수 있으므로 detected_at 은 필수다
    (서버 수신 시각이 아니라 실제 감지 시각을 기록해야 한다).
    """

    alert_type: AlertType
    confidence: Annotated[float, Field(ge=0.0, le=1.0)]
    detected_at: datetime
    raw_class: Annotated[str | None, Field(default=None, max_length=120)]
    consecutive_frames: Annotated[int, Field(default=1, ge=1, le=1000)]
    session_id: uuid.UUID | None = None
    latitude: Annotated[float | None, Field(default=None, ge=-90, le=90)]
    longitude: Annotated[float | None, Field(default=None, ge=-180, le=180)]
    location_label: Annotated[str | None, Field(default=None, max_length=200)]


class AlertBatchCreate(APIModel):
    """오프라인 큐 일괄 업로드."""

    alerts: Annotated[list[AlertCreate], Field(min_length=1, max_length=100)]


class AlertResponse(APIModel):
    id: uuid.UUID
    alert_type: AlertType
    label_ko: str
    severity: int
    confidence: float
    raw_class: str | None
    detected_at: datetime
    consecutive_frames: int
    session_id: uuid.UUID | None
    latitude: float | None
    longitude: float | None
    location_label: str | None
    acknowledged_at: datetime | None
    is_false_positive: bool


class AlertUpdate(APIModel):
    acknowledged: bool | None = None
    is_false_positive: bool | None = None

    @model_validator(mode="after")
    def _at_least_one(self) -> AlertUpdate:
        if self.acknowledged is None and self.is_false_positive is None:
            raise ValueError("변경할 항목이 없습니다.")
        return self


# --------------------------------------------------------------------- settings


class UserSettingsResponse(APIModel):
    log_retention_days: int
    auto_delete_enabled: bool
    caption_text_scale: float
    loudness_scaling_enabled: bool
    emotion_animation_enabled: bool
    high_contrast_mode: bool
    alerts_enabled: bool
    alert_vibration_enabled: bool
    alert_flash_enabled: bool
    alert_torch_strobe_enabled: bool
    alert_sensitivity: float
    location_tagging_enabled: bool


class UserSettingsUpdate(APIModel):
    log_retention_days: Annotated[int | None, Field(default=None, ge=0, le=3650)]
    auto_delete_enabled: bool | None = None
    caption_text_scale: Annotated[float | None, Field(default=None, ge=0.5, le=3.0)]
    loudness_scaling_enabled: bool | None = None
    emotion_animation_enabled: bool | None = None
    high_contrast_mode: bool | None = None
    alerts_enabled: bool | None = None
    alert_vibration_enabled: bool | None = None
    alert_flash_enabled: bool | None = None
    alert_torch_strobe_enabled: bool | None = None
    alert_sensitivity: Annotated[float | None, Field(default=None, ge=0.0, le=1.0)]
    location_tagging_enabled: bool | None = None

    @model_validator(mode="after")
    def _at_least_one(self) -> UserSettingsUpdate:
        if not self.model_dump(exclude_none=True):
            raise ValueError("변경할 항목이 없습니다.")
        return self


class StatsResponse(APIModel):
    """설정 화면에 보여줄 사용 통계."""

    total_sessions: int
    total_utterances: int
    total_duration_seconds: float
    favorite_sessions: int
    total_alerts: int
    oldest_session_at: datetime | None
    tone_distribution: dict[str, int]


class SessionImportSpeaker(APIModel):
    label: Annotated[str, Field(max_length=8)]
    color_hex: ColorHex
    display_name: Annotated[str | None, Field(default=None, max_length=60)]


class SessionImportUtterance(APIModel):
    sequence: int
    text: Annotated[str, Field(min_length=1, max_length=2000)]
    start_ms: Annotated[int, Field(ge=0)]
    end_ms: Annotated[int, Field(ge=0)]
    speaker_label: str | None = None
    tone: EmotionTone = EmotionTone.NEUTRAL
    tone_confidence: Annotated[float, Field(default=0.0, ge=0.0, le=1.0)]
    tone_basis: ToneBasis = ToneBasis.VOICE
    intensity: Annotated[float, Field(default=0.5, ge=0.0, le=1.0)]


class SessionImport(APIModel):
    speakers: Annotated[list[SessionImportSpeaker], Field(max_length=16)]
    utterances: Annotated[list[SessionImportUtterance], Field(min_length=1, max_length=500)]
