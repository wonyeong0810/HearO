"""보관 주기 자동 삭제 워커 (기획 3-2 '오래된 로그 자동 삭제 옵션').

주기적으로 돌면서 사용자별 보관 설정에 따라 지난 기록을 지운다.
즐겨찾기한 대화와 미확인 경보는 지우지 않는다 — 사용자가 명시적으로 중요하다고
표시한 것을 자동 삭제하면 신뢰를 잃는다.

버려진(ABANDONED) 세션 정리도 함께 한다: 앱이 강제종료되어 종료 신호를 못 받은
세션이 영원히 ACTIVE 로 남으면 동시 세션 제한에 걸려 새 자막을 못 켜게 된다.
"""

from __future__ import annotations

import asyncio
import contextlib
import signal
from datetime import UTC, datetime

from app.core.config import settings
from app.core.logging import configure_logging, get_logger
from app.db.session import dispose_engine, session_scope
from app.services.repositories.alert_repo import AlertRepository
from app.services.repositories.session_repo import SessionRepository
from app.services.repositories.user_repo import SettingsRepository

log = get_logger(__name__)

# 이 시간 넘게 ACTIVE 로 남은 세션은 버려진 것으로 본다.
_ABANDONED_AFTER_SECONDS = 6 * 60 * 60
# 한 번의 스윕에서 처리할 사용자 수 상한. DB 를 오래 붙들지 않기 위함.
_MAX_USERS_PER_SWEEP = 500


async def sweep_once() -> dict[str, int]:
    """한 사이클. 삭제된 항목 수를 돌려준다."""
    started = datetime.now(UTC)
    deleted_sessions = 0
    deleted_alerts = 0
    users_processed = 0

    # 1) 버려진 세션 정리
    async with session_scope() as db:
        abandoned = await SessionRepository(db).sweep_abandoned(_ABANDONED_AFTER_SECONDS)
    if abandoned:
        log.info("abandoned_sessions_marked", count=abandoned)

    # 2) 사용자별 보관 주기 적용
    async with session_scope() as db:
        targets = await SettingsRepository(db).users_with_expired_logs()

    for user_id, retention_days in targets[:_MAX_USERS_PER_SWEEP]:
        try:
            async with session_scope() as db:
                sessions = await SessionRepository(db).delete_expired(user_id, retention_days)
                alerts = await AlertRepository(db).delete_expired(user_id, retention_days)
        except Exception as exc:  # noqa: BLE001 — 한 사용자 실패가 전체를 막지 않는다
            log.error("retention_user_failed", user_id=str(user_id), error=str(exc))
            continue

        deleted_sessions += sessions
        deleted_alerts += alerts
        users_processed += 1

        if sessions or alerts:
            log.info(
                "retention_applied",
                user_id=str(user_id),
                retention_days=retention_days,
                sessions=sessions,
                alerts=alerts,
            )

        # DB 에 여유를 준다 — 이 작업은 급하지 않다.
        await asyncio.sleep(0)

    elapsed = (datetime.now(UTC) - started).total_seconds()
    result = {
        "users_processed": users_processed,
        "sessions_deleted": deleted_sessions,
        "alerts_deleted": deleted_alerts,
        "abandoned_marked": abandoned,
    }
    log.info("retention_sweep_complete", **result, elapsed_seconds=round(elapsed, 2))
    return result


async def run_forever() -> None:
    stop = asyncio.Event()

    def _request_stop(*_: object) -> None:
        log.info("retention_worker_stop_requested")
        stop.set()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        with contextlib.suppress(NotImplementedError):
            loop.add_signal_handler(sig, _request_stop)

    interval = settings.retention_sweep_interval_seconds
    log.info("retention_worker_started", interval_seconds=interval)

    # 기동 직후 바로 한 번 돌리지 않고 잠시 기다린다 — 배포 직후 DB 마이그레이션과
    # 겹치는 것을 피한다.
    with contextlib.suppress(TimeoutError):
        await asyncio.wait_for(stop.wait(), timeout=30)

    while not stop.is_set():
        try:
            await sweep_once()
        except Exception as exc:
            log.exception("retention_sweep_failed", error=str(exc))

        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(stop.wait(), timeout=interval)

    await dispose_engine()
    log.info("retention_worker_stopped")


def main() -> None:
    configure_logging()
    asyncio.run(run_forever())


if __name__ == "__main__":
    main()
