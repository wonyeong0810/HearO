"""Redis 연결 관리와, Redis 없이도 서비스가 죽지 않게 하는 폴백.

Redis 는 부가 기능(레이트리밋, 토큰 폐기, 동시 세션 수)에만 쓰이므로
장애 시에는 기능을 degrade 하되 요청 자체는 통과시킨다. 단, 토큰 폐기목록만은
보안에 직결되므로 "확인 불가"를 "폐기됨"으로 취급하지 않고 로그를 남긴다.
"""

from __future__ import annotations

from typing import Any

import redis.asyncio as aioredis
from redis.asyncio import Redis
from redis.exceptions import RedisError

from app.core.config import settings
from app.core.logging import get_logger

log = get_logger(__name__)

_client: Redis | None = None


async def init_redis() -> None:
    global _client
    _client = aioredis.from_url(
        str(settings.redis_url),
        encoding="utf-8",
        decode_responses=True,
        socket_connect_timeout=3,
        socket_timeout=3,
        health_check_interval=30,
        retry_on_timeout=True,
        max_connections=50,
    )
    try:
        await _client.ping()
        log.info("redis_connected", url=str(settings.redis_url))
    except RedisError as exc:
        log.error("redis_unavailable_at_startup", error=str(exc))


async def close_redis() -> None:
    global _client
    if _client is not None:
        await _client.aclose()
        _client = None


def get_redis() -> Redis | None:
    return _client


async def redis_healthy() -> bool:
    if _client is None:
        return False
    try:
        return bool(await _client.ping())
    except RedisError:
        return False


# --------------------------------------------------------------- token denylist

_DENY_PREFIX = "hearo:denylist:jti:"


async def revoke_jti(jti: str, ttl_seconds: int) -> None:
    """리프레시 토큰 폐기. TTL 은 토큰 만료까지의 잔여 시간으로 준다."""
    if _client is None or ttl_seconds <= 0:
        return
    try:
        await _client.setex(f"{_DENY_PREFIX}{jti}", ttl_seconds, "1")
    except RedisError as exc:
        # 폐기 실패는 보안 이슈이므로 크게 남긴다.
        log.error("token_revocation_failed", jti=jti, error=str(exc))


async def is_jti_revoked(jti: str) -> bool:
    if _client is None:
        return False
    try:
        return await _client.exists(f"{_DENY_PREFIX}{jti}") == 1
    except RedisError as exc:
        log.warning("denylist_check_failed_fail_open", jti=jti, error=str(exc))
        return False


async def revoke_all_for_user(user_id: str, epoch: int) -> None:
    """전체 로그아웃: 이 시각 이전 발급분을 모두 무효화한다."""
    if _client is None:
        return
    try:
        await _client.set(f"hearo:token_epoch:{user_id}", epoch)
    except RedisError as exc:
        log.error("global_revocation_failed", user_id=user_id, error=str(exc))


async def get_token_epoch(user_id: str) -> int:
    if _client is None:
        return 0
    try:
        value = await _client.get(f"hearo:token_epoch:{user_id}")
        return int(value) if value else 0
    except (RedisError, ValueError):
        return 0


# --------------------------------------------------------- live session counter

_LIVE_PREFIX = "hearo:live:"


async def acquire_live_slot(user_id: str, session_id: str, ttl_seconds: int) -> int:
    """라이브 세션 슬롯 점유. 현재 점유 개수를 반환한다."""
    if _client is None:
        return 1
    key = f"{_LIVE_PREFIX}{user_id}"
    try:
        pipe = _client.pipeline()
        pipe.sadd(key, session_id)
        pipe.expire(key, ttl_seconds)
        pipe.scard(key)
        result: list[Any] = await pipe.execute()
        return int(result[-1])
    except RedisError as exc:
        log.warning("live_slot_acquire_failed", error=str(exc))
        return 1


async def release_live_slot(user_id: str, session_id: str) -> None:
    if _client is None:
        return
    try:
        await _client.srem(f"{_LIVE_PREFIX}{user_id}", session_id)
    except RedisError as exc:
        log.warning("live_slot_release_failed", error=str(exc))


async def count_live_slots(user_id: str) -> int:
    if _client is None:
        return 0
    try:
        return int(await _client.scard(f"{_LIVE_PREFIX}{user_id}"))
    except RedisError:
        return 0
