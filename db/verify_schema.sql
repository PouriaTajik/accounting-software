-- =============================================================================
-- Schema verification.
--
-- Proves that the ledger invariants in schema.sql are actually enforced by the
-- database, not just described in its comments. Everything runs inside a
-- transaction that is rolled back at the end, so it is safe against a live
-- database (though a scratch one is still the sane choice).
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/schema.sql
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/verify_schema.sql
--
-- Exit code 0 and a final "ALL CHECKS PASSED" notice means the invariants
-- hold. Any failure aborts with a FAIL message naming the check.
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- Asserts that `stmt` is rejected by the database.
CREATE FUNCTION pg_temp.assert_rejects(stmt text, label text) RETURNS void AS $fn$
BEGIN
    BEGIN
        EXECUTE stmt;
    EXCEPTION WHEN others THEN
        RAISE NOTICE 'PASS  % -- rejected: %', label, sqlerrm;
        RETURN;
    END;
    RAISE EXCEPTION 'FAIL  % -- the database ACCEPTED a statement it should have rejected', label;
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


DO $verify$
DECLARE
    ws           uuid;
    other_ws     uuid;
    cash         uuid;
    supplies     uuid;
    other_cash   uuid;
    draft        uuid;
    posted       uuid;
    line_id      uuid;
    v_version    integer;
    v_count      integer;
BEGIN
    -- --- fixtures ------------------------------------------------------------
    INSERT INTO workspaces (name) VALUES ('Verify Co')  RETURNING id INTO ws;
    INSERT INTO workspaces (name) VALUES ('Other Co')   RETURNING id INTO other_ws;

    INSERT INTO accounts (workspace_id, code, name, type)
        VALUES (ws, '1000', 'Cash', 'asset') RETURNING id INTO cash;
    INSERT INTO accounts (workspace_id, code, name, type)
        VALUES (ws, '5000', 'Office Supplies', 'expense') RETURNING id INTO supplies;
    INSERT INTO accounts (workspace_id, code, name, type)
        VALUES (other_ws, '1000', 'Cash', 'asset') RETURNING id INTO other_cash;

    -- --- 1. line shape -------------------------------------------------------
    INSERT INTO journal_entries (workspace_id, entry_date, memo)
        VALUES (ws, current_date, 'shape checks') RETURNING id INTO draft;

    PERFORM pg_temp.assert_rejects(format(
        $s$INSERT INTO journal_lines (workspace_id, journal_entry_id, account_id, debit, credit)
           VALUES ('%s','%s','%s', 0, 0)$s$, ws, draft, cash),
        'a line that is zero on both sides');

    PERFORM pg_temp.assert_rejects(format(
        $s$INSERT INTO journal_lines (workspace_id, journal_entry_id, account_id, debit, credit)
           VALUES ('%s','%s','%s', 50, 50)$s$, ws, draft, cash),
        'a line carrying both a debit and a credit');

    PERFORM pg_temp.assert_rejects(format(
        $s$INSERT INTO journal_lines (workspace_id, journal_entry_id, account_id, debit, credit)
           VALUES ('%s','%s','%s', -50, 0)$s$, ws, draft, cash),
        'a line with a negative amount');

    -- --- 2. cross-tenant references ------------------------------------------
    PERFORM pg_temp.assert_rejects(format(
        $s$INSERT INTO journal_lines (workspace_id, journal_entry_id, account_id, debit, credit)
           VALUES ('%s','%s','%s', 10, 0)$s$, ws, draft, other_cash),
        'a line pointing at another workspace''s account');

    PERFORM pg_temp.assert_rejects(format(
        $s$INSERT INTO accounts (workspace_id, code, name, type, parent_account_id)
           VALUES ('%s','9999','Bad Child','asset','%s')$s$, ws, other_cash),
        'an account parented to another workspace''s account');

    -- --- 3. posting rules ----------------------------------------------------
    -- Unbalanced: 100 debit, 60 credit.
    INSERT INTO journal_lines (workspace_id, journal_entry_id, account_id, debit, credit)
        VALUES (ws, draft, supplies, 100, 0);
    INSERT INTO journal_lines (workspace_id, journal_entry_id, account_id, debit, credit)
        VALUES (ws, draft, cash, 0, 60);

    PERFORM pg_temp.assert_rejects(format(
        $s$UPDATE journal_entries SET posted_at = now() WHERE id = '%s'$s$, draft),
        'posting an unbalanced entry');

    -- A single-line entry cannot post either.
    DELETE FROM journal_lines WHERE journal_entry_id = draft;
    INSERT INTO journal_lines (workspace_id, journal_entry_id, account_id, debit, credit)
        VALUES (ws, draft, supplies, 100, 0);

    PERFORM pg_temp.assert_rejects(format(
        $s$UPDATE journal_entries SET posted_at = now() WHERE id = '%s'$s$, draft),
        'posting a one-sided (single-line) entry');

    -- Posting must be a transition, or the balance check above is bypassable
    -- by inserting a row that is born posted (and therefore lineless).
    PERFORM pg_temp.assert_rejects(format(
        $s$INSERT INTO journal_entries (workspace_id, entry_date, posted_at)
           VALUES ('%s', current_date, now())$s$, ws),
        'inserting an entry that is already posted');

    -- --- 4. draft version bump ------------------------------------------------
    SELECT version INTO v_version FROM journal_entries WHERE id = draft;
    UPDATE journal_entries SET memo = 'edited' WHERE id = draft;
    PERFORM pg_temp.assert(
        (SELECT version FROM journal_entries WHERE id = draft) = v_version + 1,
        'editing a draft bumps its version automatically');

    -- workspaces carried a `version` column since 0001 with no trigger to
    -- bump it until 0006 -- an UPDATE against a stale version matched
    -- anyway, so two concurrent writers could each believe they held the
    -- current version and neither would see a 409.
    SELECT version INTO v_version FROM workspaces WHERE id = ws;
    UPDATE workspaces SET name = 'Verify Co Renamed' WHERE id = ws;
    PERFORM pg_temp.assert(
        (SELECT version FROM workspaces WHERE id = ws) = v_version + 1,
        'editing a workspace bumps its version automatically');

    PERFORM pg_temp.assert_rejects(format(
        $s$UPDATE journal_entries SET workspace_id = '%s' WHERE id = '%s'$s$, other_ws, draft),
        'moving a draft entry to another workspace');

    -- --- 5. a balanced entry posts -------------------------------------------
    INSERT INTO journal_entries (workspace_id, entry_date, memo)
        VALUES (ws, current_date, 'office chairs') RETURNING id INTO posted;
    INSERT INTO journal_lines (workspace_id, journal_entry_id, account_id, debit, credit)
        VALUES (ws, posted, supplies, 250, 0) RETURNING id INTO line_id;
    INSERT INTO journal_lines (workspace_id, journal_entry_id, account_id, debit, credit)
        VALUES (ws, posted, cash, 0, 250);

    UPDATE journal_entries SET posted_at = now() WHERE id = posted;
    PERFORM pg_temp.assert(
        (SELECT posted_at IS NOT NULL FROM journal_entries WHERE id = posted),
        'a balanced two-sided entry posts');

    -- --- 6. posted rows are frozen -------------------------------------------
    PERFORM pg_temp.assert_rejects(format(
        $s$UPDATE journal_entries SET memo = 'tampered' WHERE id = '%s'$s$, posted),
        'editing the memo of a posted entry');

    PERFORM pg_temp.assert_rejects(format(
        $s$UPDATE journal_entries SET posted_at = NULL WHERE id = '%s'$s$, posted),
        'un-posting a posted entry');

    PERFORM pg_temp.assert_rejects(format(
        $s$DELETE FROM journal_entries WHERE id = '%s'$s$, posted),
        'deleting a posted entry');

    -- The important one: the lines of a posted entry carry its amounts.
    PERFORM pg_temp.assert_rejects(format(
        $s$UPDATE journal_lines SET debit = 9999 WHERE id = '%s'$s$, line_id),
        'changing the amount on a posted entry''s line');

    PERFORM pg_temp.assert_rejects(format(
        $s$DELETE FROM journal_lines WHERE id = '%s'$s$, line_id),
        'deleting a posted entry''s line');

    PERFORM pg_temp.assert_rejects(format(
        $s$INSERT INTO journal_lines (workspace_id, journal_entry_id, account_id, debit, credit)
           VALUES ('%s','%s','%s', 1, 0)$s$, ws, posted, cash),
        'adding a new line to a posted entry');

    -- --- 7. corrections are reversing entries --------------------------------
    PERFORM pg_temp.assert_rejects(format(
        $s$INSERT INTO journal_entries (workspace_id, entry_date, reverses_entry_id, source)
           VALUES ('%s', current_date, '%s', 'manual')$s$, ws, posted),
        'a reversal not marked with source = reversal');

    INSERT INTO journal_entries (workspace_id, entry_date, memo, source, reverses_entry_id)
        VALUES (ws, current_date, 'reverses office chairs', 'reversal', posted);
    PERFORM pg_temp.assert(true, 'a correction can be recorded as a reversing entry');

    PERFORM pg_temp.assert_rejects(format(
        $s$INSERT INTO journal_entries (workspace_id, entry_date, source, reverses_entry_id)
           VALUES ('%s', current_date, 'reversal', '%s')$s$, ws, posted),
        'reversing the same entry twice');

    -- --- 8. drafts still delete cleanly (lines cascade) ----------------------
    DELETE FROM journal_entries WHERE id = draft;
    PERFORM pg_temp.assert(
        NOT EXISTS (SELECT 1 FROM journal_lines WHERE journal_entry_id = draft),
        'deleting a draft cascades to its lines');

    -- --- 9. NL-query views are tenant-scoped by construction ------------------
    PERFORM set_config('app.workspace_id', '', true);
    SELECT count(*) INTO v_count FROM ledger_query.journal_lines;
    PERFORM pg_temp.assert(v_count = 0,
        'ledger_query views expose nothing when app.workspace_id is unset');

    PERFORM set_config('app.workspace_id', other_ws::text, true);
    SELECT count(*) INTO v_count FROM ledger_query.journal_lines;
    PERFORM pg_temp.assert(v_count = 0,
        'ledger_query views expose nothing from another tenant');

    PERFORM set_config('app.workspace_id', ws::text, true);
    SELECT count(*) INTO v_count FROM ledger_query.journal_lines;
    PERFORM pg_temp.assert(v_count = 2,
        'ledger_query views expose exactly the scoped workspace');

    -- --- 10. break-glass purge path ------------------------------------------
    PERFORM set_config('app.ledger_purge', 'on', true);
    DELETE FROM journal_entries WHERE workspace_id = ws AND reverses_entry_id IS NOT NULL;
    DELETE FROM journal_entries WHERE id = posted;
    PERFORM pg_temp.assert(
        NOT EXISTS (SELECT 1 FROM journal_entries WHERE id = posted),
        'tenant offboarding can purge posted rows behind the explicit flag');
    PERFORM set_config('app.ledger_purge', 'off', true);

    RAISE NOTICE '=== ALL CHECKS PASSED ===';
END;
$verify$;

ROLLBACK;
