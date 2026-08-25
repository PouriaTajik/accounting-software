-- =============================================================================
-- Database roles.
--
-- Run AFTER schema.sql, as a superuser or the database owner. The password
-- differs per install, so this is kept out of schema.sql (which must stay
-- secret-free). Unlike schema.sql, this file IS safe to re-run: every
-- statement here is idempotent.
--
-- ONCE PER DATABASE, NOT ONCE PER CLUSTER. The role itself is a cluster-level
-- object, but every GRANT and REVOKE below is scoped to the current database.
-- Create a second database in the same cluster and nl_query starts out able to
-- read its base tables, because the hardening here never applied there. Run
-- this file against each database that holds ledger data.
-- db/verify_roles.sql fails loudly on a database that was missed.
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

-- Defaults, NOT boundaries. Read this before relying on any of the three
-- settings below.
--
-- default_transaction_read_only, statement_timeout and
-- idle_in_transaction_session_timeout are all USERSET parameters: the role can
-- override its own role-level value with a plain `SET` and Postgres offers no
-- way to forbid that for a non-superuser. Verified against PG16 --
-- db/verify_roles.sql demonstrates the override working. So a compromised
-- generator CAN turn the read-only default off and CAN clear the timeout.
--
-- They are set anyway because they make the common case safe: an accidental
-- write or a runaway join in a query nobody attacked fails fast and loudly.
-- What actually stops a hostile query is the privilege grant below -- nl_query
-- holds no INSERT/UPDATE/DELETE anywhere and no rights at all on the base
-- tables, so turning read-only off gains an attacker nothing to write to.
ALTER ROLE nl_query SET default_transaction_read_only = on;
ALTER ROLE nl_query SET statement_timeout = '10s';
ALTER ROLE nl_query SET idle_in_transaction_session_timeout = '30s';

-- The role sees the projection and nothing else. `public` is not on its path,
-- so an unqualified `SELECT * FROM journal_entries` resolves to the scoped
-- view rather than the base table.
ALTER ROLE nl_query SET search_path = ledger_query;

-- No rights on the base tables at all. The views in ledger_query are owned by
-- the app owner, so SELECT through them works by ownership chaining without
-- the caller ever holding a privilege on `public.journal_entries` et al.
--
-- This -- not the read-only default above -- is the control that holds.
REVOKE ALL ON SCHEMA public FROM nl_query;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM nl_query;

-- The two REVOKEs above are necessary but not sufficient, and it is worth
-- being precise about why. Postgres grants USAGE on schema `public` to the
-- pseudo-role PUBLIC by default, and revoking from `nl_query` does not touch a
-- privilege it holds via PUBLIC -- after those two statements
-- has_schema_privilege('nl_query','public','USAGE') is still true. Today that
-- is harmless, because no table in `public` grants SELECT to PUBLIC. It stops
-- being harmless the first time someone runs a broad `GRANT ... TO PUBLIC`.
--
-- So close it at the source. Blast radius: any *other* role that reaches
-- `public` today by way of PUBLIC needs an explicit GRANT after this runs. The
-- database owner is re-granted below; the app connects as the owner, and
-- nl_query is the only other role this deployment defines.
REVOKE USAGE ON SCHEMA public FROM PUBLIC;

DO $do$
BEGIN
    EXECUTE format(
        'GRANT USAGE, CREATE ON SCHEMA public TO %I',
        (SELECT pg_get_userbyid(datdba) FROM pg_database
          WHERE datname = current_database())
    );
END;
$do$;

-- Same reasoning for tables added to `public` later: default privileges are
-- per-granting-role, so this pins the default for the role that creates them.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM PUBLIC;

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
