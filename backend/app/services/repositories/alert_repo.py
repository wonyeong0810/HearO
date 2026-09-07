"""경보 이벤트 데이터 접근."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import NotFoundError
from app.core.logging import get_logger
from app.db.models import AlertEvent, AlertType, ConversationSession
from app.schemas.transcript import AlertCreate

log = get_logger(__name__)

# 같은 경보가 이 시간 안에 다시 올라오면 중복으로 본다.
# 앱의 디바운스를 통과한 뒤에도 오프라인 큐 재전송 등으로 중복이 생길 수 있다.
_DEDUP_WINDOW_SECONDS = 30


class AlertRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._db = session

    # ----------------------------------------------------------------- write

    async def create(self, user_id: uuid.UUID, payload: AlertCreate) -> AlertEvent | None:
        """경보를 기록한다. 중복이면 None 을 돌려준다."""
        if await self._is_duplicate(user_id, payload):
            log.info(
                "alert_deduplicated",
                user_id=str(user_id),
                alert_type=payload.alert_type.value,
            )
            return None

        # 세션이 지정됐다면 소유자가 맞는지 확인한다. 아니면 그냥 연결을 끊는다
        # (경보 자체는 기록되어야 하므로 예외를 던지지 않는다).
        session_id = payload.session_id
        if session_id is not None:
            owner = await self._db.execute(
                select(ConversationSession.user_id).where(ConversationSession.id == session_id)
            )
            if owner.scalar_one_or_none() != user_id:
                log.warning("alert_session_mismatch", session_id=str(session_id))
                session_id = None

        record = AlertEvent(
            user_id=user_id,
            session_id=session_id,
            alert_type=payload.alert_type,
            confidence=payload.confidence,
            raw_class=payload.raw_class,
            detected_at=payload.detected_at,
            consecutive_frames=payload.consecutive_frames,
            latitude=payload.latitude,
            longitude=payload.longitude,
            location_label=payload.location_label,
        )
        self._db.add(record)
        await self._db.flush()

        log.info(
            "alert_recorded",
            user_id=str(user_id),
            alert_type=payload.alert_type.value,
            severity=payload.alert_type.severity,
            confidence=round(payload.confidence, 2),
        )
        return record

    async def create_many(
        self, user_id: uuid.UUID, payloads: list[AlertCreate]
    ) -> list[AlertEvent]:
        """오프라인 큐 일괄 업로드. 중복은 건너뛴다."""
        created: list[AlertEvent] = []
        # 감지 시각 순으로 처리해야 중복 판정이 일관된다.
        for payload in sorted(payloads, key=lambda p: p.detected_at):
            if record := await self.create(user_id, payload):
                created.append(record)
        return created

    async def _is_duplicate(self, user_id: uuid.UUID, payload: AlertCreate) -> bool:
        window_start = payload.detected_at - timedelta(seconds=_DEDUP_WINDOW_SECONDS)
        result = await self._db.execute(
            select(func.count())
            .select_from(AlertEvent)
            .where(
                AlertEvent.user_id == user_id,
                AlertEvent.alert_type == payload.alert_type,
                AlertEvent.detected_at >= window_start,
                AlertEvent.detected_at <= payload.detected_at,
            )
        )
        return int(result.scalar_one()) > 0

    async def update(
        self, alert_id: uuid.UUID, user_id: uuid.UUID, changes: dict[str, Any]
    ) -> AlertEvent:
        result = await self._db.execute(
            select(AlertEvent).where(AlertEvent.id == alert_id, AlertEvent.user_id == user_id)
        )
        record = result.scalar_one_or_none()
        if record is None:
            raise NotFoundError("경보 기록을 찾을 수 없습니다.")

        if changes.get("acknowledged") is True and record.acknowledged_at is None:
            record.acknowledged_at = datetime.now(UTC)
        elif changes.get("acknowledged") is False:
            record.acknowledged_at = None

        if (false_positive := changes.get("is_false_positive")) is not None:
            record.is_false_positive = false_positive
            if false_positive:
                log.info(
                    "alert_marked_false_positive",
                    alert_id=str(alert_id),
                    alert_type=record.alert_type.value,
                    confidence=record.confidence,
                    raw_class=record.raw_class,
                )

        await self._db.flush()
        return record

    async def acknowledge_all(self, user_id: uuid.UUID) -> int:
        result = await self._db.execute(
            update(AlertEvent)
            .where(
                AlertEvent.user_id == user_id,
                AlertEvent.acknowledged_at.is_(None),
            )
            .values(acknowledged_at=datetime.now(UTC))
        )
        return int(result.rowcount or 0)

    # ----------------------------------------------------------------- read

    async def list_for_user(
        self,
        user_id: uuid.UUID,
        *,
        limit: int = 50,
        offset: int = 0,
        alert_type: AlertType | None = None,
        unacknowledged_only: bool = False,
        date_from: datetime | None = None,
        date_to: datetime | None = None,
    ) -> tuple[list[AlertEvent], int]:
        conditions = [AlertEvent.user_id == user_id]
        if alert_type is not None:
            conditions.append(AlertEvent.alert_type == alert_type)
        if unacknowledged_only:
            conditions.append(AlertEvent.acknowledged_at.is_(None))
        if date_from is not None:
            conditions.append(AlertEvent.detected_at >= date_from)
        if date_to is not None:
            conditions.append(AlertEvent.detected_at <= date_to)

        total = int(
            (
                await self._db.execute(
                    select(func.count()).select_from(AlertEvent).where(*conditions)
                )
            ).scalar_one()
        )

        result = await self._db.execute(
            select(AlertEvent)
            .where(*conditions)
            .order_by(AlertEvent.detected_at.desc())
            .limit(limit)
            .offset(offset)
        )
        return list(result.scalars().all()), total

    async def unacknowledged_count(self, user_id: uuid.UUID) -> int:
        result = await self._db.execute(
            select(func.count())
            .select_from(AlertEvent)
            .where(
                AlertEvent.user_id == user_id,
                AlertEvent.acknowledged_at.is_(None),
            )
        )
        return int(result.scalar_one())

    async def count_for_user(self, user_id: uuid.UUID) -> int:
        result = await self._db.execute(
            select(func.count()).select_from(AlertEvent).where(AlertEvent.user_id == user_id)
        )
        return int(result.scalar_one())

    async def delete_expired(self, user_id: uuid.UUID, retention_days: int) -> int:
        """경보 기록도 보관 주기를 따른다. 단, 미확인 경보는 남긴다."""
        if retention_days <= 0:
            return 0

        from sqlalchemy import delete

        cutoff = datetime.now(UTC) - timedelta(days=retention_days)
        result = await self._db.execute(
            delete(AlertEvent).where(
                AlertEvent.user_id == user_id,
                AlertEvent.detected_at < cutoff,
                AlertEvent.acknowledged_at.is_not(None),
            )
        )
        return int(result.rowcount or 0)
