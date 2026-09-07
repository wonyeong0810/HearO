"""인증 엔드포인트."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Body, Request, status

from app.api.deps import CurrentUser, DbSession, UserRepo
from app.core.config import settings
from app.core.errors import (
    AccountDisabledError,
    InvalidCredentialsError,
    InvalidTokenError,
)
from app.core.logging import get_logger
from app.core.redis_client import get_redis, is_jti_revoked, revoke_all_for_user, revoke_jti
from app.core.security import (
    create_access_token,
    create_refresh_token,
    decode_token,
    generate_opaque_token,
    needs_rehash,
    verify_password,
)
from app.schemas.auth import (
    AuthResponse,
    ChangePasswordRequest,
    LoginRequest,
    RefreshRequest,
    RegisterRequest,
    TokenPair,
    UserResponse,
    WebSocketTicket,
)
from app.schemas.common import MessageResponse

router = APIRouter(prefix="/auth", tags=["인증"])
log = get_logger(__name__)

# WS 티켓 수명. 짧을수록 안전하고, 앱이 즉시 연결하므로 60초면 충분하다.
_WS_TICKET_TTL_SECONDS = 60
_WS_TICKET_PREFIX = "hearo:ws_ticket:"


def _issue_tokens(user_id: uuid.UUID) -> TokenPair:
    access_token, expires_at = create_access_token(str(user_id))
    refresh_token, _jti, _refresh_expires = create_refresh_token(str(user_id))
    return TokenPair(
        access_token=access_token,
        refresh_token=refresh_token,
        expires_at=expires_at,
        expires_in=settings.access_token_expire_minutes * 60,
    )


@router.post(
    "/register",
    response_model=AuthResponse,
    status_code=status.HTTP_201_CREATED,
    summary="회원가입",
)
async def register(payload: RegisterRequest, db: DbSession, users: UserRepo) -> AuthResponse:
    user = await users.create(
        email=payload.email,
        password=payload.password,
        display_name=payload.display_name,
    )
    await db.commit()
    await db.refresh(user)

    log.info("user_registered", user_id=str(user.id))
    return AuthResponse(
        user=UserResponse.model_validate(user),
        tokens=_issue_tokens(user.id),
    )


@router.post("/login", response_model=AuthResponse, summary="로그인")
async def login(payload: LoginRequest, db: DbSession, users: UserRepo) -> AuthResponse:
    user = await users.get_by_email(payload.email)

    # 계정이 없어도 verify_password 를 호출해 응답 시간을 맞춘다
    # (가입 여부가 타이밍으로 새어나가지 않게).
    password_ok = verify_password(payload.password, user.password_hash if user else None)

    if user is None or not password_ok:
        log.info("login_failed", email_domain=payload.email.split("@")[-1])
        raise InvalidCredentialsError
    if not user.is_active:
        raise AccountDisabledError

    # Argon2 파라미터가 올라갔으면 이 기회에 재해싱한다.
    if needs_rehash(user.password_hash):
        await users.rehash_password(user, payload.password)

    await users.touch_login(user)
    await db.commit()
    await db.refresh(user)

    log.info("login_succeeded", user_id=str(user.id))
    return AuthResponse(
        user=UserResponse.model_validate(user),
        tokens=_issue_tokens(user.id),
    )


@router.post("/refresh", response_model=TokenPair, summary="토큰 갱신")
async def refresh_tokens(payload: RefreshRequest, db: DbSession, users: UserRepo) -> TokenPair:
    claims = decode_token(payload.refresh_token, expected_type="refresh")

    jti = str(claims.get("jti", ""))
    if jti and await is_jti_revoked(jti):
        raise InvalidTokenError("이미 사용된 인증 정보입니다.")

    try:
        user_id = uuid.UUID(str(claims["sub"]))
    except (KeyError, ValueError) as exc:
        raise InvalidTokenError from exc

    user = await users.get_by_id(user_id)
    if user is None or not user.is_active:
        raise InvalidTokenError

    if user.token_epoch and int(claims.get("iat", 0)) < user.token_epoch:
        raise InvalidTokenError("다시 로그인해 주세요.")

    # 리프레시 토큰 회전: 쓴 토큰은 즉시 폐기한다. 탈취된 토큰이 재사용되면
    # 폐기목록에 걸려 막힌다.
    if jti:
        expires_at = int(claims.get("exp", 0))
        remaining = max(0, expires_at - int(datetime.now(UTC).timestamp()))
        await revoke_jti(jti, remaining)

    await db.commit()
    return _issue_tokens(user_id)


@router.post("/logout", response_model=MessageResponse, summary="로그아웃")
async def logout(
    user: CurrentUser,
    refresh_token: Annotated[str | None, Body(embed=True)] = None,
) -> MessageResponse:
    """현재 기기에서 로그아웃. 리프레시 토큰을 함께 주면 그것도 폐기한다."""
    if refresh_token:
        try:
            claims = decode_token(refresh_token, expected_type="refresh")
        except InvalidTokenError:
            # 이미 못 쓰는 토큰이면 폐기할 것도 없다.
            pass
        else:
            jti = str(claims.get("jti", ""))
            remaining = max(0, int(claims.get("exp", 0)) - int(datetime.now(UTC).timestamp()))
            if jti:
                await revoke_jti(jti, remaining)

    log.info("logout", user_id=str(user.id))
    return MessageResponse(message="로그아웃되었습니다.")


@router.post("/logout-all", response_model=MessageResponse, summary="모든 기기 로그아웃")
async def logout_all(user: CurrentUser, db: DbSession, users: UserRepo) -> MessageResponse:
    epoch = await users.bump_token_epoch(user)
    await db.commit()
    await revoke_all_for_user(str(user.id), epoch)

    log.info("logout_all", user_id=str(user.id))
    return MessageResponse(message="모든 기기에서 로그아웃되었습니다.")


@router.get("/me", response_model=UserResponse, summary="내 정보")
async def me(user: CurrentUser) -> UserResponse:
    return UserResponse.model_validate(user)


@router.post("/change-password", response_model=MessageResponse, summary="비밀번호 변경")
async def change_password(
    payload: ChangePasswordRequest,
    user: CurrentUser,
    db: DbSession,
    users: UserRepo,
) -> MessageResponse:
    if not verify_password(payload.current_password, user.password_hash):
        raise InvalidCredentialsError("현재 비밀번호가 올바르지 않습니다.")

    await users.update_password(user, payload.new_password)
    await db.commit()
    await revoke_all_for_user(str(user.id), user.token_epoch)

    log.info("password_changed", user_id=str(user.id))
    return MessageResponse(message="비밀번호가 변경되었습니다. 다시 로그인해 주세요.")


@router.post(
    "/ws-ticket",
    response_model=WebSocketTicket,
    summary="라이브 자막 WebSocket 접속 티켓 발급",
)
async def issue_ws_ticket(user: CurrentUser, request: Request) -> WebSocketTicket:
    """WebSocket 은 커스텀 헤더를 못 붙이는 클라이언트가 많아 쿼리스트링으로
    인증해야 한다. 액세스 토큰을 URL 에 실으면 프록시/서버 로그에 그대로 남으므로,
    60초짜리 1회용 티켓을 대신 쓴다."""
    ticket = generate_opaque_token(32)

    redis = get_redis()
    if redis is None:
        # Redis 가 없으면 티켓을 검증할 방법이 없다. 이건 조용히 넘어갈 문제가
        # 아니라서 명시적으로 알린다.
        from app.core.errors import ConfigurationError

        raise ConfigurationError("실시간 자막 기능을 사용할 수 없습니다 (세션 저장소 장애).")

    await redis.setex(f"{_WS_TICKET_PREFIX}{ticket}", _WS_TICKET_TTL_SECONDS, str(user.id))
    return WebSocketTicket(ticket=ticket, expires_in=_WS_TICKET_TTL_SECONDS)


async def consume_ws_ticket(ticket: str) -> uuid.UUID | None:
    """티켓을 검증하고 즉시 소모한다 (1회용)."""
    redis = get_redis()
    if redis is None or not ticket:
        return None

    key = f"{_WS_TICKET_PREFIX}{ticket}"
    # GETDEL 로 조회와 삭제를 원자적으로 처리해 재사용을 막는다.
    raw = await redis.getdel(key)
    if not raw:
        return None
    try:
        return uuid.UUID(str(raw))
    except ValueError:
        return None


@router.delete(
    "/me",
    response_model=MessageResponse,
    summary="계정 삭제",
    description="계정과 모든 대화 기록·경보 기록이 즉시 삭제됩니다. 되돌릴 수 없습니다.",
)
async def delete_account(
    user: CurrentUser,
    db: DbSession,
    users: UserRepo,
    password: Annotated[str, Body(embed=True)],
) -> MessageResponse:
    # 계정 삭제는 되돌릴 수 없으므로 비밀번호를 다시 확인한다.
    if not verify_password(password, user.password_hash):
        raise InvalidCredentialsError("비밀번호가 올바르지 않습니다.")

    user_id = str(user.id)
    await users.delete(user)
    await db.commit()
    await revoke_all_for_user(user_id, int(datetime.now(UTC).timestamp()))

    log.info("account_deleted", user_id=user_id)
    return MessageResponse(message="계정이 삭제되었습니다.")
