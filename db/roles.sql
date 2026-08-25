-- =============================================================================
-- Database roles.
--
-- Run once per deployment, AFTER schema.sql, as a superuser or the database
-- owner. Roles are cluster-level objects and the password differs per install,
-- so they are kept out of schema.sql (which must stay idempotently appliable
-- and secret-free).
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--        -v nl_query_password="'<generated-secret>'" -f db/roles.sql
--
-- The point of this file: the natural-language query feature turns user text
-- into SQL. That SQL must execute on a connection that is incapable of doing
-- damage even if the model is fully compromised by a prompt injection buried
-- in a scanned receipt. Capability, not prompt instructions, is the control.
-- =============================================================================

\set ON_ERROR_STOP on

-- -----------------------------------------------------------------------------
-- nl_query: the role that runs generated text-to-SQL
-- -----------------------------------------------------------------------------

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nl_query') THEN
        CREATE ROLE nl_query LOGIN;
    END IF;
END;
$do$;

ALTER ROLE nl_query PASSWORD :nl_query_password;

-- Read-only at the transaction level: even a generated INSERT/UPDATE/DELETE
-- that slipped through query validation cannot commit.
ALTER ROLE nl_query SET default_transaction_read_only = on;

-- A generated query cannot pin the ledger under a cartesian join.
ALTER ROLE nl_query SET statement_timeout = '10s';
ALTER ROLE nl_query SET idle_in_transaction_session_timeout = '30s';

-- The role sees the projection and nothing else. `public` is not on its path,
-- so an unqualified `SELECT * FROM journal_entries` resolves to the scoped
-- view rather than the base table.
ALTER ROLE nl_query SET search_path = ledger_query;

-- No rights on the base tables at all. The views in ledger_query are owned by
-- the app owner, so SELECT through them works by ownership chaining without
-- the caller ever holding a privilege on `public.journal_entries` et al.
REVOKE ALL ON SCHEMA public FROM nl_query;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM nl_query;

GRANT USAGE ON SCHEMA ledger_query TO nl_query;
GRANT SELECT ON ALL TABLES IN SCHEMA ledger_query TO nl_query;

-- Views added to the projection later are readable without re-running grants.
ALTER DEFAULT PRIVILEGES IN SCHEMA ledger_query GRANT SELECT ON TABLES TO nl_query;

-- Needed so the session can scope itself before querying:
--   SET LOCAL app.workspace_id = '<uuid>';
-- app.* is a user-defined GUC and needs no special grant; noted here because
-- the views return zero rows without it, which looks like a bug otherwise.


-- -----------------------------------------------------------------------------
-- Sanity check
-- -----------------------------------------------------------------------------
-- Confirm the read-only role genuinely cannot reach the base tables:
--
--   psql "postgresql://nl_query:<secret>@host/db" -c \
--     "SELECT * FROM public.workspace_ai_config;"
--   -- expected: ERROR: permission denied for schema public
--
--   psql "postgresql://nl_query:<secret>@host/db" -c \
--     "SET app.workspace_id = '<uuid>'; DELETE FROM ledger_query.journal_lines;"
--   -- expected: ERROR: cannot execute DELETE in a read-only transaction
