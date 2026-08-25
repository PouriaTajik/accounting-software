-- =============================================================================
-- Currency model verification.
--
-- Proves the decisions in 0002_currency.sql are enforced rather than intended:
-- toman is a display unit and not a currency, base-currency lines cannot carry
-- an exchange rate, and the Level 0 gate actually holds.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/verify_currency.sql
--
-- Runs inside a transaction it rolls back. Exit 0 and a final
-- "ALL CURRENCY CHECKS PASSED" notice means the model holds.
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


DO $verify$
DECLARE
    ir_ws     uuid;
    usd_ws    uuid;
    cash      uuid;
    revenue   uuid;
    entry     uuid;
    v_line    journal_lines%ROWTYPE;
    v_toman   numeric;
    v_rial    numeric;
    v_text    text;
BEGIN
    -- --- fixtures ------------------------------------------------------------
    -- An Iranian workspace: books in rial, screen in toman.
    INSERT INTO workspaces (name, base_currency, display_unit, display_exponent)
         VALUES ('Tehran Trading', 'IRR', 'toman', 1) RETURNING id INTO ir_ws;
    INSERT INTO workspaces (name, base_currency)
         VALUES ('US Co', 'USD') RETURNING id INTO usd_ws;

    INSERT INTO accounts (workspace_id, code, name, type)
         VALUES (ir_ws, '1000', 'Cash', 'asset') RETURNING id INTO cash;
    INSERT INTO accounts (workspace_id, code, name, type)
         VALUES (ir_ws, '4000', 'Revenue', 'revenue') RETURNING id INTO revenue;


    -- --- toman is a display unit, not a currency -----------------------------

    -- The trap this product will actually walk into: a developer adds IRT
    -- because a user asked for toman. The refusal names the reason.
    PERFORM pg_temp.assert_rejects(
        'INSERT INTO currencies (code, name, minor_unit) VALUES (''IRT'', ''Toman'', 0)',
        'adding toman to the currency table');

    PERFORM pg_temp.assert_rejects(
        'UPDATE workspaces SET base_currency = ''IRT'' WHERE id = ' || quote_literal(ir_ws),
        'keeping books in a toman "currency"');

    PERFORM pg_temp.assert_rejects(
        'UPDATE workspaces SET base_currency = ''XYZ'' WHERE id = ' || quote_literal(ir_ws),
        'a base currency that is not a known ISO code');

    -- The exactness claim the whole design rests on: rial is the smaller unit,
    -- so display conversion is lossless in both directions at any magnitude.
    v_toman := 12345678.0;
    v_rial  := v_toman * power(10::numeric, 1);
    PERFORM pg_temp.assert(
        v_rial = 123456780 AND v_rial / power(10::numeric, 1) = v_toman,
        'toman <-> rial conversion is exact in both directions');

    -- A display shift with nothing to call it would render ambiguous amounts.
    PERFORM pg_temp.assert_rejects(
        'INSERT INTO workspaces (name, base_currency, display_exponent)
         VALUES (''Nameless'', ''IRR'', 1)',
        'a display shift with no unit name');


    -- --- rial magnitudes fit -------------------------------------------------

    INSERT INTO journal_entries (workspace_id, entry_date, memo)
         VALUES (ir_ws, DATE '2026-03-01', 'Large invoice') RETURNING id INTO entry;

    -- 500 billion toman = 5 trillion rial. numeric(18,2) would have coped, but
    -- only just; this is the headroom the widening bought.
    INSERT INTO journal_lines (workspace_id, journal_entry_id, account_id, debit, credit)
         VALUES (ir_ws, entry, cash, 5000000000000, 0),
                (ir_ws, entry, revenue, 0, 5000000000000);

    SELECT sum(debit) INTO v_rial FROM journal_lines WHERE journal_entry_id = entry;
    PERFORM pg_temp.assert(v_rial = 5000000000000,
        'a five-trillion-rial line stores without loss');

    UPDATE journal_entries SET posted_at = now() WHERE id = entry;
    PERFORM pg_temp.assert(
        (SELECT posted_at FROM journal_entries WHERE id = entry) IS NOT NULL,
        'a rial-denominated entry posts and balances');


    -- --- the defaults trigger ------------------------------------------------
    -- The point of the trigger: an INSERT written before 0002 still works, and
    -- gets a correct, complete currency record without naming any of it.

    INSERT INTO journal_entries (workspace_id, entry_date, memo)
         VALUES (ir_ws, DATE '2026-03-02', 'Defaults') RETURNING id INTO entry;
    INSERT INTO journal_lines (workspace_id, journal_entry_id, account_id, debit, credit)
         VALUES (ir_ws, entry, cash, 250000, 0);

    SELECT * INTO v_line FROM journal_lines
     WHERE journal_entry_id = entry AND debit = 250000;

    PERFORM pg_temp.assert(v_line.base_currency = 'IRR',
        'base_currency is filled from the workspace, not the caller');
    PERFORM pg_temp.assert(v_line.currency = 'IRR',
        'currency defaults to the base currency');
    PERFORM pg_temp.assert(v_line.fx_rate = 1,
        'a base-currency line gets an identity rate');
    PERFORM pg_temp.assert(
        v_line.original_debit = 250000 AND v_line.original_credit = 0,
        'original amounts mirror the base amounts, on the correct side');


    -- --- tenancy and drift ---------------------------------------------------

    PERFORM pg_temp.assert_rejects(
        'INSERT INTO journal_lines
             (workspace_id, journal_entry_id, account_id, debit, credit, base_currency)
         VALUES (' || quote_literal(ir_ws) || ', ' || quote_literal(entry) || ', '
         || quote_literal(cash) || ', 10, 0, ''USD'')',
        'a line claiming a base currency its workspace does not use');

    -- Re-denominating books that already have lines is not an UPDATE.
    PERFORM pg_temp.assert_rejects(
        'UPDATE workspaces SET base_currency = ''USD'' WHERE id = ' || quote_literal(ir_ws),
        'changing base currency once the ledger has lines');

    -- But a workspace with no lines yet is free to choose.
    UPDATE workspaces SET base_currency = 'EUR' WHERE id = usd_ws;
    PERFORM pg_temp.assert(
        (SELECT base_currency FROM workspaces WHERE id = usd_ws) = 'EUR',
        'a workspace with no lines can still change its base currency');


    -- --- the Level 0 gate ----------------------------------------------------

    PERFORM pg_temp.assert_rejects(
        'INSERT INTO journal_lines
             (workspace_id, journal_entry_id, account_id, debit, credit,
              currency, original_debit, original_credit, fx_rate)
         VALUES (' || quote_literal(ir_ws) || ', ' || quote_literal(entry) || ', '
         || quote_literal(cash) || ', 600000000, 0, ''USD'', 1000, 0, 600000)',
        'a foreign-currency line while the Level 0 gate stands');

    PERFORM pg_temp.assert(
        EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'journal_lines_single_currency_until_l1'),
        'the Level 0 gate is a named constraint, droppable in one statement');

    -- Everything behind the gate is ready. Drop it exactly as the L1 migration
    -- will, confirm a foreign-currency line then records correctly, and let the
    -- rollback put it back.
    ALTER TABLE journal_lines DROP CONSTRAINT journal_lines_single_currency_until_l1;

    INSERT INTO journal_lines
        (workspace_id, journal_entry_id, account_id, debit, credit,
         currency, original_debit, original_credit, fx_rate, fx_rate_source)
    VALUES (ir_ws, entry, cash, 600000000, 0, 'USD', 1000, 0, 600000, 'free_market');

    SELECT * INTO v_line FROM journal_lines
     WHERE journal_entry_id = entry AND currency = 'USD';
    PERFORM pg_temp.assert(
        v_line.debit = v_line.original_debit * v_line.fx_rate,
        'a foreign-currency line converts to base at the recorded rate');
    PERFORM pg_temp.assert(v_line.base_currency = 'IRR',
        'a foreign-currency line still reports in the workspace base currency');
    PERFORM pg_temp.assert(v_line.fx_rate_source = 'free_market',
        'which of Iran''s several rates was used is recorded on the line');

    -- The constraints that must survive into L1.
    PERFORM pg_temp.assert_rejects(
        'INSERT INTO journal_lines
             (workspace_id, journal_entry_id, account_id, debit, credit,
              currency, original_debit, original_credit, fx_rate)
         VALUES (' || quote_literal(ir_ws) || ', ' || quote_literal(entry) || ', '
         || quote_literal(cash) || ', 100, 0, ''USD'', 1000, 0, 0)',
        'a foreign-currency line with a zero exchange rate');

    PERFORM pg_temp.assert_rejects(
        'INSERT INTO journal_lines
             (workspace_id, journal_entry_id, account_id, debit, credit,
              currency, original_debit, original_credit, fx_rate)
         VALUES (' || quote_literal(ir_ws) || ', ' || quote_literal(entry) || ', '
         || quote_literal(cash) || ', 100, 0, ''USD'', 0, 50, 2)',
        'an original amount on the opposite side from the base amount');

    PERFORM pg_temp.assert_rejects(
        'INSERT INTO journal_lines
             (workspace_id, journal_entry_id, account_id, debit, credit,
              currency, original_debit, original_credit, fx_rate)
         VALUES (' || quote_literal(ir_ws) || ', ' || quote_literal(entry) || ', '
         || quote_literal(cash) || ', 100, 0, ''JPY'', 100, 0, 1)',
        'a currency outside the supported set');

    RAISE NOTICE '=== ALL CURRENCY CHECKS PASSED ===';
END;
$verify$;

ROLLBACK;
