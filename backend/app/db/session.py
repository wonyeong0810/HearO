"""비동기 엔진/세션 팩토리."""

from __future__ import annotations

from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from app.core.config import settings
from app.core.logging import get_logger

log = get_logger(__name__)

_engine: AsyncEngine | None = None
_session_factory: async_sessionmaker[AsyncSession] | None = None


def _build_engine() -> AsyncEngine:
    # SQLite(테스트) 는 풀 옵션을 받지 않는다.
    is_sqlite = settings.database_url.startswith("sqlite")
    kwargs: dict[str, object] = {
        "echo": settings.db_echo,
        "future": True,
        "pool_pre_ping": True,
    }
    if not is_sqlite:
        kwargs.update(
            pool_size=settings.db_pool_size,
            max_overflow=settings.db_max_overflow,
            pool_recycle=settings.db_pool_recycle_seconds,
            # 서버가 준비되기 전에 붙는 경우를 대비
            connect_args={"server_settings": {"application_name": "hearo-api"}},
        )
    return create_async_engine(settings.database_url, **kwargs)  # type: ignore[arg-type]


def get_engine() -> AsyncEngine:
    global _engine
    if _engine is None:
        _engine = _build_engine()
    return _engine


def get_session_factory() -> async_sessionmaker[AsyncSession]:
    global _session_factory
    if _session_factory is None:
        _session_factory = async_sessionmaker(
            bind=get_engine(),
            class_=AsyncSession,
            expire_on_commit=False,  # 커밋 후에도 객체 속성 접근이 가능해야 함
            autoflush=False,
        )
    return _session_factory


async def get_db() -> AsyncGenerator[AsyncSession]:
    """FastAPI 의존성. 예외 시 롤백, 항상 close."""
    factory = get_session_factory()
    async with factory() as session:
        try:
            yield session
        except Exception:
            await session.rollback()
            raise


@asynccontextmanager
async def session_scope() -> AsyncGenerator[AsyncSession]:
    """워커/백그라운드 태스크용. 정상 종료 시 커밋한다."""
    factory = get_session_factory()
    async with factory() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise


async def dispose_engine() -> None:
    global _engine, _session_factory
    if _engine is not None:
        await _engine.dispose()
        _engine = None
        _session_factory = None
        log.info("db_engine_disposed")
