-- =============================================================================
-- Role hardening verification.
--
-- roles.sql claims the natural-language query role cannot reach the ledger.
-- This proves it, so the claim is a test rather than a comment. Runs inside a
-- transaction that is rolled back, so it is safe against a live database
-- (a scratch one is still the sane choice).
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/schema.sql
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--        -v nl_query_password="'<secret>'" -f db/roles.sql
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/verify_roles.sql
--
-- Run as the role that created nl_query: the script grants nl_query to itself
-- so it can SET ROLE into it, and rolls that grant back at the end.
--
-- SCOPE -- what this file can and cannot cover:
--
--   Covered: the privilege layer. No rights on base tables, SELECT only
--   through the ledger_query views, workspace scoping, no write path. This is
--   the layer that actually holds, so it is the layer worth testing.
--
--   NOT covered: the per-role GUCs (default_transaction_read_only,
--   statement_timeout, idle_in_transaction_session_timeout). `ALTER ROLE ...
--   SET` applies at login, and SET ROLE does not trigger it, so they cannot be
--   observed from inside one session. They are also USERSET parameters the
--   role can simply turn off -- see the comments in roles.sql. Exercising them
--   needs a real login as nl_query; db/README.md carries that snippet.
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- Fail with something actionable rather than "role does not exist" if roles.sql
-- was never applied -- the common case, since Compose auto-applies schema.sql
-- on first boot but not roles.sql.
DO $precheck$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nl_query') THEN
        RAISE EXCEPTION
            'role nl_query does not exist -- apply db/roles.sql before this script'
            USING HINT = 'psql "$DATABASE_URL" -v nl_query_password="''<secret>''" -f db/roles.sql';
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
    RAISE EXCEPTION 'FAIL  % -- nl_query was ALLOWED something it must not be', label;
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


-- --- fixtures: two tenants, each with a posted entry --------------------------

DO $seed$
DECLARE
    ws       uuid;
    other_ws uuid;
    cash     uuid;
    revenue  uuid;
    entry    uuid;
BEGIN
    INSERT INTO workspaces (name) VALUES ('Roles Co') RETURNING id INTO ws;
    INSERT INTO workspaces (name) VALUES ('Other Co') RETURNING id INTO other_ws;

    INSERT INTO accounts (workspace_id, code, name, type)
         VALUES (ws, '1000', 'Cash', 'asset') RETURNING id INTO cash;
    INSERT INTO accounts (workspace_id, code, name, type)
         VALUES (ws, '4000', 'Revenue', 'revenue') RETURNING id INTO revenue;

    INSERT INTO journal_entries (workspace_id, entry_date, memo)
         VALUES (ws, DATE '2026-01-15', 'Sale') RETURNING id INTO entry;
    INSERT INTO journal_lines (workspace_id, journal_entry_id, account_id, debit, credit)
         VALUES (ws, entry, cash, 100, 0), (ws, entry, revenue, 0, 100);
    UPDATE journal_entries SET posted_at = now() WHERE id = entry;

    -- The other tenant gets a posted entry too, so "scoped" means "excluded
    -- this specific other row" rather than "there was nothing to leak".
    INSERT INTO accounts (workspace_id, code, name, type)
         VALUES (other_ws, '1000', 'Cash', 'asset') RETURNING id INTO cash;
    INSERT INTO accounts (workspace_id, code, name, type)
         VALUES (other_ws, '4000', 'Revenue', 'revenue') RETURNING id INTO revenue;
    INSERT INTO journal_entries (workspace_id, entry_date, memo)
         VALUES (other_ws, DATE '2026-01-16', 'Other tenant sale') RETURNING id INTO entry;
    INSERT INTO journal_lines (workspace_id, journal_entry_id, account_id, debit, credit)
         VALUES (other_ws, entry, cash, 250, 0), (other_ws, entry, revenue, 0, 250);
    UPDATE journal_entries SET posted_at = now() WHERE id = entry;

    PERFORM set_config('verify.ws', ws::text, false);
    PERFORM set_config('verify.other_ws', other_ws::text, false);
END;
$seed$;


-- --- grants that outlive the role switch --------------------------------------
-- Rolled back with the transaction.
DO $grant$
BEGIN
    EXECUTE format('GRANT nl_query TO %I', current_user);
END;
$grant$;


-- --- checks that must run with nl_query's privileges --------------------------

SET LOCAL ROLE nl_query;

-- `ALTER ROLE nl_query SET search_path = ledger_query` in roles.sql applies at
-- login, which SET ROLE does not trigger, so set it by hand to reproduce the
-- state a real nl_query session starts in. This is emulated, not observed:
-- the login-time value is asserted separately below, off pg_roles.
SET LOCAL search_path = ledger_query;

DO $verify$
DECLARE
    ws        uuid := current_setting('verify.ws')::uuid;
    other_ws  uuid := current_setting('verify.other_ws')::uuid;
    v_count   integer;
BEGIN
    -- 1. The base tables are unreachable, by every name they have.
    PERFORM pg_temp.assert_rejects(
        'SELECT * FROM public.journal_lines',
        'nl_query reading the journal_lines base table');
    PERFORM pg_temp.assert_rejects(
        'SELECT * FROM public.journal_entries',
        'nl_query reading the journal_entries base table');
    PERFORM pg_temp.assert_rejects(
        'SELECT * FROM public.accounts',
        'nl_query reading the accounts base table');
    PERFORM pg_temp.assert_rejects(
        'SELECT * FROM public.workspace_ai_config',
        'nl_query reading stored AI credentials');
    PERFORM pg_temp.assert_rejects(
        'SELECT * FROM public.documents',
        'nl_query reading the documents base table');

    -- 2. It holds no privilege on them either -- not merely blocked by
    --    search_path, actually ungranted.
    SELECT count(*) INTO v_count
      FROM information_schema.table_privileges
     WHERE grantee = 'nl_query' AND table_schema = 'public';
    PERFORM pg_temp.assert(v_count = 0,
        'nl_query holds zero table privileges in schema public');

    -- 3. And it cannot reach schema public at all, so a future careless
    --    `GRANT ... TO PUBLIC` does not silently open a door.
    PERFORM pg_temp.assert(
        NOT has_schema_privilege('nl_query', 'public', 'USAGE'),
        'nl_query holds no USAGE on schema public');

    -- 4. The projection is readable -- ownership chaining works.
    PERFORM set_config('app.workspace_id', ws::text, true);
    SELECT count(*) INTO v_count FROM ledger_query.journal_lines;
    PERFORM pg_temp.assert(v_count = 2,
        'nl_query reads its scoped workspace through ledger_query');

    -- 5. An unqualified name resolves to the view, not the base table,
    --    because search_path is pinned to ledger_query.
    SELECT count(*) INTO v_count FROM journal_lines;
    PERFORM pg_temp.assert(v_count = 2,
        'an unqualified journal_lines resolves to the scoped view');

    -- 6. Scoping excludes the other tenant rather than returning everything.
    --    The views deliberately do not project workspace_id -- the tenant key
    --    is not part of the surface handed to generated SQL -- so the other
    --    tenant is identified here by its distinctive amount and memo.
    SELECT count(*) INTO v_count FROM ledger_query.journal_lines
     WHERE debit = 250 OR credit = 250;
    PERFORM pg_temp.assert(v_count = 0,
        'ledger_query leaks no journal lines from another tenant');

    SELECT count(*) INTO v_count FROM ledger_query.journal_entries
     WHERE memo = 'Other tenant sale';
    PERFORM pg_temp.assert(v_count = 0,
        'ledger_query leaks no journal entries from another tenant');

    -- 7. Unscoped means empty, not unfiltered. This is the one that matters:
    --    a generated query on a session nobody scoped must see nothing.
    PERFORM set_config('app.workspace_id', '', true);
    SELECT count(*) INTO v_count FROM ledger_query.journal_lines;
    PERFORM pg_temp.assert(v_count = 0,
        'ledger_query exposes nothing when app.workspace_id is unset');

    SELECT count(*) INTO v_count FROM ledger_query.journal_entries;
    PERFORM pg_temp.assert(v_count = 0,
        'ledger_query.journal_entries is empty when unscoped');
    SELECT count(*) INTO v_count FROM ledger_query.accounts;
    PERFORM pg_temp.assert(v_count = 0,
        'ledger_query.accounts is empty when unscoped');

    -- 8. No write path exists, scoped or not.
    PERFORM set_config('app.workspace_id', ws::text, true);
    --    journal_lines/journal_entries are multi-table views and so are not
    --    auto-updatable; accounts is a single-table view and IS auto-updatable,
    --    so it exercises the privilege check rather than the view shape. Both
    --    paths are covered deliberately -- these statements use each view's
    --    real column names, so a rejection means "refused", not "typo".
    PERFORM pg_temp.assert_rejects(
        'DELETE FROM ledger_query.journal_lines',
        'nl_query deleting through a multi-table projection');
    PERFORM pg_temp.assert_rejects(
        'UPDATE ledger_query.journal_entries SET memo = ''tampered''',
        'nl_query updating through a multi-table projection');
    PERFORM pg_temp.assert_rejects(
        'DELETE FROM ledger_query.accounts',
        'nl_query deleting through an auto-updatable projection');
    PERFORM pg_temp.assert_rejects(
        'UPDATE ledger_query.accounts SET account_name = ''tampered''',
        'nl_query updating through an auto-updatable projection');
    PERFORM pg_temp.assert_rejects(
        'INSERT INTO ledger_query.accounts (account_code, account_name, account_type)
         VALUES (''9999'', ''Injected'', ''asset'')',
        'nl_query inserting through an auto-updatable projection');
    PERFORM pg_temp.assert_rejects(
        'CREATE TABLE public.exfiltrated (x int)',
        'nl_query creating a table in public');

    -- 9. The login-time settings are configured as roles.sql intends. This
    --    asserts the stored configuration, NOT that it is enforceable -- the
    --    role can override all four at runtime (see roles.sql). It catches
    --    roles.sql never having been run, or drift after a manual ALTER ROLE.
    PERFORM pg_temp.assert(
        (SELECT rolconfig FROM pg_roles WHERE rolname = 'nl_query')
            @> ARRAY['search_path=ledger_query'],
        'nl_query logs in with search_path pinned to ledger_query');
    PERFORM pg_temp.assert(
        (SELECT rolconfig FROM pg_roles WHERE rolname = 'nl_query')
            @> ARRAY['default_transaction_read_only=on'],
        'nl_query logs in read-only by default');
    PERFORM pg_temp.assert(
        (SELECT rolconfig FROM pg_roles WHERE rolname = 'nl_query')
            @> ARRAY['statement_timeout=10s'],
        'nl_query logs in with a statement timeout');
    PERFORM pg_temp.assert(
        (SELECT rolconfig FROM pg_roles WHERE rolname = 'nl_query')
            @> ARRAY['idle_in_transaction_session_timeout=30s'],
        'nl_query logs in with an idle-in-transaction timeout');

    RAISE NOTICE '=== ALL ROLE CHECKS PASSED ===';
END;
$verify$;

RESET ROLE;

ROLLBACK;
