from __future__ import annotations

import enum
from datetime import UTC, datetime

from sqlalchemy import Enum, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from postpilot.db import Base, UTCDateTime


def utcnow() -> datetime:
    return datetime.now(UTC)


class PostStatus(enum.StrEnum):
    SCHEDULED = "scheduled"
    PUBLISHED = "published"
    FAILED = "failed"
    CANCELLED = "cancelled"


class Post(Base):
    __tablename__ = "posts"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    content: Mapped[str] = mapped_column(Text)
    channel: Mapped[str] = mapped_column(String(64))
    publish_at: Mapped[datetime] = mapped_column(UTCDateTime, index=True)
    status: Mapped[PostStatus] = mapped_column(
        Enum(
            PostStatus,
            native_enum=False,
            length=16,
            values_callable=lambda enum_cls: [member.value for member in enum_cls],
        ),
        default=PostStatus.SCHEDULED,
        index=True,
    )
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    last_error: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    published_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)
