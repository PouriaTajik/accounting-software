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


class DuplicateKey(DomainError):
    """A uniqueness constraint refused the write.

    User error, not a bug: two accounts cannot share a code within a
    workspace, and an entry can be reversed at most once.
    """

    status_code = 409
    code = "duplicate_key"


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


class PeriodLocked(DomainError):
    """The entry's date falls at or before the workspace's books-locked-through date."""

    status_code = 409
    code = "period_locked"


class FiscalYearClosed(DomainError):
    """The entry's date falls inside a fiscal year that has been closed."""

    status_code = 409
    code = "fiscal_year_closed"


class EntryNotPosted(DomainError):
    """Only a posted entry can be reversed; a draft is deleted instead."""

    status_code = 422
    code = "entry_not_posted"


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

def translate_database_error(exc: Exception) -> DomainError | None:
    """Map an asyncpg error onto a domain error, or None if it is unexpected.

    Returning None matters: an unrecognised database failure must surface as a
    500 and get logged, not be smoothed into a 4xx that tells the user they
    did something wrong.

    Several distinct guards in db/schema.sql share one SQLSTATE -- Postgres has
    no room for more than one custom code per condition here -- so the message
    text, which every trigger writes to be shown to a user, is what tells them
    apart. Each branch is a guard that actually exists in db/migrations; a
    message this does not recognise falls through to the generic case for its
    SQLSTATE, or to None.
    """
    sqlstate = getattr(exc, "sqlstate", None)
    if sqlstate is None:
        return None

    message = getattr(exc, "message", None) or str(exc)

    if sqlstate == "23001":  # restrict_violation
        if "tenant boundary" in message:
            return TenantBoundaryViolation(message)
        if "books are locked through" in message:
            return PeriodLocked(message)
        if "fiscal year" in message and "is closed" in message:
            return FiscalYearClosed(message)
        # Posted-entry/-line immutability, and the insert-must-be-a-draft guard.
        return PostedEntryImmutable(message)

    if sqlstate == "23505":  # unique_violation
        return DuplicateKey(message)

    if sqlstate == "23514":  # check_violation
        # Only the entry-level posting guards (unbalanced, too few lines, zero
        # value) raise this custom-worded; a bare column CHECK (e.g. a
        # single-sided journal_lines violation) is a request the API layer
        # should have rejected before it reached the database, so it is left
        # unmapped rather than mislabeled as "unbalanced".
        if message.startswith("journal_entries:"):
            return UnbalancedEntry(message)
        return None

    return None


def register_exception_handlers(app: Any) -> None:
    """Wire domain errors to HTTP responses on a FastAPI app."""
    import asyncpg
    from fastapi import Request
    from fastapi.encoders import jsonable_encoder
    from fastapi.responses import JSONResponse

    @app.exception_handler(DomainError)
    async def _handle_domain_error(_: Request, exc: DomainError) -> JSONResponse:
        # `to_payload()` may carry raw row values (UUIDs, Decimals, datetimes)
        # straight from asyncpg, e.g. VersionConflict.current -- jsonable_encoder
        # is what makes those safe to hand to the stdlib json module underneath.
        return JSONResponse(
            status_code=exc.status_code, content=jsonable_encoder(exc.to_payload())
        )

    @app.exception_handler(asyncpg.PostgresError)
    async def _handle_postgres_error(request: Request, exc: asyncpg.PostgresError) -> JSONResponse:
        # Recognised trigger refusals become the domain error they represent.
        # Anything else must keep surfacing as a 500: an unmapped failure is
        # not the user's fault, and translating it into a 4xx would say it is.
        domain_error = translate_database_error(exc)
        if domain_error is None:
            raise exc
        return await _handle_domain_error(request, domain_error)
