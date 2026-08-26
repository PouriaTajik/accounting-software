-- =============================================================================
-- 0006 -- the version-bump trigger `workspaces` never got.
--
-- workspaces.version has carried `DEFAULT 1 NOT NULL` since 0001, and the
-- API's optimistic-concurrency pattern everywhere else is
--   UPDATE ... SET ... WHERE id = $1 AND version = $2
-- trusting the database to bump `version` on every UPDATE. 0001 wired that
-- bump (`guard_mutable_row`) onto `accounts` and `workspace_ai_config`;
-- 0003 and 0005 wired it onto the tables they added. `workspaces` itself was
-- the one table with a `version` column and no trigger -- so an UPDATE
-- against a stale version matched anyway, and two concurrent PATCHes each
-- believing they held the current version could both succeed, the second
-- silently clobbering the first, with neither seeing a 409. Exactly the
-- "looks applied and is not" failure shape this schema has been bitten by
-- before (see 0004's header on the nl_query REVOKE).
--
-- `guard_mutable_row` is not reused here: it also guards against
-- `workspace_id` being reassigned, a column `workspaces` does not have --
-- its own `id` *is* the tenant boundary, not a foreign key to one.
-- =============================================================================

CREATE OR REPLACE FUNCTION guard_workspace_version() RETURNS trigger AS $fn$
BEGIN
    new.version    := old.version + 1;
    new.updated_at := now();
    RETURN new;
END;
$fn$ LANGUAGE plpgsql;

CREATE TRIGGER trg_workspaces_version
    BEFORE UPDATE ON workspaces
    FOR EACH ROW EXECUTE FUNCTION guard_workspace_version();
