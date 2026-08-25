"""Domain errors, and the translation from Postgres errors into them.

`db/schema.sql` enforces the ledger invariants with triggers, which means the
authoritative "no, you may not do that" arrives as an `asyncpg` exception
rather than as a Python check. This module is that seam: it turns a database
refusal into a typed domain error, and a domain error into an HTTP response.

Nothing here imports FastAPI at module level except the handler registration
at the bottom, so `core/` can raise these without depending on the web layer.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID


class DomainError(Exception):
    """Base for every expected, user-facing failure."""

    status_code: int = 400
    code: str = "domain_error"

    def __init__(self, message: str, **context: Any) -> None:
        super().__init__(message)
        self.message = message
        self.context = context

    def to_payload(self) -> dict[str, Any]:
        return {"code": self.code, "message": self.message, **self.context}


class NotFound(DomainError):
    status_code = 404
    code = "not_found"


class WorkspaceNotFound(NotFound):
    code = "workspace_not_found"


class PostedEntryImmutable(DomainError):
    """A posted journal entry (or one of its lines) was modified.

    Not a validation failure to be fixed and retried -- the correct response is
    to record a reversing entry, so the message says so.
    """

    status_code = 409
    code = "posted_entry_immutable"


class UnbalancedEntry(DomainError):
    """Debits did not equal credits at the moment of posting."""

    status_code = 422
    code = "unbalanced_entry"


class VersionConflict(DomainError):
    """Optimistic concurrency lost: someone else wrote this row first.

    Financial data is never auto-merged (ARCHITECTURE.md). The payload carries
    both sides so the client can show them and let a human choose. Adding a
    "resolution" that picks a winner server-side would defeat the point of the
    `version` column, so this error deliberately offers no such affordance.
    """

    status_code = 409
    code = "version_conflict"

    def __init__(
        self,
        entity: str,
        entity_id: UUID,
        expected_version: int,
        current: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(
            f"{entity} {entity_id} was changed by someone else "
            f"(you had version {expected_version}).",
            entity=entity,
            entity_id=str(entity_id),
            expected_version=expected_version,
            current=current,
        )


class TenantBoundaryViolation(DomainError):
    """A write tried to cross `workspace_id`. Always a bug, never user error."""

    status_code = 403
    code = "tenant_boundary_violation"


class AIProviderNotConfigured(DomainError):
    status_code = 503
    code = "ai_provider_not_configured"


class UnsafeGeneratedQuery(DomainError):
    """Text-to-SQL produced something the query guard refused to execute."""

    status_code = 422
    code = "unsafe_generated_query"


# --------------------------------------------------------------------------
# Postgres -> domain translation
# --------------------------------------------------------------------------

#: SQLSTATEs raised by the guards in db/schema.sql. The trigger messages are
#: written to be shown to a user, so they are carried through rather than
#: replaced with something vaguer.
_SQLSTATE_MAP: dict[str, type[DomainError]] = {
    "23001": PostedEntryImmutable,   # restrict_violation
    "23514": UnbalancedEntry,        # check_violation
}


def translate_database_error(exc: Exception) -> DomainError | None:
    """Map an asyncpg error onto a domain error, or None if it is unexpected.

    Returning None matters: an unrecognised database failure must surface as a
    500 and get logged, not be smoothed into a 4xx that tells the user they
    did something wrong.
    """
    sqlstate = getattr(exc, "sqlstate", None)
    if sqlstate is None:
        return None

    error_cls = _SQLSTATE_MAP.get(sqlstate)
    if error_cls is None:
        return None

    message = getattr(exc, "message", None) or str(exc)

    # The tenant guards share 23001 with the immutability guards; the message
    # is what distinguishes them.
    if error_cls is PostedEntryImmutable and "tenant boundary" in message:
        return TenantBoundaryViolation(message)

    return error_cls(message)


def register_exception_handlers(app: Any) -> None:
    """Wire domain errors to HTTP responses on a FastAPI app."""
    from fastapi import Request
    from fastapi.responses import JSONResponse

    @app.exception_handler(DomainError)
    async def _handle_domain_error(_: Request, exc: DomainError) -> JSONResponse:
        return JSONResponse(status_code=exc.status_code, content=exc.to_payload())
