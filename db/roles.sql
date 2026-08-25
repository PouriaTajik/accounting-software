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
--        -v nl_query_password="'<generated-secret>'" \
--        -v app_password="'<generated-secret>'" -f db/roles.sql
--
-- Two roles, for two different threats.
--
--   nl_query        The natural-language query feature turns user text into
--                   SQL. That SQL must execute on a connection incapable of
--                   doing damage even if the model is fully compromised by a
--                   prompt injection buried in a scanned receipt.
--
--   accounting_app  The connection the API itself uses. Its job is to NOT be
--                   the table owner, because a table's owner is exempt from
--                   its row-level security policies. Connecting the API as the
--                   owner would leave 0004's policies in place and inert --
--                   the same shape of failure as a REVOKE that looks applied
--                   and is not.
--
-- Capability, not prompt instructions and not code review, is the control.
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
-- accounting_app: the role the API connects as
-- -----------------------------------------------------------------------------
-- Exists for one reason: it is NOT the owner of the tables. A table's owner is
-- exempt from its row-level security policies, so an API connecting as the
-- owner would leave every policy in 0004 in place and doing nothing.
--
-- The exemption itself is wanted -- migrations must be able to touch every
-- tenant's rows, and 0004 explains why FORCE ROW LEVEL SECURITY would break
-- them. It just must not extend to the request path.

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'accounting_app') THEN
        CREATE ROLE accounting_app LOGIN;
    END IF;
END;
$do$;

ALTER ROLE accounting_app PASSWORD :app_password;

-- Explicitly spelled out rather than assumed. NOSUPERUSER and NOBYPASSRLS are
-- the defaults for a new role, but this file is also the repair path for a
-- database someone has already been administering by hand, and re-running it
-- should put the role back into a known state.
ALTER ROLE accounting_app NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;

-- Revoked from PUBLIC further up, so the application needs it explicitly.
GRANT USAGE ON SCHEMA public TO accounting_app;

-- DML only. No DDL, no ownership: the application cannot drop a policy, alter
-- a table out of RLS, or disable a trigger, whatever a request talks it into.
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public
    TO accounting_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO accounting_app;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO accounting_app;

-- Reference data: readable by every tenant, writable by none of them. It has
-- no RLS policy (see 0004), so the grant is the only thing scoping it.
REVOKE INSERT, UPDATE, DELETE ON currencies FROM accounting_app;

-- Migration bookkeeping is infrastructure. The application has no business
-- reading it and certainly none writing it -- a forged row here would make the
-- runner skip a migration.
REVOKE ALL ON schema_migrations FROM accounting_app;

-- The ledger_query projection is nl_query's surface, not the application's.
-- The API reads base tables directly, under RLS.
REVOKE ALL ON SCHEMA ledger_query FROM accounting_app;


-- -----------------------------------------------------------------------------
-- Sanity check
-- -----------------------------------------------------------------------------
-- db/verify_roles.sql and db/verify_rls.sql assert all of this. To watch the
-- login-time behaviour by hand, which neither can (role settings apply at
-- login, and SET ROLE does not trigger them):
--
--   psql "postgresql://nl_query:<secret>@host/db" -c \
--     "SELECT * FROM public.workspace_ai_config;"
--   -- expected: ERROR: permission denied for schema public
--
--   psql "postgresql://accounting_app:<secret>@host/db" -c \
--     "SELECT count(*) FROM journal_lines;"
--   -- expected: 0 -- no app.workspace_id set, so RLS shows nothing
--
--   psql "postgresql://accounting_app:<secret>@host/db" -c \
--     "SET app.workspace_id = '<uuid>'; SELECT count(*) FROM journal_lines;"
--   -- expected: that workspace's lines, and only those
