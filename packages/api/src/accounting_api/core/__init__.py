"""Business logic, with no web framework in it.

Nothing in this package may import FastAPI, Starlette, or a `Request`. Each
function takes an `asyncpg.Connection` (already scoped to a workspace) plus
plain values, and returns plain values or raises a `DomainError`.

That constraint is what makes `apps/desktop` and `apps/server` the same
product: the HTTP layer is a delivery mechanism, and the rules live here where
they can be tested without binding a port.
"""
