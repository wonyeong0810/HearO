# syntax=docker/dockerfile:1.7

# ----------------------------------------------------------------- builder
FROM python:3.12-slim AS builder

COPY --from=ghcr.io/astral-sh/uv:0.5.11 /uv /usr/local/bin/uv

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never

WORKDIR /srv

# 의존성 레이어를 소스와 분리해 캐시 적중률을 높인다.
COPY pyproject.toml ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv venv /srv/.venv && \
    uv pip install --python /srv/.venv/bin/python -r pyproject.toml

# ----------------------------------------------------------------- runtime
FROM python:3.12-slim AS runtime

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/srv/.venv/bin:$PATH"

# 비루트 실행
RUN groupadd --system --gid 1001 hearo && \
    useradd --system --uid 1001 --gid hearo --create-home hearo

WORKDIR /srv

COPY --from=builder --chown=hearo:hearo /srv/.venv /srv/.venv
COPY --chown=hearo:hearo alembic.ini ./
COPY --chown=hearo:hearo alembic ./alembic
COPY --chown=hearo:hearo app ./app
COPY --chown=hearo:hearo entrypoint.sh ./
RUN chmod +x entrypoint.sh

USER hearo
EXPOSE 8000

ENTRYPOINT ["./entrypoint.sh"]
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2", "--proxy-headers", "--forwarded-allow-ips", "*"]
