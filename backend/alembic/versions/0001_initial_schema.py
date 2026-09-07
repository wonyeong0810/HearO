"""initial schema

Revision ID: 0001
Revises:
Create Date: 2026-08-06

users / user_settings / conversation_sessions / speakers / utterances / alert_events
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


emotion_tone = postgresql.ENUM(
    "calm", "excited", "angry", "happy", "sad", "neutral",
    name="emotion_tone",
    create_type=False,
)
alert_type = postgresql.ENUM(
    "fire_alarm", "smoke_detector", "civil_defense_siren", "emergency_vehicle", "general_alarm",
    name="alert_type",
    create_type=False,
)
session_status = postgresql.ENUM(
    "active", "ended", "abandoned",
    name="session_status",
    create_type=False,
)


def upgrade() -> None:
    bind = op.get_bind()

    # 한국어 부분일치 검색에 필요. 슈퍼유저 권한이 필요하므로 관리형 DB 에서는
    # 미리 만들어 두어야 할 수 있다 (README 배포 절 참고).
    op.execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    emotion_tone.create(bind, checkfirst=True)
    alert_type.create(bind, checkfirst=True)
    session_status.create(bind, checkfirst=True)

    # ------------------------------------------------------------------ users
    op.create_table(
        "users",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("email", sa.String(length=320), nullable=False),
        sa.Column("password_hash", sa.String(length=255), nullable=False),
        sa.Column("display_name", sa.String(length=60), nullable=False),
        sa.Column("is_active", sa.Boolean(), server_default=sa.true(), nullable=False),
        sa.Column("last_login_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("token_epoch", sa.Integer(), server_default="0", nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_users")),
    )
    op.create_index(op.f("ix_users_email"), "users", ["email"], unique=True)
    op.create_index(op.f("ix_users_created_at"), "users", ["created_at"])

    # --------------------------------------------------------- user_settings
    op.create_table(
        "user_settings",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("log_retention_days", sa.Integer(), server_default="90", nullable=False),
        sa.Column("auto_delete_enabled", sa.Boolean(), server_default=sa.true(), nullable=False),
        sa.Column("caption_text_scale", sa.Float(), server_default="1.0", nullable=False),
        sa.Column("loudness_scaling_enabled", sa.Boolean(), server_default=sa.true(), nullable=False),
        sa.Column("emotion_animation_enabled", sa.Boolean(), server_default=sa.true(), nullable=False),
        sa.Column("high_contrast_mode", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.Column("alerts_enabled", sa.Boolean(), server_default=sa.true(), nullable=False),
        sa.Column("alert_vibration_enabled", sa.Boolean(), server_default=sa.true(), nullable=False),
        sa.Column("alert_flash_enabled", sa.Boolean(), server_default=sa.true(), nullable=False),
        sa.Column("alert_torch_strobe_enabled", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.Column("alert_sensitivity", sa.Float(), server_default="0.55", nullable=False),
        sa.Column("location_tagging_enabled", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("log_retention_days >= 0", name=op.f("ck_user_settings_retention_non_negative")),
        sa.CheckConstraint(
            "caption_text_scale >= 0.5 AND caption_text_scale <= 3.0",
            name=op.f("ck_user_settings_text_scale_range"),
        ),
        sa.CheckConstraint(
            "alert_sensitivity >= 0.0 AND alert_sensitivity <= 1.0",
            name=op.f("ck_user_settings_sensitivity_range"),
        ),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"],
            name=op.f("fk_user_settings_user_id_users"), ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_user_settings")),
        sa.UniqueConstraint("user_id", name=op.f("uq_user_settings_user_id")),
    )
    op.create_index(op.f("ix_user_settings_created_at"), "user_settings", ["created_at"])

    # -------------------------------------------------- conversation_sessions
    op.create_table(
        "conversation_sessions",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("title", sa.String(length=200), nullable=True),
        sa.Column("status", session_status, server_default="active", nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ended_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("duration_seconds", sa.Float(), server_default="0", nullable=False),
        sa.Column("location_label", sa.String(length=200), nullable=True),
        sa.Column("latitude", sa.Float(), nullable=True),
        sa.Column("longitude", sa.Float(), nullable=True),
        sa.Column("is_favorite", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.Column("utterance_count", sa.Integer(), server_default="0", nullable=False),
        sa.Column("speaker_count", sa.Integer(), server_default="0", nullable=False),
        sa.Column("preview_text", sa.String(length=300), nullable=True),
        sa.Column("dominant_tone", emotion_tone, nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("duration_seconds >= 0", name=op.f("ck_conversation_sessions_duration_non_negative")),
        sa.CheckConstraint(
            "(latitude IS NULL AND longitude IS NULL) "
            "OR (latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180)",
            name=op.f("ck_conversation_sessions_valid_coordinates"),
        ),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"],
            name=op.f("fk_conversation_sessions_user_id_users"), ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_conversation_sessions")),
    )
    op.create_index(op.f("ix_conversation_sessions_created_at"), "conversation_sessions", ["created_at"])
    op.create_index("ix_sessions_user_started", "conversation_sessions", ["user_id", "started_at"])
    op.create_index(
        "ix_sessions_user_favorite",
        "conversation_sessions",
        ["user_id", "started_at"],
        postgresql_where=sa.text("is_favorite IS true"),
    )
    op.create_index("ix_sessions_retention_sweep", "conversation_sessions", ["status", "ended_at"])

    # -------------------------------------------------------------- speakers
    op.create_table(
        "speakers",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("session_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("label", sa.String(length=16), nullable=False),
        sa.Column("display_name", sa.String(length=60), nullable=True),
        sa.Column("color_hex", sa.String(length=7), nullable=False),
        sa.Column("color_is_custom", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.Column("utterance_count", sa.Integer(), server_default="0", nullable=False),
        sa.Column("total_speaking_seconds", sa.Float(), server_default="0", nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint(r"color_hex ~ '^#[0-9A-Fa-f]{6}$'", name=op.f("ck_speakers_color_hex_format")),
        sa.ForeignKeyConstraint(
            ["session_id"], ["conversation_sessions.id"],
            name=op.f("fk_speakers_session_id_conversation_sessions"), ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_speakers")),
        sa.UniqueConstraint("session_id", "label", name="uq_speaker_session_label"),
    )
    op.create_index(op.f("ix_speakers_created_at"), "speakers", ["created_at"])

    # ------------------------------------------------------------ utterances
    op.create_table(
        "utterances",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("session_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("speaker_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("sequence", sa.Integer(), nullable=False),
        sa.Column("text", sa.Text(), nullable=False),
        sa.Column("start_ms", sa.Integer(), nullable=False),
        sa.Column("end_ms", sa.Integer(), nullable=False),
        sa.Column("tone", emotion_tone, server_default="neutral", nullable=False),
        sa.Column("tone_confidence", sa.Float(), server_default="0", nullable=False),
        sa.Column("loudness_dbfs", sa.Float(), nullable=True),
        sa.Column("intensity", sa.Float(), server_default="0.5", nullable=False),
        sa.Column("pitch_hz", sa.Float(), nullable=True),
        sa.Column("speech_rate", sa.Float(), nullable=True),
        sa.Column("is_final", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.Column("speaker_resolved", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.Column("is_bookmarked", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("end_ms >= start_ms", name=op.f("ck_utterances_valid_time_range")),
        sa.CheckConstraint("intensity >= 0.0 AND intensity <= 1.0", name=op.f("ck_utterances_intensity_range")),
        sa.CheckConstraint(
            "tone_confidence >= 0.0 AND tone_confidence <= 1.0",
            name=op.f("ck_utterances_tone_confidence_range"),
        ),
        sa.ForeignKeyConstraint(
            ["session_id"], ["conversation_sessions.id"],
            name=op.f("fk_utterances_session_id_conversation_sessions"), ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["speaker_id"], ["speakers.id"],
            name=op.f("fk_utterances_speaker_id_speakers"), ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_utterances")),
        sa.UniqueConstraint("session_id", "sequence", name="uq_utterance_session_sequence"),
    )
    op.create_index(op.f("ix_utterances_created_at"), "utterances", ["created_at"])
    op.create_index("ix_utterances_session_seq", "utterances", ["session_id", "sequence"])
    op.create_index(
        "ix_utterances_bookmarked",
        "utterances",
        ["session_id"],
        postgresql_where=sa.text("is_bookmarked IS true"),
    )
    op.create_index(
        "ix_utterances_text_trgm",
        "utterances",
        ["text"],
        postgresql_using="gin",
        postgresql_ops={"text": "gin_trgm_ops"},
    )

    # ---------------------------------------------------------- alert_events
    op.create_table(
        "alert_events",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("session_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("alert_type", alert_type, nullable=False),
        sa.Column("confidence", sa.Float(), nullable=False),
        sa.Column("raw_class", sa.String(length=120), nullable=True),
        sa.Column("detected_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("consecutive_frames", sa.Integer(), server_default="1", nullable=False),
        sa.Column("latitude", sa.Float(), nullable=True),
        sa.Column("longitude", sa.Float(), nullable=True),
        sa.Column("location_label", sa.String(length=200), nullable=True),
        sa.Column("acknowledged_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("is_false_positive", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("confidence >= 0.0 AND confidence <= 1.0", name=op.f("ck_alert_events_confidence_range")),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"],
            name=op.f("fk_alert_events_user_id_users"), ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["session_id"], ["conversation_sessions.id"],
            name=op.f("fk_alert_events_session_id_conversation_sessions"), ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_alert_events")),
    )
    op.create_index(op.f("ix_alert_events_created_at"), "alert_events", ["created_at"])
    op.create_index(op.f("ix_alert_events_detected_at"), "alert_events", ["detected_at"])
    op.create_index("ix_alerts_user_detected", "alert_events", ["user_id", "detected_at"])


def downgrade() -> None:
    op.drop_table("alert_events")
    op.drop_table("utterances")
    op.drop_table("speakers")
    op.drop_table("conversation_sessions")
    op.drop_table("user_settings")
    op.drop_table("users")

    bind = op.get_bind()
    session_status.drop(bind, checkfirst=True)
    alert_type.drop(bind, checkfirst=True)
    emotion_tone.drop(bind, checkfirst=True)
    # pg_trgm 은 다른 스키마가 쓸 수 있으므로 그대로 둔다.
