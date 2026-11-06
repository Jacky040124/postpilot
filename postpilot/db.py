"""Database engine, session factory and table creation."""

from __future__ import annotations

from datetime import UTC, datetime

from sqlalchemy import DateTime, Engine, create_engine
from sqlalchemy.orm import DeclarativeBase, sessionmaker
from sqlalchemy.types import TypeDecorator


class Base(DeclarativeBase):
    pass


class UTCDateTime(TypeDecorator):
    """Store datetimes in UTC and always return timezone-aware values.

    Postgres keeps the offset, SQLite (used in tests) does not, so normalise here.
    """

    impl = DateTime(timezone=True)
    cache_ok = True

    def process_bind_param(self, value: datetime | None, dialect) -> datetime | None:
        if value is None:
            return None
        if value.tzinfo is None:
            value = value.replace(tzinfo=UTC)
        return value.astimezone(UTC)

    def process_result_value(self, value: datetime | None, dialect) -> datetime | None:
        if value is None:
            return None
        if value.tzinfo is None:
            return value.replace(tzinfo=UTC)
        return value.astimezone(UTC)


def make_engine(database_url: str) -> Engine:
    kwargs: dict = {"pool_pre_ping": True}
    if database_url.startswith("sqlite"):
        kwargs["connect_args"] = {"check_same_thread": False}
    return create_engine(database_url, **kwargs)


def make_session_factory(engine: Engine) -> sessionmaker:
    return sessionmaker(bind=engine, expire_on_commit=False)


def create_tables(engine: Engine) -> None:
    # Import models so they register on Base.metadata.
    from postpilot import models  # noqa: F401

    Base.metadata.create_all(engine)
