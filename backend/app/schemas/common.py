"""공용 스키마."""

from __future__ import annotations

from typing import Annotated, Generic, TypeVar

from pydantic import BaseModel, ConfigDict, Field

T = TypeVar("T")


class APIModel(BaseModel):
    """모든 응답/요청 모델의 베이스."""

    model_config = ConfigDict(
        from_attributes=True,
        populate_by_name=True,
        str_strip_whitespace=True,
        # 알 수 없는 필드는 조용히 무시하지 않고 거부한다 — 오타를 빨리 잡는다.
        extra="forbid",
    )


class PageParams(BaseModel):
    """커서 없는 오프셋 페이지네이션.

    대화 기록은 시간순으로 안정적이고 목록 크기가 개인 단위라 오프셋으로 충분하다.
    """

    limit: Annotated[int, Field(default=20, ge=1, le=100)]
    offset: Annotated[int, Field(default=0, ge=0)]


# UP046: PEP 695 구문 대신 Generic[T] 를 쓴다 — pydantic 이 확실히 지원하는 형태.
class Page(APIModel, Generic[T]):  # noqa: UP046
    items: list[T]
    total: int
    limit: int
    offset: int

    @property
    def has_more(self) -> bool:
        return self.offset + len(self.items) < self.total


class MessageResponse(APIModel):
    message: str


class ErrorDetail(APIModel):
    code: str
    message: str
    details: dict[str, object] | None = None


class ErrorResponse(APIModel):
    error: ErrorDetail


class HealthResponse(APIModel):
    status: str
    version: str
    environment: str
    checks: dict[str, str] | None = None
