# apps/server

The FastAPI backend deployed multi-tenant, for hosted installs and for on-prem
"cowork" deployments.

This directory holds no business logic and never will. It imports `create_app`
from `packages/api` and configures it for `DeploymentMode.SERVER`. If something
needs to behave differently here than it does in the desktop build, it belongs
in `Settings` — the moment logic forks between the two, the desktop app has
become a second product to maintain.

## Run it

```bash
docker compose -f apps/server/docker-compose.yml up
```

That brings up Postgres 16, applies `db/schema.sql` on first boot, and serves
the API on <http://localhost:8000> with docs at `/docs`.
