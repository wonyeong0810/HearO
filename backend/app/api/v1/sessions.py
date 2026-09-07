"""대화 세션 / 자막 기록 엔드포인트 (기획 3. 텍스트 저장 기능)."""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Query, status

from app.api.deps import (
    CurrentUser,
    DbSession,
    SessionRepo,
    SpeakerRepo,
    UtteranceRepo,
)
from app.core.logging import get_logger
from app.db.models import ConversationSession, EmotionTone, Speaker, Utterance
from app.schemas.common import MessageResponse, Page
from app.schemas.transcript import (
    SessionCreate,
    SessionDetailResponse,
    SessionImport,
    SessionSearchParams,
    SessionSummaryResponse,
    SessionUpdate,
    SpeakerResponse,
    SpeakerUpdate,
    UtteranceResponse,
    UtteranceSearchResult,
    UtteranceUpdate,
)

router = APIRouter(prefix="/sessions", tags=["대화 기록"])
log = get_logger(__name__)


# --------------------------------------------------------------------- mappers


def _utterance_response(utterance: Utterance) -> UtteranceResponse:
    speaker = utterance.speaker
    return UtteranceResponse(
        id=utterance.id,
        sequence=utterance.sequence,
        text=utterance.text,
        start_ms=utterance.start_ms,
        end_ms=utterance.end_ms,
        tone=utterance.tone,
        tone_confidence=utterance.tone_confidence,
        tone_basis=utterance.tone_basis,
        intensity=utterance.intensity,
        loudness_dbfs=utterance.loudness_dbfs,
        pitch_hz=utterance.pitch_hz,
        speech_rate=utterance.speech_rate,
        speaker_id=utterance.speaker_id,
        speaker_label=speaker.label if speaker else None,
        speaker_color=speaker.color_hex if speaker else None,
        speaker_name=speaker.display_name if speaker else None,
        is_final=utterance.is_final,
        speaker_resolved=utterance.speaker_resolved,
        is_bookmarked=utterance.is_bookmarked,
    )


def _detail_response(record: ConversationSession) -> SessionDetailResponse:
    return SessionDetailResponse(
        id=record.id,
        title=record.title,
        status=record.status,
        started_at=record.started_at,
        ended_at=record.ended_at,
        duration_seconds=record.duration_seconds,
        location_label=record.location_label,
        latitude=record.latitude,
        longitude=record.longitude,
        is_favorite=record.is_favorite,
        utterance_count=record.utterance_count,
        speaker_count=record.speaker_count,
        preview_text=record.preview_text,
        dominant_tone=record.dominant_tone,
        speakers=[SpeakerResponse.model_validate(s) for s in record.speakers],
        utterances=[_utterance_response(u) for u in record.utterances],
    )


# --------------------------------------------------------------------- CRUD


@router.post(
    "",
    response_model=SessionSummaryResponse,
    status_code=status.HTTP_201_CREATED,
    summary="대화 세션 생성",
    description="라이브 자막을 시작하기 전에 호출합니다. 반환된 id 로 WebSocket 에 접속합니다.",
)
async def create_session(
    payload: SessionCreate,
    user: CurrentUser,
    db: DbSession,
    sessions: SessionRepo,
) -> SessionSummaryResponse:
    record = await sessions.create(
        user_id=user.id,
        title=payload.title,
        location_label=payload.location_label,
        latitude=payload.latitude,
        longitude=payload.longitude,
    )
    await db.commit()
    await db.refresh(record)
    return SessionSummaryResponse.model_validate(record)


@router.get(
    "",
    response_model=Page[SessionSummaryResponse],
    summary="대화 기록 목록 · 검색",
    description=(
        "날짜·위치·화자·즐겨찾기·감정으로 필터링하고 자유 텍스트로 검색합니다. "
        "본문은 포함되지 않습니다 (상세 조회를 사용하세요)."
    ),
)
async def list_sessions(
    user: CurrentUser,
    sessions: SessionRepo,
    params: Annotated[SessionSearchParams, Depends()],
) -> Page[SessionSummaryResponse]:
    records, total = await sessions.search(user.id, params)
    return Page[SessionSummaryResponse](
        items=[SessionSummaryResponse.model_validate(r) for r in records],
        total=total,
        limit=params.limit,
        offset=params.offset,
    )


@router.get(
    "/search/utterances",
    response_model=Page[UtteranceSearchResult],
    summary="자막 본문 전체 검색",
    description="모든 대화의 자막에서 검색해 어느 대화의 몇 번째 줄인지까지 알려줍니다.",
)
async def search_utterances(
    user: CurrentUser,
    sessions: SessionRepo,
    q: Annotated[str, Query(min_length=1, max_length=200, description="검색어")],
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> Page[UtteranceSearchResult]:
    rows, total = await sessions.search_utterances(user.id, q.strip(), limit=limit, offset=offset)
    items = [
        UtteranceSearchResult(
            session_id=session.id,
            session_title=session.title,
            session_started_at=session.started_at,
            utterance_id=utterance.id,
            sequence=utterance.sequence,
            text=utterance.text,
            start_ms=utterance.start_ms,
            tone=utterance.tone,
            speaker_label=speaker.label if speaker else None,
            speaker_name=speaker.display_name if speaker else None,
            speaker_color=speaker.color_hex if speaker else None,
        )
        for utterance, session, speaker in rows
    ]
    return Page[UtteranceSearchResult](items=items, total=total, limit=limit, offset=offset)


@router.get(
    "/bookmarks",
    response_model=Page[UtteranceSearchResult],
    summary="즐겨찾기한 자막 모아보기",
)
async def list_bookmarks(
    user: CurrentUser,
    utterances: UtteranceRepo,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> Page[UtteranceSearchResult]:
    rows, total = await utterances.bookmarked(user.id, limit=limit, offset=offset)
    items = [
        UtteranceSearchResult(
            session_id=session.id,
            session_title=session.title,
            session_started_at=session.started_at,
            utterance_id=utterance.id,
            sequence=utterance.sequence,
            text=utterance.text,
            start_ms=utterance.start_ms,
            tone=utterance.tone,
            speaker_label=None,
            speaker_name=None,
            speaker_color=None,
        )
        for utterance, session in rows
    ]
    return Page[UtteranceSearchResult](items=items, total=total, limit=limit, offset=offset)


@router.get(
    "/{session_id}",
    response_model=SessionDetailResponse,
    summary="대화 상세 조회",
)
async def get_session(
    session_id: uuid.UUID,
    user: CurrentUser,
    sessions: SessionRepo,
) -> SessionDetailResponse:
    record = await sessions.get(session_id, user.id, with_details=True)
    return _detail_response(record)


@router.patch(
    "/{session_id}",
    response_model=SessionSummaryResponse,
    summary="대화 정보 수정 (제목 · 즐겨찾기 · 위치)",
)
async def update_session(
    session_id: uuid.UUID,
    payload: SessionUpdate,
    user: CurrentUser,
    db: DbSession,
    sessions: SessionRepo,
) -> SessionSummaryResponse:
    record = await sessions.update(session_id, user.id, payload.model_dump(exclude_none=True))
    await db.commit()
    await db.refresh(record)
    return SessionSummaryResponse.model_validate(record)


@router.delete(
    "/{session_id}",
    response_model=MessageResponse,
    summary="대화 삭제",
)
async def delete_session(
    session_id: uuid.UUID,
    user: CurrentUser,
    db: DbSession,
    sessions: SessionRepo,
) -> MessageResponse:
    await sessions.delete(session_id, user.id)
    await db.commit()
    log.info("session_deleted", session_id=str(session_id), user_id=str(user.id))
    return MessageResponse(message="대화 기록이 삭제되었습니다.")


@router.post(
    "/bulk-delete",
    response_model=MessageResponse,
    summary="대화 여러 건 삭제",
)
async def bulk_delete(
    session_ids: Annotated[list[uuid.UUID], Query(alias="ids", max_length=200)],
    user: CurrentUser,
    db: DbSession,
    sessions: SessionRepo,
) -> MessageResponse:
    deleted = await sessions.delete_many(session_ids, user.id)
    await db.commit()
    log.info("sessions_bulk_deleted", count=deleted, user_id=str(user.id))
    return MessageResponse(message=f"{deleted}건의 대화 기록이 삭제되었습니다.")


# --------------------------------------------------------------------- 화자


@router.patch(
    "/{session_id}/speakers/{speaker_id}",
    response_model=SpeakerResponse,
    summary="화자 이름 · 색상 변경",
    description="기획 1-2 의 '유저가 직접 색상 지정' 기능입니다.",
)
async def update_speaker(
    session_id: uuid.UUID,
    speaker_id: uuid.UUID,
    payload: SpeakerUpdate,
    user: CurrentUser,
    db: DbSession,
    sessions: SessionRepo,
    speakers: SpeakerRepo,
) -> SpeakerResponse:
    # 세션 소유권을 먼저 확인한다.
    await sessions.get(session_id, user.id)
    record = await speakers.update(speaker_id, user.id, payload.model_dump(exclude_none=True))
    await db.commit()
    await db.refresh(record)
    return SpeakerResponse.model_validate(record)


# --------------------------------------------------------------------- 발화


@router.patch(
    "/{session_id}/utterances/{utterance_id}",
    response_model=UtteranceResponse,
    summary="자막 수정 · 즐겨찾기",
    description="오인식된 자막을 고치거나, 중요한 발화를 즐겨찾기합니다.",
)
async def update_utterance(
    session_id: uuid.UUID,
    utterance_id: uuid.UUID,
    payload: UtteranceUpdate,
    user: CurrentUser,
    db: DbSession,
    sessions: SessionRepo,
    utterances: UtteranceRepo,
) -> UtteranceResponse:
    await sessions.get(session_id, user.id)
    record = await utterances.update(utterance_id, user.id, payload.model_dump(exclude_none=True))
    await db.commit()
    await db.refresh(record, attribute_names=["speaker"])
    return _utterance_response(record)


def _speaker_or_none(speaker: Speaker | None) -> SpeakerResponse | None:
    return SpeakerResponse.model_validate(speaker) if speaker else None


@router.post(
    "/{session_id}/import",
    response_model=SessionDetailResponse,
    summary="자막을 한 번에 저장",
    description="체험 모드처럼 라이브 WS 를 거치지 않고 만든 자막을 기록에 남깁니다.",
)
async def import_session(
    session_id: uuid.UUID,
    payload: SessionImport,
    user: CurrentUser,
    db: DbSession,
    sessions: SessionRepo,
    speakers: SpeakerRepo,
    utterances: UtteranceRepo,
) -> SessionDetailResponse:
    await sessions.get(session_id, user.id)

    speaker_ids: dict[str, uuid.UUID] = {}
    for entry in payload.speakers:
        record = await speakers.upsert(
            session_id=session_id,
            label=entry.label,
            color_hex=entry.color_hex,
            display_name=entry.display_name,
        )
        speaker_ids[entry.label] = record.id

    rows = [
        {
            "id": uuid.uuid4(),
            "session_id": session_id,
            "speaker_id": speaker_ids.get(line.speaker_label or ""),
            "sequence": line.sequence,
            "text": line.text,
            "start_ms": line.start_ms,
            "end_ms": line.end_ms,
            "tone": line.tone,
            "tone_confidence": line.tone_confidence,
            "tone_basis": line.tone_basis,
            "intensity": line.intensity,
            "is_final": True,
            "speaker_resolved": line.speaker_label is not None,
        }
        for line in payload.utterances
    ]
    await utterances.upsert_many(rows)

    counts: dict[EmotionTone, int] = {}
    for line in payload.utterances:
        counts[line.tone] = counts.get(line.tone, 0) + 1
    dominant = max(counts, key=lambda key: counts[key]) if counts else None

    await sessions.finalize(
        session_id,
        utterance_count=len(payload.utterances),
        speaker_count=len(speaker_ids),
        duration_seconds=max(line.end_ms for line in payload.utterances) / 1000,
        dominant_tone=dominant,
        preview_text=payload.utterances[0].text[:120],
    )
    await db.commit()

    log.info(
        "session_imported",
        session_id=str(session_id),
        user_id=str(user.id),
        utterances=len(rows),
    )
    return await get_session(session_id, user, sessions)
