"""대화 세션 / 화자 / 발화 데이터 접근.

기획 3-2 의 "날짜별 / 위치별 / 화자별 분류 + 검색" 이 여기 구현된다.
한국어 검색은 pg_trgm 부분일치를 쓴다 — 영어식 형태소 분석기(tsvector)는
한국어 교착어 구조에서 "먹었어요/먹다"를 이어주지 못해 사실상 무용하다.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy import Select, delete, func, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.errors import NotFoundError, PermissionDeniedError, SessionNotFoundError
from app.core.logging import get_logger
from app.db.models import (
    AlertEvent,
    ConversationSession,
    EmotionTone,
    SessionStatus,
    Speaker,
    Utterance,
)
from app.schemas.transcript import SessionSearchParams

log = get_logger(__name__)

# 트라이그램 인덱스가 효과를 내려면 검색어가 3자 이상이어야 한다.
# 1~2자 검색은 인덱스를 못 타므로 접두어 매칭으로 대체한다.
_TRIGRAM_MIN_LENGTH = 3


class SessionRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._db = session

    # ================================================================ create

    async def create(
        self,
        *,
        user_id: uuid.UUID,
        title: str | None = None,
        location_label: str | None = None,
        latitude: float | None = None,
        longitude: float | None = None,
    ) -> ConversationSession:
        record = ConversationSession(
            user_id=user_id,
            title=title,
            status=SessionStatus.ACTIVE,
            started_at=datetime.now(UTC),
            location_label=location_label,
            latitude=latitude,
            longitude=longitude,
        )
        self._db.add(record)
        await self._db.flush()
        return record

    # ================================================================ read

    async def get(
        self, session_id: uuid.UUID, user_id: uuid.UUID, *, with_details: bool = False
    ) -> ConversationSession:
        query = select(ConversationSession).where(ConversationSession.id == session_id)
        if with_details:
            query = query.options(
                selectinload(ConversationSession.speakers),
                selectinload(ConversationSession.utterances).selectinload(Utterance.speaker),
            )

        result = await self._db.execute(query)
        record = result.scalar_one_or_none()
        if record is None:
            raise SessionNotFoundError
        # 소유자 확인을 조회 조건이 아니라 별도 검사로 둔다 — 존재하지 않는 것과
        # 남의 것을 구분해 로그로 남기기 위해서다. 응답은 둘 다 404 로 통일한다.
        if record.user_id != user_id:
            log.warning("session_access_denied", session_id=str(session_id), user_id=str(user_id))
            raise SessionNotFoundError
        return record

    async def get_active(self, user_id: uuid.UUID) -> list[ConversationSession]:
        result = await self._db.execute(
            select(ConversationSession).where(
                ConversationSession.user_id == user_id,
                ConversationSession.status == SessionStatus.ACTIVE,
            )
        )
        return list(result.scalars().all())

    # ================================================================ search

    def _apply_filters(
        self, query: Select[Any], user_id: uuid.UUID, params: SessionSearchParams
    ) -> Select[Any]:
        query = query.where(ConversationSession.user_id == user_id)

        if params.date_from:
            query = query.where(ConversationSession.started_at >= params.date_from)
        if params.date_to:
            query = query.where(ConversationSession.started_at <= params.date_to)

        if params.location:
            query = query.where(ConversationSession.location_label.ilike(f"%{params.location}%"))

        if params.favorites_only:
            query = query.where(ConversationSession.is_favorite.is_(True))

        if params.tone:
            query = query.where(ConversationSession.dominant_tone == params.tone)

        if params.speaker_name:
            speaker_match = (
                select(Speaker.session_id)
                .where(Speaker.display_name.ilike(f"%{params.speaker_name}%"))
                .scalar_subquery()
            )
            query = query.where(ConversationSession.id.in_(speaker_match))

        if params.q:
            term = params.q.strip()
            if len(term) >= _TRIGRAM_MIN_LENGTH:
                text_match = (
                    select(Utterance.session_id)
                    .where(Utterance.text.ilike(f"%{term}%"))
                    .scalar_subquery()
                )
            else:
                # 짧은 검색어는 접두어로만 찾는다 (인덱스 미사용 전체 스캔 방지).
                text_match = (
                    select(Utterance.session_id)
                    .where(Utterance.text.ilike(f"{term}%"))
                    .scalar_subquery()
                )
            query = query.where(
                or_(
                    ConversationSession.title.ilike(f"%{term}%"),
                    ConversationSession.preview_text.ilike(f"%{term}%"),
                    ConversationSession.id.in_(text_match),
                )
            )

        return query

    async def search(
        self, user_id: uuid.UUID, params: SessionSearchParams
    ) -> tuple[list[ConversationSession], int]:
        base = self._apply_filters(select(ConversationSession), user_id, params)

        count_query = self._apply_filters(
            select(func.count()).select_from(ConversationSession), user_id, params
        )
        total = int((await self._db.execute(count_query)).scalar_one())

        sort_column = {
            "started_at": ConversationSession.started_at,
            "duration": ConversationSession.duration_seconds,
            "utterance_count": ConversationSession.utterance_count,
        }[params.sort]
        ordering = sort_column.desc() if params.order == "desc" else sort_column.asc()

        result = await self._db.execute(
            base.order_by(ordering, ConversationSession.id.desc())
            .limit(params.limit)
            .offset(params.offset)
        )
        return list(result.scalars().all()), total

    async def search_utterances(
        self,
        user_id: uuid.UUID,
        term: str,
        *,
        limit: int = 50,
        offset: int = 0,
    ) -> tuple[list[tuple[Utterance, ConversationSession, Speaker | None]], int]:
        """발화 단위 전문 검색 — 어느 대화의 몇 번째 줄인지까지 돌려준다."""
        pattern = f"%{term}%" if len(term) >= _TRIGRAM_MIN_LENGTH else f"{term}%"

        base = (
            select(Utterance, ConversationSession, Speaker)
            .join(ConversationSession, Utterance.session_id == ConversationSession.id)
            .outerjoin(Speaker, Utterance.speaker_id == Speaker.id)
            .where(
                ConversationSession.user_id == user_id,
                Utterance.text.ilike(pattern),
            )
        )

        count_query = (
            select(func.count())
            .select_from(Utterance)
            .join(ConversationSession, Utterance.session_id == ConversationSession.id)
            .where(
                ConversationSession.user_id == user_id,
                Utterance.text.ilike(pattern),
            )
        )
        total = int((await self._db.execute(count_query)).scalar_one())

        result = await self._db.execute(
            base.order_by(ConversationSession.started_at.desc(), Utterance.sequence)
            .limit(limit)
            .offset(offset)
        )
        rows = [(row[0], row[1], row[2]) for row in result.all()]
        return rows, total

    # ================================================================ update

    async def update(
        self, session_id: uuid.UUID, user_id: uuid.UUID, changes: dict[str, Any]
    ) -> ConversationSession:
        record = await self.get(session_id, user_id)
        for key, value in changes.items():
            if value is not None and hasattr(record, key):
                setattr(record, key, value)
        await self._db.flush()
        return record

    async def finalize(
        self,
        session_id: uuid.UUID,
        *,
        utterance_count: int,
        speaker_count: int,
        duration_seconds: float,
        dominant_tone: EmotionTone | None,
        preview_text: str | None,
        status: SessionStatus = SessionStatus.ENDED,
    ) -> None:
        """라이브 세션 종료 시 집계값을 비정규화 필드에 써 넣는다."""
        await self._db.execute(
            update(ConversationSession)
            .where(ConversationSession.id == session_id)
            .values(
                status=status,
                ended_at=datetime.now(UTC),
                utterance_count=utterance_count,
                speaker_count=speaker_count,
                duration_seconds=duration_seconds,
                dominant_tone=dominant_tone,
                preview_text=preview_text,
            )
        )

    async def discard_if_empty(self, session_id: uuid.UUID) -> bool:
        """한 마디도 안 잡힌 세션을 지운다. 지웠으면 True.

        자막을 켰다가 아무도 말하지 않고 껐을 때, 기록 목록에 빈 줄만 남는다.
        내용이 없는 대화는 열어 볼 것도, 검색될 것도, 즐겨찾기할 것도 없다.
        녹음기가 무음 파일을 저장하지 않는 것과 같다.

        다만 이 세션에 묶인 경보 기록이 있으면 남긴다. `alert_events.session_id`
        는 ON DELETE SET NULL 이라 세션을 지우면 "그때 어디서 울렸는지"의 맥락이
        조용히 끊긴다. 경보가 울리는 동안 아무도 말하지 않는 건 오히려 흔한
        상황이라, 하필 그때 맥락을 잃는다.
        """
        linked_alerts = await self._db.scalar(
            select(func.count()).select_from(AlertEvent).where(AlertEvent.session_id == session_id)
        )
        if linked_alerts:
            return False

        result = await self._db.execute(
            delete(ConversationSession).where(ConversationSession.id == session_id)
        )
        return bool(result.rowcount)

    async def mark_abandoned(self, session_id: uuid.UUID) -> None:
        await self._db.execute(
            update(ConversationSession)
            .where(
                ConversationSession.id == session_id,
                ConversationSession.status == SessionStatus.ACTIVE,
            )
            .values(status=SessionStatus.ABANDONED, ended_at=datetime.now(UTC))
        )

    async def delete(self, session_id: uuid.UUID, user_id: uuid.UUID) -> None:
        record = await self.get(session_id, user_id)
        await self._db.delete(record)

    async def delete_many(self, session_ids: list[uuid.UUID], user_id: uuid.UUID) -> int:
        if not session_ids:
            return 0
        result = await self._db.execute(
            delete(ConversationSession).where(
                ConversationSession.id.in_(session_ids),
                ConversationSession.user_id == user_id,
            )
        )
        return int(result.rowcount or 0)

    # ================================================================ retention

    async def delete_expired(self, user_id: uuid.UUID, retention_days: int) -> int:
        """보관 기간이 지난 세션을 삭제한다. 즐겨찾기는 남긴다.

        사용자가 명시적으로 중요 표시한 대화까지 자동 삭제하면 신뢰를 잃는다.
        """
        if retention_days <= 0:
            return 0

        cutoff = datetime.now(UTC) - timedelta(days=retention_days)
        result = await self._db.execute(
            delete(ConversationSession).where(
                ConversationSession.user_id == user_id,
                ConversationSession.is_favorite.is_(False),
                ConversationSession.started_at < cutoff,
            )
        )
        return int(result.rowcount or 0)

    async def sweep_abandoned(self, older_than_seconds: int) -> int:
        """앱이 죽어 종료 신호를 못 받은 ACTIVE 세션을 정리한다."""
        cutoff = datetime.now(UTC) - timedelta(seconds=older_than_seconds)
        result = await self._db.execute(
            update(ConversationSession)
            .where(
                ConversationSession.status == SessionStatus.ACTIVE,
                ConversationSession.started_at < cutoff,
            )
            .values(status=SessionStatus.ABANDONED, ended_at=func.now())
        )
        return int(result.rowcount or 0)

    # ================================================================ stats

    async def stats(self, user_id: uuid.UUID) -> dict[str, Any]:
        totals = await self._db.execute(
            select(
                func.count(ConversationSession.id),
                func.coalesce(func.sum(ConversationSession.utterance_count), 0),
                func.coalesce(func.sum(ConversationSession.duration_seconds), 0.0),
                func.count(ConversationSession.id).filter(
                    ConversationSession.is_favorite.is_(True)
                ),
                func.min(ConversationSession.started_at),
            ).where(ConversationSession.user_id == user_id)
        )
        count, utterances, duration, favorites, oldest = totals.one()

        tone_rows = await self._db.execute(
            select(Utterance.tone, func.count(Utterance.id))
            .join(ConversationSession, Utterance.session_id == ConversationSession.id)
            .where(ConversationSession.user_id == user_id)
            .group_by(Utterance.tone)
        )
        distribution = {tone.value: int(n) for tone, n in tone_rows.all()}

        return {
            "total_sessions": int(count),
            "total_utterances": int(utterances),
            "total_duration_seconds": float(duration),
            "favorite_sessions": int(favorites),
            "oldest_session_at": oldest,
            "tone_distribution": distribution,
        }


class SpeakerRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._db = session

    async def upsert(
        self,
        *,
        session_id: uuid.UUID,
        label: str,
        color_hex: str,
        display_name: str | None = None,
    ) -> Speaker:
        result = await self._db.execute(
            select(Speaker).where(Speaker.session_id == session_id, Speaker.label == label)
        )
        existing = result.scalar_one_or_none()
        if existing is not None:
            return existing

        record = Speaker(
            session_id=session_id,
            label=label,
            color_hex=color_hex,
            display_name=display_name,
        )
        self._db.add(record)
        await self._db.flush()
        return record

    async def get_by_label(self, session_id: uuid.UUID, label: str) -> Speaker | None:
        result = await self._db.execute(
            select(Speaker).where(Speaker.session_id == session_id, Speaker.label == label)
        )
        return result.scalar_one_or_none()

    async def update(
        self, speaker_id: uuid.UUID, user_id: uuid.UUID, changes: dict[str, Any]
    ) -> Speaker:
        result = await self._db.execute(
            select(Speaker)
            .join(ConversationSession, Speaker.session_id == ConversationSession.id)
            .where(Speaker.id == speaker_id)
        )
        record = result.scalar_one_or_none()
        if record is None:
            raise NotFoundError("화자를 찾을 수 없습니다.")

        owner = await self._db.execute(
            select(ConversationSession.user_id).where(ConversationSession.id == record.session_id)
        )
        if owner.scalar_one() != user_id:
            raise PermissionDeniedError

        if (name := changes.get("display_name")) is not None:
            record.display_name = name
        if (color := changes.get("color_hex")) is not None:
            record.color_hex = color
            # 사용자가 직접 고른 색은 자동 배정으로 덮어쓰지 않는다.
            record.color_is_custom = True

        await self._db.flush()
        return record

    async def bump_stats(self, speaker_id: uuid.UUID, *, utterances: int, seconds: float) -> None:
        await self._db.execute(
            update(Speaker)
            .where(Speaker.id == speaker_id)
            .values(
                utterance_count=Speaker.utterance_count + utterances,
                total_speaking_seconds=Speaker.total_speaking_seconds + seconds,
            )
        )


class UtteranceRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._db = session

    async def upsert_many(self, rows: list[dict[str, Any]]) -> None:
        """라이브 파이프라인이 보내는 배치를 저장한다.

        같은 발화가 여러 번(텍스트 확정 → 화자 확정 → 톤 확정) 올라오므로
        PK 기준 upsert 로 처리한다.
        """
        if not rows:
            return

        from sqlalchemy.dialects.postgresql import insert as pg_insert

        statement = pg_insert(Utterance).values(rows)
        statement = statement.on_conflict_do_update(
            index_elements=[Utterance.id],
            set_={
                "text": statement.excluded.text,
                "speaker_id": statement.excluded.speaker_id,
                "tone": statement.excluded.tone,
                "tone_confidence": statement.excluded.tone_confidence,
                "tone_basis": statement.excluded.tone_basis,
                "intensity": statement.excluded.intensity,
                "loudness_dbfs": statement.excluded.loudness_dbfs,
                "pitch_hz": statement.excluded.pitch_hz,
                "speech_rate": statement.excluded.speech_rate,
                "is_final": statement.excluded.is_final,
                "speaker_resolved": statement.excluded.speaker_resolved,
                "end_ms": statement.excluded.end_ms,
                "updated_at": func.now(),
            },
        )
        await self._db.execute(statement)

    async def update(
        self, utterance_id: uuid.UUID, user_id: uuid.UUID, changes: dict[str, Any]
    ) -> Utterance:
        result = await self._db.execute(
            select(Utterance, ConversationSession.user_id)
            .join(ConversationSession, Utterance.session_id == ConversationSession.id)
            .where(Utterance.id == utterance_id)
        )
        row = result.one_or_none()
        if row is None:
            raise NotFoundError("자막을 찾을 수 없습니다.")

        record, owner_id = row
        if owner_id != user_id:
            raise PermissionDeniedError

        if (bookmarked := changes.get("is_bookmarked")) is not None:
            record.is_bookmarked = bookmarked
        if (text := changes.get("text")) is not None:
            record.text = text

        await self._db.flush()
        return record

    async def bookmarked(
        self, user_id: uuid.UUID, *, limit: int = 50, offset: int = 0
    ) -> tuple[list[tuple[Utterance, ConversationSession]], int]:
        base = (
            select(Utterance, ConversationSession)
            .join(ConversationSession, Utterance.session_id == ConversationSession.id)
            .where(
                ConversationSession.user_id == user_id,
                Utterance.is_bookmarked.is_(True),
            )
        )
        total_query = (
            select(func.count())
            .select_from(Utterance)
            .join(ConversationSession, Utterance.session_id == ConversationSession.id)
            .where(
                ConversationSession.user_id == user_id,
                Utterance.is_bookmarked.is_(True),
            )
        )
        total = int((await self._db.execute(total_query)).scalar_one())

        result = await self._db.execute(
            base.order_by(ConversationSession.started_at.desc(), Utterance.sequence)
            .limit(limit)
            .offset(offset)
        )
        return [(row[0], row[1]) for row in result.all()], total
