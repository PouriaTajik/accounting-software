"""HTTP routers.

Routers stay thin on purpose: parse, delegate to `accounting_api.core`, map
errors. The rule that keeps `apps/desktop` and `apps/server` from drifting is
that no business rule may live in this package -- if a router is the only
place something is decided, it cannot be tested without a running server and
it cannot be reused by the local subprocess build.
"""

from . import (
    accounts,
    ai_config,
    anomalies,
    auth,
    categorization,
    documents,
    health,
    imports,
    journal,
    members,
    query,
    workspaces,
)

#: Registered in this order by `create_app()`.
ALL_ROUTERS = [
    health.router,
    auth.router,
    workspaces.router,
    members.router,
    ai_config.router,
    accounts.router,
    journal.router,
    documents.router,
    imports.router,
    categorization.router,
    anomalies.router,
    query.router,
]

__all__ = ["ALL_ROUTERS"]
