"""structlog 기반 로깅 설정.

운영에서는 JSON 한 줄 로그, 로컬에서는 사람이 읽는 컬러 로그.
요청마다 request_id 를 contextvar 에 심어 모든 로그에 자동으로 붙인다.
"""

from __future__ import annotations

import logging
import sys
from collections.abc import Callable
from typing import Any

import structlog
from structlog.contextvars import bind_contextvars, clear_contextvars, merge_contextvars

from app.core.config import settings

# 민감정보가 로그로 새는 것을 막는다.
_REDACT_KEYS = frozenset(
    {
        "password",
        "authorization",
        "token",
        "access_token",
        "refresh_token",
        "api_key",
        "openai_api_key",
        "jwt_secret_key",
        "secret",
        "audio",
        "audio_b64",
        "pcm",
    }
)
_REDACTED = "***redacted***"


def _redact(
    _logger: Any, _name: str, event_dict: structlog.types.EventDict
) -> structlog.types.EventDict:
    for key in list(event_dict):
        if key.lower() in _REDACT_KEYS:
            event_dict[key] = _REDACTED
    return event_dict


def _drop_color_message(
    _logger: Any, _name: str, event_dict: structlog.types.EventDict
) -> structlog.types.EventDict:
    # uvicorn 이 넣는 중복 필드 제거
    event_dict.pop("color_message", None)
    return event_dict


def configure_logging() -> None:
    shared: list[Callable[..., Any]] = [
        merge_contextvars,
        structlog.stdlib.add_log_level,
        structlog.stdlib.add_logger_name,
        structlog.processors.TimeStamper(fmt="iso", utc=True),
        structlog.processors.StackInfoRenderer(),
        structlog.processors.UnicodeDecoder(),
        _drop_color_message,
        _redact,
    ]

    renderer: Any
    if settings.log_json:
        shared.append(structlog.processors.format_exc_info)
        renderer = structlog.processors.JSONRenderer(ensure_ascii=False)
    else:
        renderer = structlog.dev.ConsoleRenderer(colors=sys.stderr.isatty())

    structlog.configure(
        processors=[*shared, structlog.stdlib.ProcessorFormatter.wrap_for_formatter],
        logger_factory=structlog.stdlib.LoggerFactory(),
        wrapper_class=structlog.stdlib.BoundLogger,
        cache_logger_on_first_use=True,
    )

    formatter = structlog.stdlib.ProcessorFormatter(
        foreign_pre_chain=shared,
        processors=[structlog.stdlib.ProcessorFormatter.remove_processors_meta, renderer],
    )

    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(formatter)

    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(settings.log_level)

    # uvicorn/sqlalchemy 로거를 우리 포매터로 통일
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access", "sqlalchemy.engine"):
        lg = logging.getLogger(name)
        lg.handlers.clear()
        lg.propagate = True

    logging.getLogger("uvicorn.access").setLevel(
        logging.WARNING if settings.is_production else logging.INFO
    )
    # 우리 미들웨어가 접근 로그를 이미 남기므로 httpx 는 조용히
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("websockets.client").setLevel(logging.WARNING)


def get_logger(name: str | None = None) -> structlog.stdlib.BoundLogger:
    return structlog.stdlib.get_logger(name)  # type: ignore[no-any-return]


__all__ = [
    "bind_contextvars",
    "clear_contextvars",
    "configure_logging",
    "get_logger",
]
