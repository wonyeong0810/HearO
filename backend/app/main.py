"""FastAPI 애플리케이션 진입점."""

from __future__ import annotations

from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.openapi.utils import get_openapi

from app.api.health import VERSION
from app.api.health import router as health_router
from app.api.v1.router import api_router
from app.core.config import settings
from app.core.errors import register_exception_handlers
from app.core.logging import configure_logging, get_logger
from app.core.middleware import register_middleware
from app.core.redis_client import close_redis, init_redis
from app.db.session import dispose_engine
from app.services.emotion.classifier import EmotionClassifier
from app.services.stt.diarize_client import DiarizeClient

configure_logging()
log = get_logger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None]:
    log.info(
        "starting",
        version=VERSION,
        environment=settings.environment,
        openai_configured=settings.openai_configured,
        emotion_configured=settings.emotion_configured,
        emotion_model=settings.emotion_model,
    )

    if not settings.openai_configured:
        # 부팅은 시키되 크게 경고한다 — 실시간 자막이 동작하지 않는다.
        log.warning(
            "openai_api_key_missing",
            hint=".env 의 OPENAI_API_KEY 를 채워야 실시간 자막이 동작합니다.",
        )

    if not settings.emotion_configured:
        # 자막은 정상으로 보이는데 감정만 운율 추정으로 떨어진다. 화면상
        # 표시가 사라지지 않아 눈으로는 구분되지 않으므로 로그로 남긴다.
        log.warning(
            "emotion_api_key_missing",
            hint=".env 의 EMOTION_API_KEY 를 채워야 감정 분류가 동작합니다. "
            "지금은 운율(음량·피치·속도) 추정만 쓰며, '화남'은 판정되지 않습니다.",
        )

    await init_redis()

    # OpenAI 클라이언트는 커넥션 풀을 재사용해야 하므로 앱 수명주기 동안 공유한다.
    app.state.diarize_client = DiarizeClient()
    await app.state.diarize_client.start()

    app.state.emotion_classifier = EmotionClassifier()
    await app.state.emotion_classifier.start()

    if settings.sentry_dsn:
        _init_sentry()

    log.info("started")
    try:
        yield
    finally:
        log.info("shutting_down")
        await app.state.emotion_classifier.aclose()
        await app.state.diarize_client.aclose()
        await close_redis()
        await dispose_engine()
        log.info("shutdown_complete")


def _init_sentry() -> None:
    try:
        import sentry_sdk
    except ImportError:
        log.warning("sentry_dsn_set_but_sdk_missing", hint="pip install 'hearo-backend[sentry]'")
        return

    sentry_sdk.init(
        dsn=settings.sentry_dsn,
        environment=settings.environment,
        release=VERSION,
        traces_sample_rate=0.1 if settings.is_production else 1.0,
        # 대화 내용이 에러 리포트로 새어나가면 안 된다.
        send_default_pii=False,
        max_request_body_size="never",
    )
    log.info("sentry_initialized")


def create_app() -> FastAPI:
    app = FastAPI(
        title="HearO API",
        version=VERSION,
        description=(
            "감정이 담긴 실시간 자막으로 청각장애인의 일상 소통을 돕는 보조 앱의 백엔드.\n\n"
            "**실시간 자막 흐름**\n"
            "1. `POST /api/v1/sessions` 로 세션 생성\n"
            "2. `POST /api/v1/auth/ws-ticket` 으로 1회용 티켓 발급\n"
            "3. `WS /api/v1/live/{session_id}/ws?ticket=...` 접속 후 PCM16(24kHz mono) 전송\n"
            "4. 자막·화자·감정 이벤트를 JSON 으로 수신"
        ),
        lifespan=lifespan,
        # 운영에서는 문서를 닫는다.
        docs_url=None if settings.is_production else "/docs",
        redoc_url=None if settings.is_production else "/redoc",
        openapi_url=None if settings.is_production else "/openapi.json",
    )

    register_middleware(app)
    register_exception_handlers(app)

    app.include_router(health_router)
    app.include_router(api_router, prefix=settings.api_v1_prefix)

    app.openapi = _custom_openapi(app)  # type: ignore[method-assign]
    return app


def _custom_openapi(app: FastAPI):  # type: ignore[no-untyped-def]
    def openapi() -> dict[str, object]:
        if app.openapi_schema:
            return app.openapi_schema

        schema = get_openapi(
            title=app.title,
            version=app.version,
            description=app.description,
            routes=app.routes,
        )
        schema["components"] = schema.get("components", {})
        schema["components"]["securitySchemes"] = {
            "BearerAuth": {
                "type": "http",
                "scheme": "bearer",
                "bearerFormat": "JWT",
            }
        }
        schema["security"] = [{"BearerAuth": []}]
        app.openapi_schema = schema
        return schema

    return openapi


app = create_app()


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "app.main:app",
        host=settings.api_host,
        port=settings.api_port,
        reload=not settings.is_production,
        log_config=None,  # 우리 structlog 설정을 쓴다
    )
