"""utterances.tone_basis — 톤 판정의 근거를 함께 저장한다

Revision ID: 0002
Revises: 0001
Create Date: 2026-08-14

화면에 "화난 말투로 들림"이라고 뜨면 사용자는 그걸 사실로 받아들인다. 그런데
근거가 운율(음량·피치·속도)뿐일 때와 문장 내용까지 봤을 때는 오판 확률이 크게
다르다 — 사투리, 평소 목소리가 큰 사람, 신나서 흥분한 사람, 말투 특성이 다른
사람이 전부 운율에 섞여 들어오기 때문이다.

라이브 화면은 메모리에 있는 값으로 이걸 표시할 수 있지만, 기록 화면은 DB 를
읽는다. 근거를 저장하지 않으면 기록에서는 같은 자막이 근거 없이 단정적으로만
보인다.
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0002"
down_revision: str | None = "0001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


tone_basis = postgresql.ENUM(
    "voice",
    "voice_text",
    name="tone_basis",
    create_type=False,
)


def upgrade() -> None:
    bind = op.get_bind()
    tone_basis.create(bind, checkfirst=True)

    # 기존 행은 'voice' 로 채운다. 이 컬럼이 없던 시절의 판정은 근거를 알 수
    # 없는데, 둘 중에서는 **약한 쪽**을 적어야 한다. 실제로는 문장까지 봤는데
    # "목소리만 봤다"고 표시하면 사용자가 덜 믿을 뿐이지만, 반대로 적으면
    # 근거를 부풀려 말하는 셈이 된다.
    op.add_column(
        "utterances",
        sa.Column("tone_basis", tone_basis, server_default="voice", nullable=False),
    )


def downgrade() -> None:
    op.drop_column("utterances", "tone_basis")
    tone_basis.drop(op.get_bind(), checkfirst=True)
