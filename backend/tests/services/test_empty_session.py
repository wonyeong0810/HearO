"""내용 없는 세션은 기록에 남기지 않는다.

자막을 켰다가 아무도 말하지 않고 껐을 때 기록 목록에 빈 대화가 쌓이던 문제.
열어 볼 것도 검색될 것도 없는 줄이 계속 늘어나면 기록 화면 자체가 못 쓰게 된다.

다만 경보 기록이 묶여 있으면 지우지 않는다 — `alert_events.session_id` 가
ON DELETE SET NULL 이라 세션을 지우면 맥락이 조용히 끊긴다. 경보가 울리는 동안
아무도 말하지 않는 것은 오히려 흔한 상황이다.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import AlertEvent, AlertType, ConversationSession, User
from app.services.repositories.session_repo import SessionRepository
from tests.conftest import requires_db

# asyncio_mode = "auto" 라 async 테스트에 별도 마크가 필요 없다.
pytestmark = requires_db


async def _user(db: AsyncSession) -> User:
    user = User(
        email=f"empty-{uuid.uuid4().hex[:10]}@example.com",
        password_hash="x" * 60,
        display_name="테스트",
    )
    db.add(user)
    await db.flush()
    return user


async def _exists(db: AsyncSession, session_id: uuid.UUID) -> bool:
    found = await db.scalar(
        select(ConversationSession.id).where(ConversationSession.id == session_id)
    )
    return found is not None


class TestDiscardIfEmpty:
    async def test_empty_session_is_removed(self, db: AsyncSession) -> None:
        user = await _user(db)
        repo = SessionRepository(db)
        record = await repo.create(user_id=user.id)

        assert await repo.discard_if_empty(record.id) is True
        assert await _exists(db, record.id) is False

    async def test_session_with_linked_alert_is_kept(self, db: AsyncSession) -> None:
        # 경보가 울리는 동안 아무도 말하지 않았다. 세션을 지우면 그 경보가
        # 어느 대화 중이었는지 알 수 없게 된다.
        user = await _user(db)
        repo = SessionRepository(db)
        record = await repo.create(user_id=user.id)

        db.add(
            AlertEvent(
                user_id=user.id,
                session_id=record.id,
                alert_type=AlertType.FIRE_ALARM,
                confidence=0.92,
                detected_at=datetime.now(UTC),
                consecutive_frames=6,
            )
        )
        await db.flush()

        assert await repo.discard_if_empty(record.id) is False
        assert await _exists(db, record.id) is True

    async def test_returns_false_for_unknown_session(self, db: AsyncSession) -> None:
        repo = SessionRepository(db)
        assert await repo.discard_if_empty(uuid.uuid4()) is False

    async def test_discarded_session_leaves_history_empty(self, db: AsyncSession) -> None:
        from app.schemas.transcript import SessionSearchParams

        user = await _user(db)
        repo = SessionRepository(db)
        record = await repo.create(user_id=user.id)
        await repo.discard_if_empty(record.id)

        sessions, total = await repo.search(user.id, SessionSearchParams())
        assert total == 0
        assert sessions == []


class TestFinalizedSessionStillSaved:
    async def test_session_with_utterances_survives_finalize(self, db: AsyncSession) -> None:
        # 말을 한 세션까지 사라지면 그게 훨씬 나쁜 버그다.
        user = await _user(db)
        repo = SessionRepository(db)
        record = await repo.create(user_id=user.id)

        await repo.finalize(
            record.id,
            utterance_count=3,
            speaker_count=2,
            duration_seconds=12.5,
            dominant_tone=None,
            preview_text="안녕하세요",
        )

        assert await _exists(db, record.id) is True
