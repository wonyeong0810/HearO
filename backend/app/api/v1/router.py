"""v1 라우터 집합."""

from __future__ import annotations

from fastapi import APIRouter

from app.api.v1 import alerts, auth, live, sessions, settings

api_router = APIRouter()
api_router.include_router(auth.router)
api_router.include_router(sessions.router)
api_router.include_router(alerts.router)
api_router.include_router(settings.router)
api_router.include_router(live.router)
