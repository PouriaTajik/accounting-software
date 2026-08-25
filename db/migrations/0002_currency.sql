-- =============================================================================
-- 0002 -- currency: unit of account, display units, and foreign-currency slots.
--
-- Ships LEVEL 0 behaviour (one currency per workspace) with LEVEL 1's columns
-- already in place (foreign-currency transactions recorded against a single
-- reporting currency). The gate between them is one named constraint at the
-- bottom of this file, dropped by a later migration when the application side
-- -- rate entry, FX gain/loss accounts -- actually exists.
--
-- Why the columns land now rather than when L1 ships: posted journal lines are
-- immutable by trigger. Adding a NOT NULL column to them later means either
-- disabling that trigger to rewrite every posted row, or a nullable column
-- forever with COALESCE smeared through every report. Note that even here,
-- with the ledger essentially empty, the backfill below already has to switch
-- the immutability trigger off. That cost only grows.
--
-- ---------------------------------------------------------------------------
-- TOMAN IS NOT A CURRENCY. It is a display unit.
--
-- IRR is the ISO 4217 code. Toman has none ("IRT" is an unofficial
-- abbreviation), and 1 toman is 10 rial exactly, always -- a fixed
-- denomination like dollars-to-cents, not an exchange rate. Modelling it as a
-- second currency would put a pair that can never fluctuate through the FX
-- machinery: rounding on a relationship that must never round, and a balance
-- sheet able to show FX gain/loss between rial and toman, which is nonsense.
--
-- So the ledger stores rial, and toman is presentation:
-- `workspaces.display_unit` names it, `display_exponent` shifts it. Rial is
-- the smaller unit, so rial -> toman is exact in both directions; storing
-- toman would lose the odd rial. A future redenomination changes the exponent,
-- not the schema.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- The currencies a workspace may keep its books in
-- -----------------------------------------------------------------------------

-- Deliberately NOT workspace-scoped, which is the one documented exception to
-- "workspace_id on every table": ISO 4217 is the same list for every tenant,
-- and a per-tenant copy would let two workspaces disagree about what USD is.
-- Nothing here is tenant data.
CREATE TABLE currencies (
    code        char(3) PRIMARY KEY,
    name        text     NOT NULL CHECK (length(trim(name)) > 0),
    -- ISO 4217 minor units: the decimal places the currency actually has.
    -- Amount columns carry more scale than this so intermediate FX conversion
    -- does not round early; rounding to minor_unit is a presentation and
    -- posting-time concern, not a storage one.
    minor_unit  smallint NOT NULL CHECK (minor_unit BETWEEN 0 AND 4),
    CONSTRAINT currencies_code_is_uppercase_alpha CHECK (code ~ '^[A-Z]{3}$'),

    -- Read the constraint name in the error message: that is the whole point
    -- of it. A foreign key alone would only stop an *unknown* code, and the
    -- predictable mistake here is not a typo -- it is a developer adding IRT
    -- deliberately because a user asked for toman. This refuses at exactly
    -- that moment and says why. Toman is a display unit; see
    -- workspaces.display_unit and this migration's header.
    CONSTRAINT currencies_toman_is_a_display_unit_not_a_currency
        CHECK (code <> 'IRT')
);

INSERT INTO currencies (code, name, minor_unit) VALUES
    ('IRR', 'Iranian rial',        0),
    ('USD', 'United States dollar', 2),
    ('EUR', 'Euro',                 2),
    ('AED', 'UAE dirham',           2),
    ('CNY', 'Chinese yuan',         2);

-- Note the absence of IRT. The foreign key from workspaces and journal_lines
-- to this table is what structurally prevents toman being recorded as a
-- currency -- see the header.


-- -----------------------------------------------------------------------------
-- Workspaces: unit of account, and how to display it
-- -----------------------------------------------------------------------------

ALTER TABLE workspaces
    ADD CONSTRAINT workspaces_base_currency_is_known
        FOREIGN KEY (base_currency) REFERENCES currencies (code);

-- Composite FK target, so a journal line's idea of the base currency cannot
-- drift from its workspace's. Same trick as (workspace_id, id) elsewhere.
ALTER TABLE workspaces
    ADD CONSTRAINT workspaces_id_base_currency_unique UNIQUE (id, base_currency);

ALTER TABLE workspaces
    -- What to call the unit on screen. NULL means use the currency itself.
    -- 'toman' for an Iranian workspace keeping books in rial.
    ADD COLUMN display_unit     text,
    -- Powers of ten to shift by for display: 1 rial -> toman. Purely
    -- presentational; nothing in the ledger reads it.
    ADD COLUMN display_exponent smallint NOT NULL DEFAULT 0;

ALTER TABLE workspaces
    ADD CONSTRAINT workspaces_display_exponent_sane
        CHECK (display_exponent BETWEEN 0 AND 6),
    -- A shift with no name would render ambiguous amounts.
    ADD CONSTRAINT workspaces_display_shift_is_named
        CHECK (display_exponent = 0 OR display_unit IS NOT NULL),
    ADD CONSTRAINT workspaces_display_unit_not_blank
        CHECK (display_unit IS NULL OR length(trim(display_unit)) > 0);


-- -----------------------------------------------------------------------------
-- Journal lines: base amounts, and what they were originally denominated in
-- -----------------------------------------------------------------------------

-- numeric(18,2) was too narrow to be safe in rial: 16 digits ahead of the
-- decimal, against a currency where an ordinary SMB invoice runs to ten
-- figures. Widening is free while the table is empty and a rewrite of an
-- immutable table afterwards. The extra scale is headroom for FX conversion,
-- not a claim that fractional rial exist.
--
-- The NL-query projection reads these columns, and Postgres will not retype a
-- column a view depends on, so the view is dropped and rebuilt below.
DROP VIEW ledger_query.journal_lines;

ALTER TABLE journal_lines
    ALTER COLUMN debit  TYPE numeric(24,6),
    ALTER COLUMN credit TYPE numeric(24,6);

ALTER TABLE journal_lines
    -- Denormalised from the workspace so the composite FK below can pin it.
    ADD COLUMN base_currency   char(3),
    -- What the transaction was actually denominated in.
    ADD COLUMN currency        char(3),
    -- The amount as the counterparty stated it, in `currency`.
    ADD COLUMN original_debit  numeric(24,6) NOT NULL DEFAULT 0,
    ADD COLUMN original_credit numeric(24,6) NOT NULL DEFAULT 0,
    -- Base currency units per one unit of `currency`:
    --     debit = original_debit * fx_rate
    -- Recorded per line rather than looked up from a rates table, on purpose.
    -- There is no bank feed to source rates from, and in the Iranian market
    -- there is no single rate to source -- official, NIMA and free-market
    -- rates differ, and the books must record the one actually transacted at.
    ADD COLUMN fx_rate         numeric(24,12) NOT NULL DEFAULT 1,
    -- Which rate that was. Free text for now; a controlled vocabulary can come
    -- with the L1 application work, once the real answers are known.
    ADD COLUMN fx_rate_source  text;

-- Backfill. The immutability trigger refuses UPDATEs against lines of posted
-- entries, so it comes off for the duration -- inside this migration's
-- transaction, so a failure anywhere leaves the trigger enabled and the schema
-- untouched. This is the retrofit cost the header warns about, paid here at
-- its smallest.
ALTER TABLE journal_lines DISABLE TRIGGER trg_journal_lines_immutability;

UPDATE journal_lines l
   SET base_currency   = w.base_currency,
       currency        = w.base_currency,
       original_debit  = l.debit,
       original_credit = l.credit,
       fx_rate         = 1
  FROM workspaces w
 WHERE w.id = l.workspace_id;

ALTER TABLE journal_lines ENABLE TRIGGER trg_journal_lines_immutability;

ALTER TABLE journal_lines
    ALTER COLUMN base_currency SET NOT NULL,
    ALTER COLUMN currency      SET NOT NULL;

ALTER TABLE journal_lines
    ADD CONSTRAINT journal_lines_currency_is_known
        FOREIGN KEY (currency) REFERENCES currencies (code),
    -- The line's base currency is its workspace's base currency, structurally.
    -- This also makes a workspace's base_currency un-changeable once it has
    -- lines, which is the correct behaviour: re-denominating posted books is
    -- not an UPDATE.
    ADD CONSTRAINT journal_lines_base_currency_matches_workspace
        FOREIGN KEY (workspace_id, base_currency)
        REFERENCES workspaces (id, base_currency),
    ADD CONSTRAINT journal_lines_fx_rate_positive
        CHECK (fx_rate > 0),
    -- The original amount sits on the same side as the base amount, and is
    -- zero on the other. Mirrors journal_lines_single_sided.
    ADD CONSTRAINT journal_lines_original_single_sided CHECK (
        original_debit >= 0 AND original_credit >= 0
        AND (original_debit > 0) = (debit > 0)
        AND (original_credit > 0) = (credit > 0)
    ),
    -- A line denominated in the base currency has nothing to convert.
    ADD CONSTRAINT journal_lines_base_currency_rate_is_identity CHECK (
        currency <> base_currency
        OR (fx_rate = 1 AND original_debit = debit AND original_credit = credit)
    );


-- -----------------------------------------------------------------------------
-- Currency defaults, so callers do not carry them
-- -----------------------------------------------------------------------------
-- Without this, every INSERT into journal_lines would have to repeat what the
-- workspace already knows and mirror the amounts by hand. That is boilerplate
-- at exactly the point where a mistake is a wrong ledger, and it would have to
-- be written identically in the API, the CSV importer, the OCR path and every
-- test. The database knows the answer, so the database fills it in.
--
-- Effect: a Level 0 caller writes the same INSERT it wrote before this
-- migration and never thinks about currency. A Level 1 caller supplies
-- currency, fx_rate and the original amounts, and the trigger leaves them be.
CREATE OR REPLACE FUNCTION journal_line_currency_defaults() RETURNS trigger AS $fn$
DECLARE
    workspace_currency char(3);
BEGIN
    SELECT w.base_currency INTO workspace_currency
      FROM workspaces w WHERE w.id = NEW.workspace_id;

    -- No workspace: let the foreign key report that, rather than masking it
    -- with a confusing not-null failure on a column the caller never named.
    IF workspace_currency IS NULL THEN
        RETURN NEW;
    END IF;

    NEW.base_currency := coalesce(NEW.base_currency, workspace_currency);
    NEW.currency      := coalesce(NEW.currency, NEW.base_currency);

    -- For a line denominated in the base currency these are not defaults, they
    -- are definitions -- there is nothing to convert -- so they are set rather
    -- than merely defaulted.
    IF NEW.currency = NEW.base_currency THEN
        NEW.original_debit  := NEW.debit;
        NEW.original_credit := NEW.credit;
        NEW.fx_rate         := 1;
    END IF;

    RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

-- Name matters: same-event triggers fire in alphabetical order, so this runs
-- before trg_journal_lines_immutability. They are independent today, but the
-- ordering is worth being deliberate about rather than accidental.
CREATE TRIGGER trg_journal_lines_currency_defaults
    BEFORE INSERT ON journal_lines
    FOR EACH ROW EXECUTE FUNCTION journal_line_currency_defaults();


-- -----------------------------------------------------------------------------
-- Rebuild the NL-query projection
-- -----------------------------------------------------------------------------
-- Identical to its definition in 0001. The foreign-currency columns are
-- deliberately not exposed yet: under the Level 0 gate below, `currency` is
-- always the base currency, so projecting it would only give generated SQL a
-- column that is constant. The L1 migration that drops the gate adds them.
CREATE VIEW ledger_query.journal_lines AS
    SELECT l.id               AS line_id,
           l.journal_entry_id AS entry_id,
           e.entry_date,
           CASE WHEN e.posted_at IS NULL THEN 'draft' ELSE 'posted' END AS status,
           a.code AS account_code,
           a.name AS account_name,
           a.type AS account_type,
           l.debit,
           l.credit,
           l.memo
      FROM journal_lines l
      JOIN journal_entries e ON e.id = l.journal_entry_id
      JOIN accounts a        ON a.id = l.account_id
     WHERE l.workspace_id = app_current_workspace();

-- Dropping a view drops its grants. `ALTER DEFAULT PRIVILEGES` in roles.sql
-- would usually re-grant this, but only when the migration happens to run as
-- the same role that set the default -- too subtle to rely on for a control
-- that silently fails open. Re-granted explicitly, if the role exists yet.
DO $do$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nl_query') THEN
        GRANT SELECT ON ledger_query.journal_lines TO nl_query;
    END IF;
END;
$do$;


-- -----------------------------------------------------------------------------
-- The Level 0 gate
-- -----------------------------------------------------------------------------
-- Everything above is Level 1 ready. This single constraint holds the ledger
-- at Level 0 until the application side exists: rate capture in the entry UI,
-- FX gain/loss accounts in the chart of accounts, and a decision on period-end
-- revaluation. Recording foreign-currency entries without those produces books
-- that balance but are wrong, which is worse than not supporting them.
--
-- Dropping this is the whole of the schema work for L1:
--     ALTER TABLE journal_lines
--         DROP CONSTRAINT journal_lines_single_currency_until_l1;
ALTER TABLE journal_lines
    ADD CONSTRAINT journal_lines_single_currency_until_l1
        CHECK (currency = base_currency);
