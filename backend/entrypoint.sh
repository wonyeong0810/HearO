#!/usr/bin/env sh
set -eu

# API 컨테이너만 마이그레이션을 적용한다. 워커는 건너뛴다.
# (동시에 두 컨테이너가 alembic 을 돌리면 락 경합이 발생)
case "${1:-}" in
  uvicorn)
    echo "[entrypoint] applying database migrations..."
    alembic upgrade head
    echo "[entrypoint] migrations applied."
    ;;
  *)
    echo "[entrypoint] non-api process; skipping migrations."
    ;;
esac

exec "$@"
