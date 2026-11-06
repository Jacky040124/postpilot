"""REST API: create, list and cancel scheduled posts, plus health and metrics."""

from __future__ import annotations

import logging
import time
from collections.abc import Iterator
from contextlib import asynccontextmanager
from typing import Annotated

from fastapi import Depends, FastAPI, HTTPException, Query, Request, Response, status
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from sqlalchemy import select, text
from sqlalchemy.orm import Session

from postpilot import __version__
from postpilot.config import Settings
from postpilot.db import create_tables, make_engine, make_session_factory
from postpilot.metrics import HTTP_LATENCY, HTTP_REQUESTS
from postpilot.models import Post, PostStatus
from postpilot.schemas import PostCreate, PostOut

log = logging.getLogger("postpilot.api")

# Probes and scrapes would drown out real traffic in the request log.
_QUIET_PATHS = {"/healthz", "/readyz", "/metrics"}


def get_session(request: Request) -> Iterator[Session]:
    with request.app.state.session_factory() as session:
        yield session


SessionDep = Annotated[Session, Depends(get_session)]


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    engine = make_engine(settings.database_url)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        # Small project: create tables on boot. A real team would use Alembic migrations.
        create_tables(engine)
        log.info("api_started", extra={"version": __version__})
        yield
        engine.dispose()

    app = FastAPI(title="PostPilot", version=__version__, lifespan=lifespan)
    app.state.engine = engine
    app.state.session_factory = make_session_factory(engine)

    @app.middleware("http")
    async def observe_requests(request: Request, call_next):
        start = time.perf_counter()
        response = await call_next(request)
        elapsed = time.perf_counter() - start
        route = request.scope.get("route")
        # Use the route template (/posts/{post_id}) so label values stay bounded.
        route_path = getattr(route, "path", "unmatched")
        HTTP_REQUESTS.labels(request.method, route_path, str(response.status_code)).inc()
        HTTP_LATENCY.labels(request.method, route_path).observe(elapsed)
        if request.url.path not in _QUIET_PATHS:
            log.info(
                "request",
                extra={
                    "method": request.method,
                    "path": request.url.path,
                    "status": response.status_code,
                    "duration_ms": round(elapsed * 1000, 2),
                },
            )
        return response

    @app.get("/healthz", tags=["ops"])
    def healthz() -> dict:
        """Liveness: the process is up. Does not touch dependencies."""
        return {"status": "ok"}

    @app.get("/readyz", tags=["ops"])
    def readyz(response: Response) -> dict:
        """Readiness: we can reach the database, so we can serve traffic."""
        try:
            with app.state.engine.connect() as conn:
                conn.execute(text("SELECT 1"))
        except Exception as exc:
            log.warning("readiness_failed", extra={"error": str(exc)})
            response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
            return {"status": "unavailable"}
        return {"status": "ready"}

    @app.get("/metrics", tags=["ops"], include_in_schema=False)
    def metrics() -> Response:
        return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

    @app.post("/posts", response_model=PostOut, status_code=status.HTTP_201_CREATED)
    def create_post(payload: PostCreate, session: SessionDep) -> Post:
        post = Post(content=payload.content, channel=payload.channel, publish_at=payload.publish_at)
        session.add(post)
        session.commit()
        log.info("post_scheduled", extra={"post_id": post.id, "channel": post.channel})
        return post

    @app.get("/posts", response_model=list[PostOut])
    def list_posts(
        session: SessionDep,
        status_filter: Annotated[PostStatus | None, Query(alias="status")] = None,
        limit: Annotated[int, Query(ge=1, le=200)] = 50,
    ) -> list[Post]:
        stmt = select(Post).order_by(Post.publish_at).limit(limit)
        if status_filter is not None:
            stmt = stmt.where(Post.status == status_filter)
        return list(session.scalars(stmt))

    @app.get("/posts/{post_id}", response_model=PostOut)
    def get_post(post_id: int, session: SessionDep) -> Post:
        post = session.get(Post, post_id)
        if post is None:
            raise HTTPException(status_code=404, detail="post not found")
        return post

    @app.post("/posts/{post_id}/cancel", response_model=PostOut)
    def cancel_post(post_id: int, session: SessionDep) -> Post:
        # Lock the row so we cannot race the worker that might be publishing it.
        post = session.get(Post, post_id, with_for_update=True)
        if post is None:
            raise HTTPException(status_code=404, detail="post not found")
        if post.status != PostStatus.SCHEDULED:
            raise HTTPException(status_code=409, detail=f"cannot cancel a {post.status} post")
        post.status = PostStatus.CANCELLED
        session.commit()
        log.info("post_cancelled", extra={"post_id": post.id})
        return post

    return app
