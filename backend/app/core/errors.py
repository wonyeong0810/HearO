"""도메인 예외와 전역 예외 핸들러.

클라이언트로 나가는 에러는 항상 같은 형태다:

    {"error": {"code": "SESSION_NOT_FOUND", "message": "...", "details": {...}}}

Flutter 쪽에서 `code` 로 분기하므로 code 는 안정적인 계약이다. 문구(message)는
사용자에게 그대로 보여줄 수 있는 한국어여야 한다.
"""

from __future__ import annotations

from typing import Any

from fastapi import FastAPI, Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.core.config import settings
from app.core.logging import get_logger

log = get_logger(__name__)


class HearOError(Exception):
    """모든 도메인 예외의 부모."""

    status_code: int = status.HTTP_400_BAD_REQUEST
    code: str = "BAD_REQUEST"
    message: str = "요청을 처리할 수 없습니다."

    def __init__(
        self,
        message: str | None = None,
        *,
        details: dict[str, Any] | None = None,
        code: str | None = None,
    ) -> None:
        self.message = message or self.message
        self.details = details or {}
        if code:
            self.code = code
        super().__init__(self.message)

    def to_payload(self) -> dict[str, Any]:
        body: dict[str, Any] = {"code": self.code, "message": self.message}
        if self.details:
            body["details"] = self.details
        return {"error": body}


# --------------------------------------------------------------------- 401 / 403
class AuthenticationError(HearOError):
    status_code = status.HTTP_401_UNAUTHORIZED
    code = "UNAUTHENTICATED"
    message = "로그인이 필요합니다."


class InvalidCredentialsError(AuthenticationError):
    code = "INVALID_CREDENTIALS"
    message = "이메일 또는 비밀번호가 올바르지 않습니다."


class TokenExpiredError(AuthenticationError):
    code = "TOKEN_EXPIRED"
    message = "인증이 만료되었습니다. 다시 로그인해 주세요."


class InvalidTokenError(AuthenticationError):
    code = "INVALID_TOKEN"
    message = "인증 정보가 올바르지 않습니다."


class PermissionDeniedError(HearOError):
    status_code = status.HTTP_403_FORBIDDEN
    code = "PERMISSION_DENIED"
    message = "이 리소스에 접근할 권한이 없습니다."


class AccountDisabledError(HearOError):
    status_code = status.HTTP_403_FORBIDDEN
    code = "ACCOUNT_DISABLED"
    message = "비활성화된 계정입니다."


# --------------------------------------------------------------------- 404 / 409
class NotFoundError(HearOError):
    status_code = status.HTTP_404_NOT_FOUND
    code = "NOT_FOUND"
    message = "요청한 항목을 찾을 수 없습니다."


class SessionNotFoundError(NotFoundError):
    code = "SESSION_NOT_FOUND"
    message = "대화 기록을 찾을 수 없습니다."


class ConflictError(HearOError):
    status_code = status.HTTP_409_CONFLICT
    code = "CONFLICT"
    message = "이미 존재하는 항목입니다."


class EmailAlreadyRegisteredError(ConflictError):
    code = "EMAIL_ALREADY_REGISTERED"
    message = "이미 가입된 이메일입니다."


# --------------------------------------------------------------------- 422 / 429
class ValidationError(HearOError):
    # 422 를 상수 대신 리터럴로 쓴다 — Starlette 가 이 상수의 이름을
    # HTTP_422_UNPROCESSABLE_ENTITY → HTTP_422_UNPROCESSABLE_CONTENT 로 바꿨고,
    # 버전에 따라 한쪽이 DeprecationWarning 을 던진다.
    status_code = 422
    code = "VALIDATION_ERROR"
    message = "입력값이 올바르지 않습니다."


class RateLimitedError(HearOError):
    status_code = status.HTTP_429_TOO_MANY_REQUESTS
    code = "RATE_LIMITED"
    message = "요청이 너무 잦습니다. 잠시 후 다시 시도해 주세요."


class TooManyLiveSessionsError(HearOError):
    status_code = status.HTTP_429_TOO_MANY_REQUESTS
    code = "TOO_MANY_LIVE_SESSIONS"
    message = "동시에 열 수 있는 실시간 자막 수를 초과했습니다."


# --------------------------------------------------------------------- 5xx / 503
class UpstreamError(HearOError):
    """OpenAI 등 외부 의존성 실패."""

    status_code = status.HTTP_502_BAD_GATEWAY
    code = "UPSTREAM_ERROR"
    message = "음성 인식 서버와 통신하지 못했습니다."


class SpeechServiceUnavailableError(UpstreamError):
    status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    code = "SPEECH_SERVICE_UNAVAILABLE"
    message = "음성 인식 서비스를 일시적으로 사용할 수 없습니다."


class ConfigurationError(HearOError):
    status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    code = "NOT_CONFIGURED"
    message = "서버 설정이 완료되지 않았습니다. 관리자에게 문의하세요."


# --------------------------------------------------------------------- handlers


def _json(status_code: int, payload: dict[str, Any]) -> JSONResponse:
    return JSONResponse(status_code=status_code, content=payload)


async def hearo_error_handler(request: Request, exc: Exception) -> JSONResponse:
    assert isinstance(exc, HearOError)
    # 4xx 는 정상적인 흐름이므로 info, 5xx 만 error 로 남긴다.
    logger = log.error if exc.status_code >= 500 else log.info
    logger(
        "domain_error",
        code=exc.code,
        status=exc.status_code,
        path=request.url.path,
        detail=exc.message,
    )
    return _json(exc.status_code, exc.to_payload())


async def http_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    assert isinstance(exc, StarletteHTTPException)
    code = {
        401: "UNAUTHENTICATED",
        403: "PERMISSION_DENIED",
        404: "NOT_FOUND",
        405: "METHOD_NOT_ALLOWED",
    }.get(exc.status_code, "HTTP_ERROR")
    return _json(
        exc.status_code,
        {"error": {"code": code, "message": str(exc.detail)}},
    )


async def validation_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    assert isinstance(exc, RequestValidationError)
    fields = [
        {
            "field": ".".join(str(p) for p in err["loc"][1:]) or str(err["loc"][0]),
            "reason": err["msg"],
        }
        for err in exc.errors()
    ]
    log.info("validation_error", path=request.url.path, fields=fields)
    return _json(
        422,
        {
            "error": {
                "code": "VALIDATION_ERROR",
                "message": "입력값이 올바르지 않습니다.",
                "details": {"fields": fields},
            }
        },
    )


async def unhandled_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    log.exception(
        "unhandled_exception",
        path=request.url.path,
        method=request.method,
        exc_type=type(exc).__name__,
    )
    body: dict[str, Any] = {
        "code": "INTERNAL_ERROR",
        "message": "서버에 문제가 발생했습니다. 잠시 후 다시 시도해 주세요.",
    }
    # 운영에서는 스택트레이스를 절대 노출하지 않는다.
    if settings.debug and not settings.is_production:
        body["details"] = {"exception": f"{type(exc).__name__}: {exc}"}
    return _json(status.HTTP_500_INTERNAL_SERVER_ERROR, {"error": body})


def register_exception_handlers(app: FastAPI) -> None:
    app.add_exception_handler(HearOError, hearo_error_handler)
    app.add_exception_handler(StarletteHTTPException, http_exception_handler)
    app.add_exception_handler(RequestValidationError, validation_exception_handler)
    app.add_exception_handler(Exception, unhandled_exception_handler)
