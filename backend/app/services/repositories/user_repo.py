"""사용자 / 설정 데이터 접근."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.config import settings
from app.core.errors import EmailAlreadyRegisteredError, NotFoundError
from app.core.logging import get_logger
from app.core.security import hash_password
from app.db.models import User, UserSettings

log = get_logger(__name__)


def normalize_email(email: str) -> str:
    """이메일을 소문자로 정규화한다.

    로컬 파트는 원칙적으로 대소문자를 구분하지만, 실제 메일 서비스는 거의
    구분하지 않는다. 대소문자만 다른 중복 가입을 막는 편이 사용자에게 이롭다.
    """
    return email.strip().lower()


class UserRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._db = session

    # ----------------------------------------------------------------- read

    async def get_by_id(self, user_id: uuid.UUID) -> User | None:
        result = await self._db.execute(
            select(User).where(User.id == user_id).options(selectinload(User.settings))
        )
        return result.scalar_one_or_none()

    async def get_by_email(self, email: str) -> User | None:
        result = await self._db.execute(
            select(User)
            .where(User.email == normalize_email(email))
            .options(selectinload(User.settings))
        )
        return result.scalar_one_or_none()

    async def require(self, user_id: uuid.UUID) -> User:
        user = await self.get_by_id(user_id)
        if user is None:
            raise NotFoundError("사용자를 찾을 수 없습니다.")
        return user

    # ----------------------------------------------------------------- write

    async def create(self, *, email: str, password: str, display_name: str) -> User:
        user = User(
            email=normalize_email(email),
            password_hash=hash_password(password),
            display_name=display_name.strip(),
        )
        # 신규 가입자에게 기본 설정을 함께 만들어 준다 — 설정이 없는 사용자가
        # 존재하면 모든 조회 경로에 None 분기가 생긴다.
        user.settings = UserSettings(
            log_retention_days=settings.default_log_retention_days,
        )
        self._db.add(user)
        try:
            await self._db.flush()
        except IntegrityError as exc:
            await self._db.rollback()
            raise EmailAlreadyRegisteredError from exc
        return user

    async def touch_login(self, user: User) -> None:
        user.last_login_at = datetime.now(UTC)

    async def update_password(self, user: User, new_password: str) -> None:
        user.password_hash = hash_password(new_password)
        # 비밀번호가 바뀌면 기존 토큰을 전부 무효화한다.
        user.token_epoch = int(datetime.now(UTC).timestamp())

    async def rehash_password(self, user: User, raw_password: str) -> None:
        """Argon2 파라미터가 상향된 뒤 로그인 시 조용히 재해싱."""
        user.password_hash = hash_password(raw_password)

    async def bump_token_epoch(self, user: User) -> int:
        user.token_epoch = int(datetime.now(UTC).timestamp())
        return user.token_epoch

    async def deactivate(self, user: User) -> None:
        user.is_active = False
        user.token_epoch = int(datetime.now(UTC).timestamp())

    async def delete(self, user: User) -> None:
        """계정 삭제. 연관된 모든 대화 기록이 CASCADE 로 함께 지워진다."""
        await self._db.delete(user)


class SettingsRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._db = session

    async def get_or_create(self, user_id: uuid.UUID) -> UserSettings:
        result = await self._db.execute(select(UserSettings).where(UserSettings.user_id == user_id))
        existing = result.scalar_one_or_none()
        if existing is not None:
            return existing

        # 마이그레이션 이전 계정 등 설정이 없는 경우를 자가 치유한다.
        created = UserSettings(
            user_id=user_id,
            log_retention_days=settings.default_log_retention_days,
        )
        self._db.add(created)
        await self._db.flush()
        log.info("user_settings_backfilled", user_id=str(user_id))
        return created

    async def update(self, user_id: uuid.UUID, changes: dict[str, object]) -> UserSettings:
        record = await self.get_or_create(user_id)
        for key, value in changes.items():
            if value is not None and hasattr(record, key):
                setattr(record, key, value)
        await self._db.flush()
        return record

    async def users_with_expired_logs(self) -> list[tuple[uuid.UUID, int]]:
        """자동 삭제가 켜져 있고 보관 기간이 유한한 사용자 목록."""
        result = await self._db.execute(
            select(UserSettings.user_id, UserSettings.log_retention_days).where(
                UserSettings.auto_delete_enabled.is_(True),
                UserSettings.log_retention_days > 0,
            )
        )
        return [(row[0], row[1]) for row in result.all()]

    async def count(self) -> int:
        result = await self._db.execute(select(func.count()).select_from(UserSettings))
        return int(result.scalar_one())
