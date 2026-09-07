"""테스트 공용 픽스처.

DB 를 쓰는 테스트는 실제 PostgreSQL 이 필요하다. SQLite 로 대체하지 않는 이유:
스키마가 pg_trgm 인덱스, 네이티브 ENUM, PGUUID, 부분 인덱스를 쓰기 때문에
SQLite 에서 통과한 테스트는 운영 동작을 전혀 보장하지 못한다.

  make up          # docker compose 로 db 기동
  make test-backend

DB 가 없으면 DB 의존 테스트만 skip 되고, 순수 로직 테스트는 그대로 돈다.
"""

from __future__ import annotations

import asyncio
import os
import uuid
from collections.abc import AsyncGenerator

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

# 앱 설정을 import 하기 전에 테스트 환경을 강제한다.
os.environ.setdefault("ENVIRONMENT", "local")
os.environ.setdefault("DEBUG", "true")
os.environ.setdefault("JWT_SECRET_KEY", "test-secret-key-that-is-long-enough-000000")
os.environ.setdefault("RATE_LIMIT_ENABLED", "false")
os.environ.setdefault("OPENAI_API_KEY", "")
# 감정 분류 제공자 키. 빈 값으로 못 박아 두지 않으면 `.env` 의 실제 키가
# 딸려 들어와 테스트가 진짜 API 를 때린다.
os.environ.setdefault("EMOTION_API_KEY", "")

TEST_DATABASE_URL = os.environ.get(
    "TEST_DATABASE_URL",
    "postgresql+asyncpg://hearo:hearo@localhost:5432/hearo_test",
)


def _redacted(dsn: str) -> str:
    """DSN 에서 비밀번호를 지운다 — skip 사유는 CI 로그에 그대로 찍힌다."""
    scheme, _, rest = dsn.partition("://")
    credentials, at, host = rest.rpartition("@")
    if not at:
        return dsn
    user, _, _ = credentials.partition(":")
    return f"{scheme}://{user}:***@{host}"


def _database_available() -> bool:
    async def probe() -> bool:
        engine = create_async_engine(TEST_DATABASE_URL, pool_pre_ping=True)
        try:
            async with engine.connect():
                return True
        except Exception:  # noqa: BLE001 — DB 가용성 탐지, 실패 원인은 무관
            return False
        finally:
            await engine.dispose()

    try:
        return asyncio.run(probe())
    except Exception:  # noqa: BLE001 — DB 가용성 탐지, 실패 원인은 무관
        return False


DB_AVAILABLE = _database_available()

requires_db = pytest.mark.skipif(
    not DB_AVAILABLE,
    reason=(
        f"테스트용 PostgreSQL 에 접속할 수 없습니다 ({_redacted(TEST_DATABASE_URL)}). "
        "'make up' 으로 DB 를 띄우고 hearo_test 데이터베이스를 만들어 주세요."
    ),
)


@pytest.fixture(scope="session")
def anyio_backend() -> str:
    return "asyncio"


@pytest.fixture(scope="session")
async def engine() -> AsyncGenerator:
    if not DB_AVAILABLE:
        pytest.skip("database unavailable")

    os.environ["DATABASE_URL"] = TEST_DATABASE_URL
    from app.db import models  # noqa: F401 — 모델 등록
    from app.db.base import Base

    engine = create_async_engine(TEST_DATABASE_URL, poolclass=None)

    from sqlalchemy import text

    async with engine.begin() as conn:
        await conn.execute(text("CREATE EXTENSION IF NOT EXISTS pg_trgm"))
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)

    yield engine

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
    await engine.dispose()


@pytest.fixture
async def db(engine) -> AsyncGenerator[AsyncSession]:
    """테스트마다 트랜잭션을 열고 끝나면 롤백해 격리한다."""
    connection = await engine.connect()
    transaction = await connection.begin()
    factory = async_sessionmaker(bind=connection, expire_on_commit=False)
    session = factory()

    try:
        yield session
    finally:
        await session.close()
        await transaction.rollback()
        await connection.close()


@pytest.fixture
async def client(db: AsyncSession) -> AsyncGenerator[AsyncClient]:
    from app.db.session import get_db
    from app.main import app

    async def override_get_db() -> AsyncGenerator[AsyncSession]:
        yield db

    app.dependency_overrides[get_db] = override_get_db

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as http:
        yield http

    app.dependency_overrides.clear()


@pytest.fixture
def unique_email() -> str:
    return f"user-{uuid.uuid4().hex[:12]}@example.com"


@pytest.fixture
async def registered_user(client: AsyncClient, unique_email: str) -> dict[str, str]:
    """가입 + 로그인된 사용자. access_token 포함."""
    response = await client.post(
        "/api/v1/auth/register",
        json={
            "email": unique_email,
            "password": "correct-horse-battery",
            "display_name": "테스트 사용자",
        },
    )
    assert response.status_code == 201, response.text
    body = response.json()
    return {
        "id": body["user"]["id"],
        "email": unique_email,
        "access_token": body["tokens"]["access_token"],
        "refresh_token": body["tokens"]["refresh_token"],
    }


@pytest.fixture
def auth_headers(registered_user: dict[str, str]) -> dict[str, str]:
    return {"Authorization": f"Bearer {registered_user['access_token']}"}
