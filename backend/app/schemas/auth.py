"""인증 스키마."""

from __future__ import annotations

import re
import uuid
from datetime import datetime
from typing import Annotated

from pydantic import EmailStr, Field, field_validator

from app.schemas.common import APIModel

# 비밀번호 최소 요건. 길이를 우선하고 문자 종류 강제는 최소화한다
# (NIST SP 800-63B 권고: 복잡도 규칙보다 길이가 효과적).
_MIN_PASSWORD_LENGTH = 10
_MAX_PASSWORD_LENGTH = 128

# 너무 흔해 사전 공격에 즉시 뚫리는 것만 걸러낸다.
_WEAK_PATTERNS = (
    re.compile(r"^(.)\1+$"),  # 같은 문자 반복
    re.compile(r"^(0123|1234|abcd|qwer|password|비밀번호)", re.IGNORECASE),
)

Password = Annotated[str, Field(min_length=_MIN_PASSWORD_LENGTH, max_length=_MAX_PASSWORD_LENGTH)]


class RegisterRequest(APIModel):
    email: EmailStr
    password: Password
    display_name: Annotated[str, Field(min_length=1, max_length=60)]

    @field_validator("password")
    @classmethod
    def _reject_weak(cls, v: str) -> str:
        for pattern in _WEAK_PATTERNS:
            if pattern.match(v):
                raise ValueError("너무 단순한 비밀번호입니다. 다른 조합을 사용해 주세요.")
        return v

    @field_validator("display_name")
    @classmethod
    def _no_control_chars(cls, v: str) -> str:
        if any(ord(ch) < 32 for ch in v):
            raise ValueError("이름에 사용할 수 없는 문자가 있습니다.")
        return v


class LoginRequest(APIModel):
    email: EmailStr
    password: Annotated[str, Field(min_length=1, max_length=_MAX_PASSWORD_LENGTH)]


class RefreshRequest(APIModel):
    refresh_token: str


class TokenPair(APIModel):
    access_token: str
    refresh_token: str
    token_type: str = "Bearer"  # noqa: S105 — 비밀이 아니라 스킴 이름
    expires_at: datetime
    expires_in: int


class ChangePasswordRequest(APIModel):
    current_password: Annotated[str, Field(min_length=1, max_length=_MAX_PASSWORD_LENGTH)]
    new_password: Password

    @field_validator("new_password")
    @classmethod
    def _reject_weak(cls, v: str) -> str:
        return RegisterRequest._reject_weak(v)


class UserResponse(APIModel):
    id: uuid.UUID
    email: EmailStr
    display_name: str
    is_active: bool
    created_at: datetime
    last_login_at: datetime | None = None


class AuthResponse(APIModel):
    user: UserResponse
    tokens: TokenPair


class WebSocketTicket(APIModel):
    """라이브 WS 연결용 단기 티켓.

    WebSocket 은 브라우저/일부 클라이언트에서 커스텀 헤더를 못 붙이므로
    쿼리스트링으로 인증해야 한다. 액세스 토큰을 URL 에 실으면 서버 로그와
    프록시 로그에 남으므로, 60초짜리 1회용 티켓을 따로 발급한다.
    """

    ticket: str
    expires_in: int
