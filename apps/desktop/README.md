# apps/desktop

Electron + React/TypeScript shell. Runs the FastAPI backend from
`packages/api` as a local subprocess against an embedded Postgres.

**Phase 4. Nothing here yet, deliberately** — the build order in
`claude-code-kickoff-prompt.md` puts the schema, the backend, and the
ElectricSQL write-path spike ahead of any UI work.

When it does get built, two things are already decided and should not be
rediscovered:

- `document.documentElement.lang` and `.dir` are set **once at the app root**
  from the active locale (`en` → `ltr`, `fa` → `rtl`), never inferred
  per-component. See `design-tokens/tailwind.config.ts`.
- The backend subprocess and the embedded Postgres start independently, so the
  shell must poll `GET /api/v1/health/ready` before showing the UI. A open port
  is not the same as a usable database.
