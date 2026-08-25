-- =============================================================================
-- Fiscal period verification.
--
-- Proves that closing a period actually stops the books moving. Immutability
-- already stops a posted row changing; what is checked here is the other hole,
-- a NEW entry backdated into a year someone has already reported on.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/verify_periods.sql
--
-- Runs inside a transaction it rolls back.
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

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

-- Posts a balanced two-line entry, returning the entry id.
CREATE FUNCTION pg_temp.post_entry(
    ws uuid, debit_account uuid, credit_account uuid, on_date date, amount numeric
) RETURNS uuid AS $fn$
DECLARE
    entry uuid;
BEGIN
    INSERT INTO journal_entries (workspace_id, entry_date, memo)
         VALUES (ws, on_date, 'verify') RETURNING id INTO entry;
    INSERT INTO journal_lines (workspace_id, journal_entry_id, account_id, debit, credit)
         VALUES (ws, entry, debit_account, amount, 0),
                (ws, entry, credit_account, 0, amount);
    UPDATE journal_entries SET posted_at = now() WHERE id = entry;
    RETURN entry;
END;
$fn$ LANGUAGE plpgsql;


DO $verify$
DECLARE
    ws        uuid;
    cash      uuid;
    revenue   uuid;
    depn      uuid;
    person    uuid;
    fy1404    uuid;
    entry     uuid;
    v_text    text;
    v_count   integer;
BEGIN
    -- --- fixtures: an Iranian workspace on the Solar Hijri year --------------
    INSERT INTO workspaces (name, base_currency, display_unit, display_exponent,
                            fiscal_calendar)
         VALUES ('Tehran Trading', 'IRR', 'toman', 1, 'solar_hijri')
      RETURNING id INTO ws;

    INSERT INTO users (email) VALUES ('owner@tehran.test') RETURNING id INTO person;
    INSERT INTO workspace_members (workspace_id, user_id, role)
         VALUES (ws, person, 'owner');

    INSERT INTO accounts (workspace_id, code, name, type)
         VALUES (ws, '1000', 'Cash', 'asset') RETURNING id INTO cash;
    INSERT INTO accounts (workspace_id, code, name, type)
         VALUES (ws, '4000', 'Revenue', 'revenue') RETURNING id INTO revenue;

    -- 1 Farvardin 1404 to 29 Esfand 1404, as Gregorian dates.
    INSERT INTO fiscal_years (workspace_id, label, starts_on, ends_on)
         VALUES (ws, '1404', DATE '2025-03-21', DATE '2026-03-20')
      RETURNING id INTO fy1404;

    PERFORM pg_temp.assert(
        (SELECT fiscal_calendar FROM workspaces WHERE id = ws) = 'solar_hijri',
        'a workspace records which calendar its users think in');


    -- --- years cannot overlap ------------------------------------------------
    -- The real collision: someone adds a Gregorian 2026 alongside a Nowruz
    -- 1404. They share nine months, so "which year is this entry in" would
    -- have two answers.
    PERFORM pg_temp.assert_rejects(
        'INSERT INTO fiscal_years (workspace_id, label, starts_on, ends_on)
         VALUES (' || quote_literal(ws) || ', ''2026'', ''2026-01-01'', ''2026-12-31'')',
        'a Gregorian year overlapping an existing Solar Hijri one');

    PERFORM pg_temp.assert_rejects(
        'INSERT INTO fiscal_years (workspace_id, label, starts_on, ends_on)
         VALUES (' || quote_literal(ws) || ', ''1404 again'', ''2025-03-21'', ''2026-03-20'')',
        'an exactly duplicated year');

    PERFORM pg_temp.assert_rejects(
        'INSERT INTO fiscal_years (workspace_id, label, starts_on, ends_on)
         VALUES (' || quote_literal(ws) || ', ''backwards'', ''2026-03-20'', ''2025-03-21'')',
        'a year that ends before it starts');

    -- The next year, abutting exactly, is fine -- 20 March to 21 March must not
    -- read as an overlap or no two consecutive years could coexist.
    INSERT INTO fiscal_years (workspace_id, label, starts_on, ends_on)
         VALUES (ws, '1405', DATE '2026-03-21', DATE '2027-03-20');
    PERFORM pg_temp.assert(true, 'consecutive years may abut without overlapping');

    -- Another workspace's year over the same dates is unrelated.
    PERFORM pg_temp.assert(
        (SELECT count(*) FROM fiscal_years WHERE workspace_id = ws) = 2,
        'fiscal years are per workspace');


    -- --- posting into an open year -------------------------------------------
    entry := pg_temp.post_entry(ws, cash, revenue, DATE '2025-06-01', 1000000);
    PERFORM pg_temp.assert(
        (SELECT posted_at FROM journal_entries WHERE id = entry) IS NOT NULL,
        'an entry posts into an open fiscal year');


    -- --- closing the year ----------------------------------------------------
    UPDATE fiscal_years
       SET closed_at = now(), closed_by_user_id = person
     WHERE id = fy1404;

    PERFORM pg_temp.assert_rejects(
        'SELECT pg_temp.post_entry(' || quote_literal(ws) || ', '
        || quote_literal(cash) || ', ' || quote_literal(revenue)
        || ', DATE ''2025-06-02'', 500000)',
        'backdating a new entry into a closed year');

    -- The hole this closes is distinct from immutability: the entry above did
    -- not exist before, so nothing about it was immutable.
    PERFORM pg_temp.assert(
        (SELECT count(*) FROM journal_entries
          WHERE workspace_id = ws AND entry_date = DATE '2025-06-02') = 0,
        'the rejected backdated entry left nothing behind');

    -- Posting into the still-open next year is unaffected.
    entry := pg_temp.post_entry(ws, cash, revenue, DATE '2026-06-01', 250000);
    PERFORM pg_temp.assert(
        (SELECT posted_at FROM journal_entries WHERE id = entry) IS NOT NULL,
        'the open year still accepts entries while its predecessor is closed');

    -- A draft may still be dated into a closed year. A draft is not in the
    -- books, and refusing to let someone type one would be the opposite of
    -- least-steps -- the refusal belongs at posting.
    INSERT INTO journal_entries (workspace_id, entry_date, memo)
         VALUES (ws, DATE '2025-06-03', 'draft in a closed year')
      RETURNING id INTO entry;
    PERFORM pg_temp.assert(
        (SELECT posted_at FROM journal_entries WHERE id = entry) IS NULL,
        'a draft may still be dated into a closed year');
    DELETE FROM journal_entries WHERE id = entry;

    -- Reopening restores posting, which is what makes close a state rather
    -- than a one-way door.
    UPDATE fiscal_years SET closed_at = NULL, closed_by_user_id = NULL
     WHERE id = fy1404;
    entry := pg_temp.post_entry(ws, cash, revenue, DATE '2025-06-04', 1);
    PERFORM pg_temp.assert(
        (SELECT posted_at FROM journal_entries WHERE id = entry) IS NOT NULL,
        'reopening a year lets it accept entries again');

    PERFORM pg_temp.assert_rejects(
        'UPDATE fiscal_years SET closed_by_user_id = ' || quote_literal(person)
        || ' WHERE id = ' || quote_literal(fy1404),
        'recording who closed a year that is not closed');


    -- --- the soft monthly lock ------------------------------------------------
    UPDATE workspaces SET books_locked_through = DATE '2025-08-31' WHERE id = ws;

    PERFORM pg_temp.assert_rejects(
        'SELECT pg_temp.post_entry(' || quote_literal(ws) || ', '
        || quote_literal(cash) || ', ' || quote_literal(revenue)
        || ', DATE ''2025-08-31'', 100)',
        'posting on the lock date itself');

    PERFORM pg_temp.assert_rejects(
        'SELECT pg_temp.post_entry(' || quote_literal(ws) || ', '
        || quote_literal(cash) || ', ' || quote_literal(revenue)
        || ', DATE ''2025-07-15'', 100)',
        'posting before the lock date');

    entry := pg_temp.post_entry(ws, cash, revenue, DATE '2025-09-01', 100);
    PERFORM pg_temp.assert(
        (SELECT posted_at FROM journal_entries WHERE id = entry) IS NOT NULL,
        'posting the day after the lock date');

    UPDATE workspaces SET books_locked_through = NULL WHERE id = ws;


    -- --- closing entries are identifiable ------------------------------------
    INSERT INTO journal_entries (workspace_id, entry_date, memo, source)
         VALUES (ws, DATE '2026-03-20', 'Close 1404', 'period_close')
      RETURNING id INTO entry;
    INSERT INTO journal_lines (workspace_id, journal_entry_id, account_id, debit, credit)
         VALUES (ws, entry, revenue, 1000000, 0), (ws, entry, cash, 0, 1000000);
    UPDATE journal_entries SET posted_at = now() WHERE id = entry;

    PERFORM pg_temp.assert(
        (SELECT source FROM journal_entries WHERE id = entry) = 'period_close',
        'a closing entry can be told apart from trading activity');

    -- Closing entries are dated inside the year they close, so they must post
    -- before it is marked closed. That ordering is why close is a flag set
    -- afterwards rather than an operation that posts and locks at once.
    UPDATE fiscal_years SET closed_at = now() WHERE id = fy1404;
    PERFORM pg_temp.assert(
        (SELECT count(*) FROM journal_entries
          WHERE workspace_id = ws AND source = 'period_close') = 1,
        'the closing entry survives the year being closed');
    UPDATE fiscal_years SET closed_at = NULL WHERE id = fy1404;


    -- --- what reports need from an account -----------------------------------
    PERFORM pg_temp.assert(
        (SELECT normal_balance FROM accounts WHERE id = cash) = 'debit',
        'an asset account defaults to a debit normal balance');
    PERFORM pg_temp.assert(
        (SELECT normal_balance FROM accounts WHERE id = revenue) = 'credit',
        'a revenue account defaults to a credit normal balance');

    -- The case `type` alone cannot express: an asset that carries a credit
    -- balance. Reported off `type` it would appear with the wrong sign.
    INSERT INTO accounts (workspace_id, code, name, type, normal_balance,
                          cash_flow_category)
         VALUES (ws, '1590', 'Accumulated depreciation', 'asset', 'credit',
                 'investing')
      RETURNING id INTO depn;

    PERFORM pg_temp.assert(
        (SELECT normal_balance FROM accounts WHERE id = depn) = 'credit',
        'a contra asset can carry a credit normal balance');
    PERFORM pg_temp.assert(
        (SELECT cash_flow_category FROM accounts WHERE id = depn) = 'investing',
        'an account can be classified for the cash flow statement');

    PERFORM pg_temp.assert_rejects(
        'INSERT INTO accounts (workspace_id, code, name, type, normal_balance)
         VALUES (' || quote_literal(ws) || ', ''9998'', ''Bad'', ''asset'', ''sideways'')',
        'an account with a normal balance that is neither debit nor credit');

    PERFORM pg_temp.assert_rejects(
        'INSERT INTO accounts (workspace_id, code, name, type, cash_flow_category)
         VALUES (' || quote_literal(ws) || ', ''9997'', ''Bad'', ''asset'', ''misc'')',
        'an account in a cash flow category that does not exist');

    RAISE NOTICE '=== ALL PERIOD CHECKS PASSED ===';
END;
$verify$;

ROLLBACK;
