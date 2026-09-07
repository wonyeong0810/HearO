"""비밀번호 해싱과 JWT 발급/검증.

- 비밀번호: Argon2id (OWASP 권장). bcrypt 72바이트 절단 문제 없음.
- 토큰: access(짧음, stateless) + refresh(김, jti 로 폐기 가능).

리프레시 토큰은 jti 를 Redis 폐기목록에 올려 로그아웃/회전 시 무효화한다.
"""

from __future__ import annotations

import hmac
import secrets
import uuid
from datetime import UTC, datetime, timedelta
from typing import Any, Literal

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerifyMismatchError
from argon2.low_level import Type

from app.core.config import settings
from app.core.errors import InvalidTokenError, TokenExpiredError

TokenType = Literal["access", "refresh"]

# OWASP Password Storage Cheat Sheet 기준 파라미터 (m=19MiB, t=2, p=1)
_hasher = PasswordHasher(
    time_cost=2,
    memory_cost=19_456,
    parallelism=1,
    hash_len=32,
    salt_len=16,
    type=Type.ID,
)

# 존재하지 않는 계정으로 로그인해도 해시 검증과 비슷한 시간이 걸리게 해
# 타이밍으로 가입 여부를 알아내는 것을 막는다.
_DUMMY_HASH = _hasher.hash("hearo-timing-equalizer")


def hash_password(raw: str) -> str:
    return _hasher.hash(raw)


def verify_password(raw: str, hashed: str | None) -> bool:
    """비밀번호 검증. hashed 가 None 이어도 더미 검증을 수행해 시간을 맞춘다."""
    target = hashed or _DUMMY_HASH
    try:
        _hasher.verify(target, raw)
    except (VerifyMismatchError, InvalidHashError):
        return False
    return hashed is not None


def needs_rehash(hashed: str) -> bool:
    """파라미터가 상향된 뒤 로그인하면 조용히 재해싱하기 위한 판정."""
    try:
        return _hasher.check_needs_rehash(hashed)
    except InvalidHashError:
        return True


# --------------------------------------------------------------------- JWT


def _now() -> datetime:
    return datetime.now(UTC)


def _encode(
    subject: str,
    token_type: TokenType,
    expires_delta: timedelta,
    extra: dict[str, Any] | None = None,
) -> tuple[str, str, datetime]:
    """(token, jti, expires_at) 반환."""
    issued = _now()
    expires = issued + expires_delta
    jti = uuid.uuid4().hex
    payload: dict[str, Any] = {
        "sub": subject,
        "typ": token_type,
        "jti": jti,
        "iat": int(issued.timestamp()),
        "nbf": int(issued.timestamp()),
        "exp": int(expires.timestamp()),
        "iss": settings.project_name,
    }
    if extra:
        payload.update(extra)
    token = jwt.encode(payload, settings.jwt_secret_key, algorithm=settings.jwt_algorithm)
    return token, jti, expires


def create_access_token(user_id: str, extra: dict[str, Any] | None = None) -> tuple[str, datetime]:
    token, _, expires = _encode(
        user_id,
        "access",
        timedelta(minutes=settings.access_token_expire_minutes),
        extra,
    )
    return token, expires


def create_refresh_token(user_id: str) -> tuple[str, str, datetime]:
    """(token, jti, expires_at) — jti 는 폐기목록 관리용."""
    return _encode(user_id, "refresh", timedelta(days=settings.refresh_token_expire_days))


def decode_token(token: str, *, expected_type: TokenType) -> dict[str, Any]:
    """토큰을 검증해 payload 를 돌려준다. 실패 시 도메인 예외를 던진다."""
    try:
        payload: dict[str, Any] = jwt.decode(
            token,
            settings.jwt_secret_key,
            algorithms=[settings.jwt_algorithm],
            issuer=settings.project_name,
            options={"require": ["exp", "iat", "sub", "jti", "typ"]},
        )
    except jwt.ExpiredSignatureError as exc:
        raise TokenExpiredError from exc
    except jwt.InvalidTokenError as exc:
        raise InvalidTokenError from exc

    # typ 를 검사하지 않으면 refresh 토큰으로 API 를 호출할 수 있게 된다.
    if not hmac.compare_digest(str(payload.get("typ", "")), expected_type):
        raise InvalidTokenError("토큰 종류가 올바르지 않습니다.")

    return payload


# --------------------------------------------------------------------- misc


def generate_opaque_token(nbytes: int = 32) -> str:
    """WS 연결용 1회성 티켓 등, JWT 가 필요 없는 곳에 쓰는 난수 토큰."""
    return secrets.token_urlsafe(nbytes)


def constant_time_equals(a: str, b: str) -> bool:
    return hmac.compare_digest(a, b)
