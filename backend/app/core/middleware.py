"""요청 단위 미들웨어: request-id, 접근 로그, 보안 헤더, 레이트리밋."""

from __future__ import annotations

import time
import uuid
from collections.abc import Awaitable, Callable

from fastapi import FastAPI, Request, Response
from redis.exceptions import RedisError
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.middleware.cors import CORSMiddleware
from starlette.middleware.gzip import GZipMiddleware
from starlette.middleware.trustedhost import TrustedHostMiddleware
from starlette.responses import JSONResponse

from app.core.config import settings
from app.core.logging import bind_contextvars, clear_contextvars, get_logger
from app.core.redis_client import get_redis

log = get_logger(__name__)

NextCall = Callable[[Request], Awaitable[Response]]

# 헬스체크는 로그를 남기지 않는다 (k8s probe 가 초당 여러 번 때린다).
_QUIET_PATHS = frozenset({"/health/live", "/health/ready", "/metrics", "/favicon.ico"})


class RequestContextMiddleware(BaseHTTPMiddleware):
    """request_id 부여 + 구조화 접근 로그 + 처리시간 헤더."""

    async def dispatch(self, request: Request, call_next: NextCall) -> Response:
        request_id = request.headers.get("X-Request-ID") or uuid.uuid4().hex[:16]
        request.state.request_id = request_id

        clear_contextvars()
        bind_contextvars(
            request_id=request_id,
            method=request.method,
            path=request.url.path,
        )

        start = time.perf_counter()
        try:
            response = await call_next(request)
        except Exception:
            elapsed_ms = (time.perf_counter() - start) * 1000
            log.exception("request_failed", duration_ms=round(elapsed_ms, 2))
            raise
        finally:
            clear_contextvars()

        elapsed_ms = (time.perf_counter() - start) * 1000
        response.headers["X-Request-ID"] = request_id
        response.headers["X-Response-Time-ms"] = f"{elapsed_ms:.1f}"

        if request.url.path not in _QUIET_PATHS:
            log.info(
                "request",
                request_id=request_id,
                method=request.method,
                path=request.url.path,
                status=response.status_code,
                duration_ms=round(elapsed_ms, 2),
            )
        return response


class SecurityHeadersMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next: NextCall) -> Response:
        response = await call_next(request)
        headers = response.headers
        headers.setdefault("X-Content-Type-Options", "nosniff")
        headers.setdefault("X-Frame-Options", "DENY")
        headers.setdefault("Referrer-Policy", "no-referrer")
        headers.setdefault("Permissions-Policy", "geolocation=(), camera=(), microphone=()")
        headers.setdefault("Cross-Origin-Opener-Policy", "same-origin")
        # API 응답은 절대 캐시하지 않는다 (대화 기록이 프록시에 남으면 안 됨).
        if request.url.path.startswith(settings.api_v1_prefix):
            headers.setdefault("Cache-Control", "no-store")
        if settings.is_production:
            headers.setdefault(
                "Strict-Transport-Security", "max-age=63072000; includeSubDomains; preload"
            )
        return response


class RateLimitMiddleware(BaseHTTPMiddleware):
    """고정 창(fixed window) 레이트리밋.

    키는 인증 사용자면 user_id, 아니면 클라이언트 IP. Redis 가 없으면 통과시킨다
    (자막 서비스가 레이트리밋 백엔드 장애로 멈추는 것은 더 나쁘다).
    """

    def __init__(self, app: FastAPI, limit_per_minute: int) -> None:
        super().__init__(app)
        self.limit = limit_per_minute

    def _client_key(self, request: Request) -> str:
        user_id = getattr(request.state, "user_id", None)
        if user_id:
            return f"u:{user_id}"
        # 프록시 뒤라면 X-Forwarded-For 의 첫 IP 를 쓴다.
        forwarded = request.headers.get("X-Forwarded-For", "")
        if forwarded:
            return f"ip:{forwarded.split(',')[0].strip()}"
        return f"ip:{request.client.host if request.client else 'unknown'}"

    async def dispatch(self, request: Request, call_next: NextCall) -> Response:
        if not settings.rate_limit_enabled or request.url.path in _QUIET_PATHS:
            return await call_next(request)

        client = get_redis()
        if client is None:
            return await call_next(request)

        window = int(time.time() // 60)
        key = f"hearo:rl:{self._client_key(request)}:{window}"

        try:
            pipe = client.pipeline()
            pipe.incr(key)
            pipe.expire(key, 70)  # 창 길이보다 살짝 길게
            count = int((await pipe.execute())[0])
        except RedisError:
            return await call_next(request)

        if count > self.limit:
            retry_after = 60 - int(time.time() % 60)
            log.warning("rate_limited", key=key, count=count, limit=self.limit)
            return JSONResponse(
                status_code=429,
                headers={
                    "Retry-After": str(retry_after),
                    "X-RateLimit-Limit": str(self.limit),
                    "X-RateLimit-Remaining": "0",
                },
                content={
                    "error": {
                        "code": "RATE_LIMITED",
                        "message": "요청이 너무 잦습니다. 잠시 후 다시 시도해 주세요.",
                    }
                },
            )

        response = await call_next(request)
        response.headers["X-RateLimit-Limit"] = str(self.limit)
        response.headers["X-RateLimit-Remaining"] = str(max(0, self.limit - count))
        return response


def register_middleware(app: FastAPI) -> None:
    """미들웨어 등록. Starlette 는 나중에 add 한 것이 바깥에 감싸이므로
    순서가 중요하다 — 여기서는 아래에서 위로 실행된다."""

    if settings.rate_limit_enabled:
        app.add_middleware(RateLimitMiddleware, limit_per_minute=settings.rate_limit_per_minute)

    app.add_middleware(SecurityHeadersMiddleware)
    app.add_middleware(GZipMiddleware, minimum_size=1024)

    if settings.cors_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=settings.cors_origins,
            allow_credentials=True,
            allow_methods=["GET", "POST", "PATCH", "PUT", "DELETE", "OPTIONS"],
            allow_headers=["Authorization", "Content-Type", "X-Request-ID"],
            expose_headers=["X-Request-ID", "X-Response-Time-ms"],
            max_age=600,
        )

    if settings.allowed_hosts and settings.allowed_hosts != ["*"]:
        app.add_middleware(TrustedHostMiddleware, allowed_hosts=settings.allowed_hosts)

    # 가장 바깥: 모든 요청에 request_id 가 붙어야 하므로 마지막에 추가.
    app.add_middleware(RequestContextMiddleware)
