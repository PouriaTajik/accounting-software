-- =============================================================================
-- Row-level security verification.
--
-- 0004 is only worth anything if the application's connection is actually
-- subject to it. A table's owner is exempt from its own policies, so the
-- failure mode this file exists to catch is policies that are present,
-- correct, and completely inert.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/verify_rls.sql
--
-- Run as the role that created accounting_app: the script grants it to itself
-- so it can SET ROLE into it, and rolls that grant back with the transaction.
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

DO $precheck$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'accounting_app') THEN
        RAISE EXCEPTION
            'role accounting_app does not exist -- apply db/roles.sql first'
            USING HINT = 'npm run db:roles';
    END IF;
END;
$precheck$;

CREATE FUNCTION pg_temp.assert_rejects(stmt text, label text) RETURNS void AS $fn$
BEGIN
    BEGIN
        EXECUTE stmt;
    EXCEPTION WHEN others THEN
        RAISE NOTICE 'PASS  % -- rejected: %', label, sqlerrm;
        RETURN;
    END;
    RAISE EXCEPTION 'FAIL  % -- the application role was ALLOWED something it must not be', label;
END;
$fn$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.assert(cond boolean, label text) RETURNS void AS $fn$
BEGIN
    IF cond THEN
        RAISE NOTICE 'PASS  %', label;
    ELSE
        RAISE EXCEPTION 'FAIL  %', label;
    END IF;
END;
$fn$ LANGUAGE plpgsql;


-- -----------------------------------------------------------------------------
-- Coverage: every tenant table is actually protected
-- -----------------------------------------------------------------------------
-- Driven off the catalog rather than a list, so a migration that adds a
-- workspace_id column and forgets its policy fails here instead of leaking.

DO $coverage$
DECLARE
    unprotected text[];
    unpolicied  text[];
BEGIN
    SELECT coalesce(array_agg(c.relname ORDER BY c.relname), '{}')
      INTO unprotected
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid
     WHERE n.nspname = 'public'
       AND c.relkind = 'r'
       AND a.attname = 'workspace_id'
       AND NOT a.attisdropped
       AND NOT c.relrowsecurity;

    PERFORM pg_temp.assert(
        unprotected = '{}',
        'every table with a workspace_id has row-level security enabled'
        || CASE WHEN unprotected = '{}' THEN ''
                ELSE ' (missing: ' || array_to_string(unprotected, ', ') || ')' END);

    SELECT coalesce(array_agg(c.relname ORDER BY c.relname), '{}')
      INTO unpolicied
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid
     WHERE n.nspname = 'public'
       AND c.relkind = 'r'
       AND a.attname = 'workspace_id'
       AND NOT a.attisdropped
       AND NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = c.oid);

    PERFORM pg_temp.assert(
        unpolicied = '{}',
        'every table with a workspace_id carries at least one policy'
        || CASE WHEN unpolicied = '{}' THEN ''
                ELSE ' (missing: ' || array_to_string(unpolicied, ', ') || ')' END);

    -- Enabling RLS with no policy denies everything, which is safe but would
    -- break the app; a policy on a table with RLS off is inert, which is
    -- worse. Both are covered above, so this asserts the pair holds together.
    PERFORM pg_temp.assert(
        (SELECT bool_and(c.relrowsecurity)
           FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = 'public'
            AND c.relname IN ('workspaces', 'users')),
        'workspaces and users are protected despite having no workspace_id');
END;
$coverage$;


-- -----------------------------------------------------------------------------
-- The role the application connects as
-- -----------------------------------------------------------------------------

DO $role$
BEGIN
    PERFORM pg_temp.assert(
        NOT (SELECT rolsuper FROM pg_roles WHERE rolname = 'accounting_app'),
        'accounting_app is not a superuser');

    -- The single attribute that would silently switch every policy off.
    PERFORM pg_temp.assert(
        NOT (SELECT rolbypassrls FROM pg_roles WHERE rolname = 'accounting_app'),
        'accounting_app does not hold BYPASSRLS');

    -- Ownership is the other exemption, and the one that is easy to acquire by
    -- accident -- create a table while connected as the app role and it owns
    -- it, policies and all.
    PERFORM pg_temp.assert(
        NOT EXISTS (
            SELECT 1 FROM pg_class c
              JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'public'
               AND c.relkind = 'r'
               AND pg_get_userbyid(c.relowner) = 'accounting_app'),
        'accounting_app owns no tables, so no table exempts it');
END;
$role$;


-- --- fixtures: two tenants with real books ------------------------------------

DO $seed$
DECLARE
    ws       uuid;
    other_ws uuid;
    person   uuid;
    cash     uuid;
    revenue  uuid;
    entry    uuid;
BEGIN
    INSERT INTO workspaces (name) VALUES ('Acme') RETURNING id INTO ws;
    INSERT INTO workspaces (name) VALUES ('Rival') RETURNING id INTO other_ws;

    INSERT INTO users (email, display_name)
         VALUES ('owner@acme.test', 'Acme Owner') RETURNING id INTO person;
    INSERT INTO workspace_members (workspace_id, user_id, role)
         VALUES (ws, person, 'owner');

    INSERT INTO users (email, display_name) VALUES ('spy@rival.test', 'Rival Owner')
         RETURNING id INTO person;
    INSERT INTO workspace_members (workspace_id, user_id, role)
         VALUES (other_ws, person, 'owner');

    INSERT INTO accounts (workspace_id, code, name, type)
         VALUES (ws, '1000', 'Cash', 'asset') RETURNING id INTO cash;
    INSERT INTO accounts (workspace_id, code, name, type)
         VALUES (ws, '4000', 'Revenue', 'revenue') RETURNING id INTO revenue;
    INSERT INTO journal_entries (workspace_id, entry_date, memo)
         VALUES (ws, DATE '2026-04-01', 'Acme sale') RETURNING id INTO entry;
    INSERT INTO journal_lines (workspace_id, journal_entry_id, account_id, debit, credit)
         VALUES (ws, entry, cash, 100, 0), (ws, entry, revenue, 0, 100);
    UPDATE journal_entries SET posted_at = now() WHERE id = entry;

    INSERT INTO accounts (workspace_id, code, name, type)
         VALUES (other_ws, '1000', 'Cash', 'asset') RETURNING id INTO cash;
    INSERT INTO accounts (workspace_id, code, name, type)
         VALUES (other_ws, '4000', 'Revenue', 'revenue') RETURNING id INTO revenue;
    INSERT INTO journal_entries (workspace_id, entry_date, memo)
         VALUES (other_ws, DATE '2026-04-02', 'Rival secret') RETURNING id INTO entry;
    INSERT INTO journal_lines (workspace_id, journal_entry_id, account_id, debit, credit)
         VALUES (other_ws, entry, cash, 999, 0), (other_ws, entry, revenue, 0, 999);
    UPDATE journal_entries SET posted_at = now() WHERE id = entry;

    PERFORM set_config('verify.ws', ws::text, false);
    PERFORM set_config('verify.other_ws', other_ws::text, false);
END;
$seed$;

-- The owner just wrote to both tenants in one statement, which is the
-- exemption 0004 relies on for migrations. Everything below runs without it.
DO $grant$
BEGIN
    EXECUTE format('GRANT accounting_app TO %I', current_user);
END;
$grant$;

SET LOCAL ROLE accounting_app;

DO $verify$
DECLARE
    ws       uuid := current_setting('verify.ws')::uuid;
    other_ws uuid := current_setting('verify.other_ws')::uuid;
    v_count  integer;
BEGIN
    -- Sanity: the role switch actually took, or everything below is vacuous.
    PERFORM pg_temp.assert(current_user = 'accounting_app',
        'the checks below run as the application role');
    PERFORM pg_temp.assert(NOT row_security_active('journal_lines') IS NULL
        AND row_security_active('journal_lines'),
        'row-level security is active for this role on journal_lines');

    -- --- unscoped means nothing, not everything ------------------------------
    PERFORM set_config('app.workspace_id', '', true);

    SELECT count(*) INTO v_count FROM journal_lines;
    PERFORM pg_temp.assert(v_count = 0,
        'an unscoped session reads no journal lines');
    SELECT count(*) INTO v_count FROM journal_entries;
    PERFORM pg_temp.assert(v_count = 0,
        'an unscoped session reads no journal entries');
    SELECT count(*) INTO v_count FROM accounts;
    PERFORM pg_temp.assert(v_count = 0,
        'an unscoped session reads no accounts');
    SELECT count(*) INTO v_count FROM workspaces;
    PERFORM pg_temp.assert(v_count = 0,
        'an unscoped session reads no workspaces');
    SELECT count(*) INTO v_count FROM users;
    PERFORM pg_temp.assert(v_count = 0,
        'an unscoped session reads no users');

    -- --- scoped sees exactly one tenant --------------------------------------
    PERFORM set_config('app.workspace_id', ws::text, true);

    SELECT count(*) INTO v_count FROM journal_lines;
    PERFORM pg_temp.assert(v_count = 2,
        'a scoped session reads its own journal lines');
    SELECT count(*) INTO v_count FROM journal_lines WHERE debit = 999 OR credit = 999;
    PERFORM pg_temp.assert(v_count = 0,
        'a scoped session cannot read the other tenant''s lines');
    SELECT count(*) INTO v_count FROM journal_entries WHERE memo = 'Rival secret';
    PERFORM pg_temp.assert(v_count = 0,
        'a scoped session cannot read the other tenant''s entries');
    SELECT count(*) INTO v_count FROM workspaces;
    PERFORM pg_temp.assert(v_count = 1,
        'a scoped session sees exactly one workspace');

    -- This is the check a forgotten WHERE clause would fail. The query asks
    -- for everything, deliberately, and still gets one tenant.
    SELECT count(DISTINCT workspace_id) INTO v_count FROM journal_lines;
    PERFORM pg_temp.assert(v_count = 1,
        'a query with no WHERE clause still spans exactly one tenant');

    -- --- users are scoped by shared membership -------------------------------
    SELECT count(*) INTO v_count FROM users;
    PERFORM pg_temp.assert(v_count = 1,
        'only co-members of the scoped workspace are visible');
    SELECT count(*) INTO v_count FROM users WHERE email = 'spy@rival.test';
    PERFORM pg_temp.assert(v_count = 0,
        'the other tenant''s users cannot be enumerated');

    -- --- writes cannot cross the boundary ------------------------------------
    -- WITH CHECK, not USING: the row does not exist yet, so visibility is not
    -- what stops this.
    PERFORM pg_temp.assert_rejects(
        'INSERT INTO accounts (workspace_id, code, name, type)
         VALUES (' || quote_literal(other_ws) || ', ''9999'', ''Planted'', ''asset'')',
        'inserting a row into another tenant');

    PERFORM pg_temp.assert_rejects(
        'UPDATE accounts SET workspace_id = ' || quote_literal(other_ws)
        || ' WHERE code = ''1000''',
        'moving one of its own rows into another tenant');

    -- An UPDATE aimed at the other tenant is not an error -- the rows are
    -- simply invisible, so it matches nothing. Silence is the correct
    -- behaviour, and worth pinning down.
    UPDATE journal_entries SET memo = 'tampered' WHERE memo = 'Rival secret';
    PERFORM pg_temp.assert(
        NOT FOUND,
        'an update aimed at another tenant matches no rows');

    DELETE FROM accounts WHERE workspace_id = other_ws;
    PERFORM pg_temp.assert(
        NOT FOUND,
        'a delete aimed at another tenant matches no rows');

    -- --- things the application has no business touching ---------------------
    PERFORM pg_temp.assert_rejects(
        'SELECT * FROM schema_migrations',
        'reading migration bookkeeping');
    PERFORM pg_temp.assert_rejects(
        'INSERT INTO currencies (code, name, minor_unit) VALUES (''GBP'', ''Pound'', 2)',
        'writing to reference data');
    PERFORM pg_temp.assert_rejects(
        'SELECT * FROM ledger_query.journal_lines',
        'reading through the NL-query projection');

    SELECT count(*) INTO v_count FROM currencies;
    PERFORM pg_temp.assert(v_count >= 5,
        'reference data is still readable');

    -- --- the ledger invariants still apply under RLS -------------------------
    -- RLS filters rows; it must not have quietly displaced the triggers.
    PERFORM pg_temp.assert_rejects(
        'UPDATE journal_entries SET memo = ''edited'' WHERE memo = ''Acme sale''',
        'editing a posted entry it CAN see');

    RAISE NOTICE '=== ALL RLS CHECKS PASSED ===';
END;
$verify$;

RESET ROLE;

ROLLBACK;
