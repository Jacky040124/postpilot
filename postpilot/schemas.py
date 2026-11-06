from __future__ import annotations

from datetime import UTC, datetime

from pydantic import BaseModel, ConfigDict, Field, field_validator

from postpilot.models import PostStatus


class PostCreate(BaseModel):
    content: str = Field(min_length=1, max_length=2000)
    channel: str = Field(min_length=1, max_length=64, examples=["marketing"])
    publish_at: datetime = Field(description="When to publish. Naive times are treated as UTC.")

    @field_validator("publish_at")
    @classmethod
    def normalise_to_utc(cls, value: datetime) -> datetime:
        if value.tzinfo is None:
            value = value.replace(tzinfo=UTC)
        return value.astimezone(UTC)


class PostOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    content: str
    channel: str
    publish_at: datetime
    status: PostStatus
    attempts: int
    last_error: str | None
    created_at: datetime
    published_at: datetime | None
