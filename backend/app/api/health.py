"""헬스체크.

live  — 프로세스가 살아있는가 (k8s livenessProbe). 의존성을 보지 않는다.
ready — 트래픽을 받을 수 있는가 (readinessProbe). DB/Redis 를 확인한다.

이 둘을 나누지 않으면 DB 가 잠깐 흔들릴 때 오케스트레이터가 멀쩡한 프로세스를
재시작해 장애를 키운다.
"""

from __future__ import annotations

import asyncio

from fastapi import APIRouter, Response, status
from sqlalchemy import text

from app.core.config import settings
from app.core.logging import get_logger
from app.core.redis_client import redis_healthy
from app.db.session import get_session_factory
from app.schemas.common import HealthResponse

router = APIRouter(tags=["헬스체크"])
log = get_logger(__name__)

VERSION = "1.0.0"
_CHECK_TIMEOUT = 3.0


async def _check_database() -> str:
    try:
        factory = get_session_factory()
        async with factory() as session:
            await asyncio.wait_for(session.execute(text("SELECT 1")), timeout=_CHECK_TIMEOUT)
        return "ok"
    except TimeoutError:
        return "timeout"
    except Exception as exc:  # noqa: BLE001
        log.warning("health_db_failed", error=str(exc))
        return "error"


async def _check_redis() -> str:
    try:
        return "ok" if await asyncio.wait_for(redis_healthy(), timeout=_CHECK_TIMEOUT) else "down"
    except TimeoutError:
        return "timeout"
    except Exception:  # noqa: BLE001
        return "error"


@router.get("/health/live", response_model=HealthResponse, summary="Liveness")
async def liveness() -> HealthResponse:
    return HealthResponse(status="ok", version=VERSION, environment=settings.environment)


@router.get("/health/ready", response_model=HealthResponse, summary="Readiness")
async def readiness(response: Response) -> HealthResponse:
    database, redis = await asyncio.gather(_check_database(), _check_redis())

    checks = {
        "database": database,
        "redis": redis,
        "openai": "configured" if settings.openai_configured else "missing_api_key",
        "emotion": "configured" if settings.emotion_configured else "missing_api_key",
    }

    # DB 가 죽으면 트래픽을 받을 수 없다. Redis 는 degrade 로 버틴다.
    healthy = database == "ok"
    if not healthy:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE

    return HealthResponse(
        status="ok" if healthy else "degraded",
        version=VERSION,
        environment=settings.environment,
        checks=checks,
    )
