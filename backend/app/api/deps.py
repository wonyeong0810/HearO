"""FastAPI 의존성."""

from __future__ import annotations

import uuid
from collections.abc import AsyncGenerator
from typing import Annotated

from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import (
    AccountDisabledError,
    AuthenticationError,
    InvalidTokenError,
)
from app.core.logging import bind_contextvars
from app.core.redis_client import get_token_epoch, is_jti_revoked
from app.core.security import decode_token
from app.db.models import User
from app.db.session import get_db
from app.services.repositories.alert_repo import AlertRepository
from app.services.repositories.session_repo import (
    SessionRepository,
    SpeakerRepository,
    UtteranceRepository,
)
from app.services.repositories.user_repo import SettingsRepository, UserRepository

# auto_error=False 로 두고 우리 예외 형식으로 직접 던진다.
_bearer = HTTPBearer(auto_error=False, description="Bearer <access_token>")

DbSession = Annotated[AsyncSession, Depends(get_db)]


async def get_db_session() -> AsyncGenerator[AsyncSession]:
    async for session in get_db():
        yield session


# --------------------------------------------------------------------- auth


async def get_current_user(
    request: Request,
    db: DbSession,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)],
) -> User:
    if credentials is None or not credentials.credentials:
        raise AuthenticationError

    payload = decode_token(credentials.credentials, expected_type="access")

    jti = str(payload.get("jti", ""))
    if jti and await is_jti_revoked(jti):
        raise InvalidTokenError("만료된 인증 정보입니다.")

    try:
        user_id = uuid.UUID(str(payload["sub"]))
    except (KeyError, ValueError) as exc:
        raise InvalidTokenError from exc

    # 전체 로그아웃/비밀번호 변경 이후 발급된 토큰인지 확인한다.
    issued_at = int(payload.get("iat", 0))
    epoch = await get_token_epoch(str(user_id))
    if epoch and issued_at < epoch:
        raise InvalidTokenError("다시 로그인해 주세요.")

    user = await UserRepository(db).get_by_id(user_id)
    if user is None:
        raise InvalidTokenError
    if not user.is_active:
        raise AccountDisabledError

    # DB 에 남은 epoch 도 확인한다 (Redis 가 죽어도 무효화가 유지되어야 한다).
    if user.token_epoch and issued_at < user.token_epoch:
        raise InvalidTokenError("다시 로그인해 주세요.")

    request.state.user_id = str(user.id)
    bind_contextvars(user_id=str(user.id))
    return user


CurrentUser = Annotated[User, Depends(get_current_user)]


# --------------------------------------------------------------------- repos


def get_user_repo(db: DbSession) -> UserRepository:
    return UserRepository(db)


def get_settings_repo(db: DbSession) -> SettingsRepository:
    return SettingsRepository(db)


def get_session_repo(db: DbSession) -> SessionRepository:
    return SessionRepository(db)


def get_speaker_repo(db: DbSession) -> SpeakerRepository:
    return SpeakerRepository(db)


def get_utterance_repo(db: DbSession) -> UtteranceRepository:
    return UtteranceRepository(db)


def get_alert_repo(db: DbSession) -> AlertRepository:
    return AlertRepository(db)


UserRepo = Annotated[UserRepository, Depends(get_user_repo)]
SettingsRepo = Annotated[SettingsRepository, Depends(get_settings_repo)]
SessionRepo = Annotated[SessionRepository, Depends(get_session_repo)]
SpeakerRepo = Annotated[SpeakerRepository, Depends(get_speaker_repo)]
UtteranceRepo = Annotated[UtteranceRepository, Depends(get_utterance_repo)]
AlertRepo = Annotated[AlertRepository, Depends(get_alert_repo)]
