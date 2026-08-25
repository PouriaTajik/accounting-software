"""FastAPI backend for the accounting app.

Layering, outermost to innermost:

    routers/   HTTP shape only -- parse, delegate, map errors
    core/      business logic, no web framework, testable without a server
    db.py      connection pools and workspace-scoped transactions
    db/schema.sql   the invariants that must hold no matter which of the above
                    has a bug, enforced by Postgres triggers

`apps/desktop` and `apps/server` both import `create_app` from here. There is
one implementation of the business logic, not two.
"""

__version__ = "0.1.0"
