"""사용자 설정 엔드포인트."""

from __future__ import annotations

from fastapi import APIRouter

from app.api.deps import AlertRepo, CurrentUser, DbSession, SessionRepo, SettingsRepo
from app.core.logging import get_logger
from app.schemas.common import MessageResponse
from app.schemas.transcript import (
    StatsResponse,
    UserSettingsResponse,
    UserSettingsUpdate,
)

router = APIRouter(prefix="/settings", tags=["설정"])
log = get_logger(__name__)


@router.get("", response_model=UserSettingsResponse, summary="설정 조회")
async def get_settings(
    user: CurrentUser, db: DbSession, settings_repo: SettingsRepo
) -> UserSettingsResponse:
    record = await settings_repo.get_or_create(user.id)
    await db.commit()
    return UserSettingsResponse.model_validate(record)


@router.patch(
    "",
    response_model=UserSettingsResponse,
    summary="설정 변경",
    description=(
        "자막 크기·감정 애니메이션·고대비 모드·경보 민감도·로그 보관 주기 등을 변경합니다. "
        "설정은 서버에 저장되어 기기를 바꿔도 유지됩니다."
    ),
)
async def update_settings(
    payload: UserSettingsUpdate,
    user: CurrentUser,
    db: DbSession,
    settings_repo: SettingsRepo,
) -> UserSettingsResponse:
    changes = payload.model_dump(exclude_none=True)
    record = await settings_repo.update(user.id, changes)
    await db.commit()
    await db.refresh(record)

    log.info("settings_updated", user_id=str(user.id), fields=sorted(changes))
    return UserSettingsResponse.model_validate(record)


@router.get(
    "/stats",
    response_model=StatsResponse,
    summary="사용 통계",
    description="총 대화 수, 자막 수, 누적 시간, 감정 분포 등.",
)
async def get_stats(user: CurrentUser, sessions: SessionRepo, alerts: AlertRepo) -> StatsResponse:
    stats = await sessions.stats(user.id)
    return StatsResponse(
        total_sessions=stats["total_sessions"],
        total_utterances=stats["total_utterances"],
        total_duration_seconds=stats["total_duration_seconds"],
        favorite_sessions=stats["favorite_sessions"],
        total_alerts=await alerts.count_for_user(user.id),
        oldest_session_at=stats["oldest_session_at"],
        tone_distribution=stats["tone_distribution"],
    )


@router.post(
    "/purge-logs",
    response_model=MessageResponse,
    summary="보관 주기 지난 기록 즉시 삭제",
    description=("자동 삭제를 기다리지 않고 지금 실행합니다. 즐겨찾기한 대화는 삭제되지 않습니다."),
)
async def purge_logs(
    user: CurrentUser,
    db: DbSession,
    settings_repo: SettingsRepo,
    sessions: SessionRepo,
    alerts: AlertRepo,
) -> MessageResponse:
    record = await settings_repo.get_or_create(user.id)

    if record.log_retention_days <= 0:
        return MessageResponse(
            message="보관 주기가 '무기한'으로 설정되어 있어 삭제할 항목이 없습니다."
        )

    deleted_sessions = await sessions.delete_expired(user.id, record.log_retention_days)
    deleted_alerts = await alerts.delete_expired(user.id, record.log_retention_days)
    await db.commit()

    log.info(
        "logs_purged_manually",
        user_id=str(user.id),
        sessions=deleted_sessions,
        alerts=deleted_alerts,
    )
    return MessageResponse(
        message=f"대화 {deleted_sessions}건, 경보 {deleted_alerts}건을 삭제했습니다."
    )
