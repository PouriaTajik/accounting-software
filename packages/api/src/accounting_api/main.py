"""Application factory.

`create_app()` is the single entry point for both deployment targets:
`apps/desktop` starts it as a local subprocess, `apps/server` serves it
multi-tenant. Neither one subclasses or patches it -- if the two ever need to
differ, that difference belongs in `Settings`, not in a second app.
"""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .config import Settings, get_settings
from .db import Database
from .errors import register_exception_handlers
from .routers import ALL_ROUTERS

logger = logging.getLogger(__name__)

API_PREFIX = "/api/v1"


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    logging.basicConfig(level=settings.log_level)

    # Constructed eagerly, connected in lifespan. Keeping the two separate
    # means `app.state.db` is always present -- routes and tests get a
    # Database that reports `is_connected == False` rather than an
    # AttributeError when the pool has not been opened.
    database = Database(settings)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        try:
            await database.connect()
            logger.info(
                "database connected (mode=%s)", settings.deployment_mode.value
            )
        except Exception:
            # The desktop shell starts the embedded Postgres and this
            # subprocess concurrently, so a cold start losing that race is
            # expected. Serving /health with a degraded readiness probe is more
            # useful than exiting -- the shell polls until it goes green.
            logger.exception("database unavailable at startup; serving degraded")
        try:
            yield
        finally:
            await database.disconnect()

    app = FastAPI(
        title="Accounting API",
        version="0.1.0",
        summary="AI-first double-entry accounting.",
        lifespan=lifespan,
    )
    app.state.db = database
    app.state.settings = settings

    if settings.cors_allow_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=settings.cors_allow_origins,
            allow_credentials=True,
            allow_methods=["*"],
            allow_headers=["*"],
        )

    register_exception_handlers(app)

    for router in ALL_ROUTERS:
        app.include_router(router, prefix=API_PREFIX)

    return app


#: Module-level app for `uvicorn accounting_api.main:app`.
app = create_app()
