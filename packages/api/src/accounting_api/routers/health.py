"""Liveness and readiness.

The only router with real logic in phase 1, because the desktop shell needs it
to know when the backend subprocess has finished starting.
"""

from fastapi import APIRouter, Response, status

from ..deps import Config, Db

router = APIRouter(tags=["health"])


@router.get("/health")
async def health(settings: Config) -> dict[str, str]:
    """Process is up. Does not touch the database."""
    return {"status": "ok", "deployment_mode": settings.deployment_mode.value}


@router.get("/health/ready")
async def ready(db: Db, response: Response) -> dict[str, object]:
    """Up *and* able to reach Postgres.

    The desktop shell polls this before showing the UI: the embedded Postgres
    and the API subprocess start independently, so "port is open" is not the
    same as "usable".
    """
    database_ok = await db.ping() if db.is_connected else False
    if not database_ok:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    return {"status": "ok" if database_ok else "degraded", "database": database_ok}
