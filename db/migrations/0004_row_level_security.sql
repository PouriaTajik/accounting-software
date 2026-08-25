-- =============================================================================
-- 0004 -- row-level security.
--
-- Composite foreign keys already make a cross-tenant *reference* structurally
-- impossible. They do nothing about a query that simply *reads* the wrong
-- tenant: every statement in packages/api has to remember
-- `WHERE workspace_id = $1`, and one omission is a cross-tenant leak in hosted
-- mode. That is the highest-severity bug class in a multi-tenant accounting
-- product, and it is one that can be deleted structurally instead of policed
-- in review.
--
-- The mechanism is the one the ledger_query views already use, applied to the
-- application's own connection: every policy compares `workspace_id` against
-- `app_current_workspace()`, which reads the `app.workspace_id` session
-- setting. `Database.workspace()` in packages/api already sets it
-- transaction-locally.
--
-- Unset means invisible, not unfiltered. `app_current_workspace()` returns
-- NULL when the setting is absent, and `workspace_id = NULL` is NULL rather
-- than true, so an unscoped session sees zero rows and can write none. Failing
-- closed is the whole point; a policy that fell back to "all rows" when
-- unscoped would be worse than no policy, because it would look like one.
--
-- ---------------------------------------------------------------------------
-- ENABLE, deliberately NOT FORCE.
--
-- A table's owner is exempt from its policies unless the table is set FORCE
-- ROW LEVEL SECURITY. That exemption is not an oversight here, it is required:
-- migrations legitimately need to touch every tenant's rows (0002's currency
-- backfill is exactly that), and under FORCE those cross-tenant statements
-- would match no rows and silently do nothing -- a corrupted migration that
-- reports success.
--
-- The exemption is only dangerous if the *application* connects as the owner,
-- which is precisely the trap this schema has been bitten by before (the
-- REVOKE ... FROM nl_query in roles.sql that looked applied and was not). So
-- that specific risk is closed where it actually lives:
--
--   * db/roles.sql creates `accounting_app`, a non-owner login role with DML
--     grants and no BYPASSRLS, for the API to connect as.
--   * db/verify_rls.sql asserts that role is not a table owner, is not a
--     superuser, and does not hold BYPASSRLS -- so a misconfiguration fails a
--     test rather than leaking quietly.
--   * packages/api refuses to start in server mode on a connection that can
--     bypass RLS.
--
-- FORCE plus a BYPASSRLS grant on the owner would be equivalent in effect and
-- would additionally require superuser at setup time, which managed Postgres
-- does not always give. This way needs no superuser.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Tenant tables: the workspace_id on the row is the boundary
-- -----------------------------------------------------------------------------

-- Applied in a loop rather than 27 near-identical statements: the list is the
-- thing worth reading, and a loop cannot get one table's policy subtly wrong.
-- Any table with a workspace_id belongs in here. If a future migration adds
-- one and forgets, db/verify_rls.sql fails -- it checks the catalog for
-- workspace_id columns without policies rather than a list it was told.
DO $rls$
DECLARE
    tenant_table text;
BEGIN
    FOREACH tenant_table IN ARRAY ARRAY[
        'accounts',
        'anomaly_flags',
        'categorization_rules',
        'devices',
        'documents',
        'journal_entries',
        'journal_lines',
        'workspace_ai_config',
        'workspace_members'
    ]
    LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', tenant_table);
        EXECUTE format(
            'CREATE POLICY %I ON %I FOR ALL '
            '  USING (workspace_id = app_current_workspace()) '
            '  WITH CHECK (workspace_id = app_current_workspace())',
            tenant_table || '_workspace_isolation',
            tenant_table
        );
    END LOOP;
END;
$rls$;


-- -----------------------------------------------------------------------------
-- The workspace row itself
-- -----------------------------------------------------------------------------

ALTER TABLE workspaces ENABLE ROW LEVEL SECURITY;

CREATE POLICY workspaces_workspace_isolation ON workspaces FOR ALL
    USING (id = app_current_workspace())
    WITH CHECK (id = app_current_workspace());

-- Creating a workspace is the one operation that cannot be performed from
-- inside one: there is no workspace to scope the session to yet. It therefore
-- runs as the owner (migrations, provisioning, the desktop app's first-run
-- setup), not through the application's RLS-bound connection.


-- -----------------------------------------------------------------------------
-- Users: global identity, scoped visibility
-- -----------------------------------------------------------------------------

-- `users` has no workspace_id -- identity is global by design (0003). Scoping
-- is therefore by shared membership: you can see a user exactly when they are
-- a member of the workspace this session is scoped to. Without this, any
-- tenant could enumerate every user of a hosted install.
ALTER TABLE users ENABLE ROW LEVEL SECURITY;

CREATE POLICY users_visible_to_co_members ON users FOR SELECT
    USING (EXISTS (
        SELECT 1 FROM workspace_members m
         WHERE m.user_id = users.id
           AND m.workspace_id = app_current_workspace()
    ));

-- No INSERT/UPDATE/DELETE policy, so the application connection cannot create
-- or alter users at all: registration and profile changes are an identity
-- concern, and identity is not yet designed (0003). When it is, it gets its
-- own policies here rather than inheriting a permissive default.


-- -----------------------------------------------------------------------------
-- Deliberately not protected
-- -----------------------------------------------------------------------------
-- `currencies` is reference data, identical for every tenant, and every
-- workspace must be able to read it. `schema_migrations` is infrastructure.
-- Neither carries tenant data, so neither gets a policy; both are restricted
-- by grant instead -- see db/roles.sql, which gives the application SELECT on
-- currencies and nothing at all on schema_migrations.
