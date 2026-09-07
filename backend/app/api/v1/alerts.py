"""경보 이벤트 엔드포인트 (기획 2. 위급 상황 감지).

감지 자체는 앱에서 온디바이스로 일어난다 — 네트워크가 끊겨도 화재경보를 놓치면
안 되기 때문이다. 이 API 는 사후 기록·조회·오탐 신고를 담당한다.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Annotated

from fastapi import APIRouter, Query, status

from app.api.deps import AlertRepo, CurrentUser, DbSession
from app.core.logging import get_logger
from app.db.models import AlertEvent, AlertType
from app.schemas.common import MessageResponse, Page
from app.schemas.transcript import (
    AlertBatchCreate,
    AlertCreate,
    AlertResponse,
    AlertUpdate,
)

router = APIRouter(prefix="/alerts", tags=["위급 상황 감지"])
log = get_logger(__name__)


def _response(record: AlertEvent) -> AlertResponse:
    return AlertResponse(
        id=record.id,
        alert_type=record.alert_type,
        label_ko=record.alert_type.label_ko,
        severity=record.alert_type.severity,
        confidence=record.confidence,
        raw_class=record.raw_class,
        detected_at=record.detected_at,
        consecutive_frames=record.consecutive_frames,
        session_id=record.session_id,
        latitude=record.latitude,
        longitude=record.longitude,
        location_label=record.location_label,
        acknowledged_at=record.acknowledged_at,
        is_false_positive=record.is_false_positive,
    )


@router.post(
    "",
    response_model=AlertResponse | MessageResponse,
    status_code=status.HTTP_201_CREATED,
    summary="경보 감지 기록",
    description=(
        "온디바이스에서 감지한 경보를 서버에 기록합니다. 30초 내 동일 경보는 중복으로 무시됩니다."
    ),
)
async def record_alert(
    payload: AlertCreate,
    user: CurrentUser,
    db: DbSession,
    alerts: AlertRepo,
) -> AlertResponse | MessageResponse:
    record = await alerts.create(user.id, payload)
    await db.commit()

    if record is None:
        return MessageResponse(message="중복 경보로 기록하지 않았습니다.")
    await db.refresh(record)
    return _response(record)


@router.post(
    "/batch",
    response_model=Page[AlertResponse],
    status_code=status.HTTP_201_CREATED,
    summary="경보 일괄 업로드 (오프라인 큐)",
    description="네트워크가 끊긴 동안 기기에 쌓인 경보들을 한 번에 올립니다.",
)
async def record_alerts_batch(
    payload: AlertBatchCreate,
    user: CurrentUser,
    db: DbSession,
    alerts: AlertRepo,
) -> Page[AlertResponse]:
    created = await alerts.create_many(user.id, payload.alerts)
    await db.commit()

    for record in created:
        await db.refresh(record)

    log.info(
        "alerts_batch_uploaded",
        user_id=str(user.id),
        submitted=len(payload.alerts),
        stored=len(created),
    )
    return Page[AlertResponse](
        items=[_response(r) for r in created],
        total=len(created),
        limit=len(payload.alerts),
        offset=0,
    )


@router.get(
    "",
    response_model=Page[AlertResponse],
    summary="경보 기록 조회",
)
async def list_alerts(
    user: CurrentUser,
    alerts: AlertRepo,
    alert_type: Annotated[AlertType | None, Query(description="경보 종류로 필터")] = None,
    unacknowledged_only: Annotated[bool, Query(description="미확인만")] = False,
    date_from: datetime | None = None,
    date_to: datetime | None = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> Page[AlertResponse]:
    records, total = await alerts.list_for_user(
        user.id,
        limit=limit,
        offset=offset,
        alert_type=alert_type,
        unacknowledged_only=unacknowledged_only,
        date_from=date_from,
        date_to=date_to,
    )
    return Page[AlertResponse](
        items=[_response(r) for r in records], total=total, limit=limit, offset=offset
    )


@router.get(
    "/unacknowledged-count",
    response_model=dict[str, int],
    summary="미확인 경보 개수",
    description="앱 배지 표시용.",
)
async def unacknowledged_count(user: CurrentUser, alerts: AlertRepo) -> dict[str, int]:
    return {"count": await alerts.unacknowledged_count(user.id)}


@router.patch(
    "/{alert_id}",
    response_model=AlertResponse,
    summary="경보 확인 · 오탐 신고",
    description=(
        "사용자가 경고를 확인했거나, 잘못된 감지였다고 신고합니다. "
        "오탐 신고는 감지 민감도 조정의 근거가 됩니다."
    ),
)
async def update_alert(
    alert_id: uuid.UUID,
    payload: AlertUpdate,
    user: CurrentUser,
    db: DbSession,
    alerts: AlertRepo,
) -> AlertResponse:
    record = await alerts.update(alert_id, user.id, payload.model_dump(exclude_none=True))
    await db.commit()
    await db.refresh(record)
    return _response(record)


@router.post(
    "/acknowledge-all",
    response_model=MessageResponse,
    summary="모든 경보 확인 처리",
)
async def acknowledge_all(user: CurrentUser, db: DbSession, alerts: AlertRepo) -> MessageResponse:
    count = await alerts.acknowledge_all(user.id)
    await db.commit()
    return MessageResponse(message=f"{count}건의 경보를 확인 처리했습니다.")
