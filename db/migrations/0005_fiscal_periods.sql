-- =============================================================================
-- 0005 -- fiscal years, period locking, and the account attributes reports need.
--
-- There was no period concept at all before this. A correct P&L needs to know
-- where a year starts and ends and whether it is still open, and "posted
-- entries are immutable" is not the same guarantee as "last year's numbers
-- cannot change" -- a *new* entry backdated into a closed year moves a figure
-- someone has already filed.
--
-- ---------------------------------------------------------------------------
-- CALENDARS. Iranian businesses keep books on the Solar Hijri year: 1 Farvardin
-- to 29/30 Esfand, roughly 21 March to 20 March. That is not a different kind
-- of date, it is a different way of naming one -- the same insight as toman in
-- 0002.
--
-- So a fiscal year is stored as an ordinary Gregorian date range with a text
-- label. `journal_entries.entry_date` is already a plain `date`, so periods
-- have to be comparable to it; and Postgres has no Solar Hijri arithmetic
-- without an extension. A workspace on the Iranian calendar simply gets years
-- labelled '1404' running 2025-03-21 to 2026-03-20. `fiscal_calendar` records
-- which calendar the user thinks in, so the UI can render and default
-- correctly -- no calendar maths in the database, and no second date type.
-- =============================================================================

-- Needed for the non-overlap constraint below: gist indexing of uuid equality
-- alongside a range. A trusted extension since PG13, so the database owner can
-- install it without superuser -- the same bar that ruled out uuid-ossp in
-- 0001. Verified against a non-superuser owner on PG16.
CREATE EXTENSION IF NOT EXISTS btree_gist;


-- -----------------------------------------------------------------------------
-- Workspace-level period settings
-- -----------------------------------------------------------------------------

ALTER TABLE workspaces
    -- Display and defaulting only. Nothing in the ledger branches on it.
    ADD COLUMN fiscal_calendar text NOT NULL DEFAULT 'gregorian',
    -- A soft cutoff for the routine "close the month" case, which does not
    -- warrant a row per month. Nothing may be posted on or before this date.
    ADD COLUMN books_locked_through date;

ALTER TABLE workspaces
    ADD CONSTRAINT workspaces_fiscal_calendar_known
        CHECK (fiscal_calendar IN ('gregorian', 'solar_hijri'));


-- -----------------------------------------------------------------------------
-- Fiscal years
-- -----------------------------------------------------------------------------

CREATE TABLE fiscal_years (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id       uuid NOT NULL REFERENCES workspaces (id) ON DELETE CASCADE,
    -- What the user calls it: '1404', 'FY2026', '2025-26'. Free text because
    -- the naming convention is the user's, not ours.
    label              text NOT NULL CHECK (length(trim(label)) > 0),
    starts_on          date NOT NULL,
    ends_on            date NOT NULL,
    -- Closing is a state, not a deletion: a closed year keeps its rows and
    -- stops accepting new postings.
    closed_at          timestamptz,
    closed_by_user_id  uuid REFERENCES users (id),
    version            integer NOT NULL DEFAULT 1,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),

    UNIQUE (workspace_id, id),      -- composite FK target
    UNIQUE (workspace_id, label),
    CONSTRAINT fiscal_years_ends_after_start CHECK (ends_on > starts_on),
    CONSTRAINT fiscal_years_closer_implies_closed
        CHECK (closed_by_user_id IS NULL OR closed_at IS NOT NULL),

    -- Two fiscal years cannot cover the same day, or "which year is this entry
    -- in" has no answer. An exclusion constraint rather than a trigger because
    -- a trigger reading the table cannot see a concurrent uncommitted insert,
    -- so two overlapping years could be created at once and both succeed.
    CONSTRAINT fiscal_years_do_not_overlap
        EXCLUDE USING gist (
            workspace_id WITH =,
            daterange(starts_on, ends_on, '[]') WITH &&
        )
);

CREATE INDEX idx_fiscal_years_workspace ON fiscal_years (workspace_id, starts_on DESC);

CREATE TRIGGER trg_fiscal_years_version
    BEFORE UPDATE ON fiscal_years
    FOR EACH ROW EXECUTE FUNCTION guard_mutable_row();

-- Every new table with a workspace_id needs its policy in the same migration
-- that creates it. This one was genuinely forgotten while writing 0005;
-- verify_rls.sql reads coverage from the catalog rather than a list and failed
-- with "missing: fiscal_years", which is exactly the job it was added to do.
ALTER TABLE fiscal_years ENABLE ROW LEVEL SECURITY;

CREATE POLICY fiscal_years_workspace_isolation ON fiscal_years FOR ALL
    USING (workspace_id = app_current_workspace())
    WITH CHECK (workspace_id = app_current_workspace());


-- -----------------------------------------------------------------------------
-- Posting into a closed period
-- -----------------------------------------------------------------------------

-- Immutability stops a posted row changing. This stops a *new* row landing in
-- a period that has already been reported on, which is a different hole.
--
-- Only the draft -> posted transition is checked. Drafts may be dated
-- anywhere: a draft is not in the books yet, and refusing to let someone type
-- one would be the opposite of least-steps.
--
-- Closing entries are ordinary entries dated inside the year they close, so
-- they must be posted BEFORE the year is marked closed. That ordering is the
-- reason close is a flag set afterwards rather than an operation that posts
-- and locks in one step.
CREATE OR REPLACE FUNCTION guard_posting_period_is_open() RETURNS trigger AS $fn$
DECLARE
    locked_through date;
    closed_year    text;
BEGIN
    IF NEW.posted_at IS NULL THEN
        RETURN NEW;
    END IF;

    -- Already posted before this statement: immutability owns that case.
    IF TG_OP = 'UPDATE' AND OLD.posted_at IS NOT NULL THEN
        RETURN NEW;
    END IF;

    SELECT w.books_locked_through INTO locked_through
      FROM workspaces w WHERE w.id = NEW.workspace_id;

    IF locked_through IS NOT NULL AND NEW.entry_date <= locked_through THEN
        RAISE EXCEPTION
            'journal_entries: books are locked through %, so an entry dated % '
            'cannot be posted. Date it later, or move the lock.',
            locked_through, NEW.entry_date
            USING ERRCODE = 'restrict_violation';
    END IF;

    SELECT f.label INTO closed_year
      FROM fiscal_years f
     WHERE f.workspace_id = NEW.workspace_id
       AND f.closed_at IS NOT NULL
       AND NEW.entry_date BETWEEN f.starts_on AND f.ends_on;

    IF closed_year IS NOT NULL THEN
        RAISE EXCEPTION
            'journal_entries: fiscal year % is closed, so an entry dated % '
            'cannot be posted. Reopen the year, or post the correction to the '
            'open one.',
            closed_year, NEW.entry_date
            USING ERRCODE = 'restrict_violation';
    END IF;

    RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

-- Fires after trg_journal_entries_immutability, which sorts earlier by name:
-- an edit to an already-posted entry is rejected as immutable before this is
-- reached, which is the clearer error of the two.
CREATE TRIGGER trg_journal_entries_period_open
    BEFORE INSERT OR UPDATE ON journal_entries
    FOR EACH ROW EXECUTE FUNCTION guard_posting_period_is_open();


-- -----------------------------------------------------------------------------
-- Closing entries are a source of their own
-- -----------------------------------------------------------------------------

-- Year-end entries zeroing revenue and expense into retained earnings are
-- ordinary journal entries, but a P&L must exclude them or the year reads as
-- nil. Generating them is application work; being able to identify them is
-- schema.
ALTER TABLE journal_entries DROP CONSTRAINT journal_entries_source_check;

ALTER TABLE journal_entries
    ADD CONSTRAINT journal_entries_source_check CHECK (source IN (
        'manual',
        'ocr_import',
        'csv_import',
        'ai_categorized',
        'reversal',
        'period_close'
    ));


-- -----------------------------------------------------------------------------
-- What reports need from an account
-- -----------------------------------------------------------------------------

-- `type` alone cannot express a contra account. Accumulated depreciation is an
-- asset that carries a credit balance; sales returns is revenue carrying a
-- debit balance. A balance sheet built on type alone reports both with the
-- wrong sign, so the normal side has to be its own fact.
ALTER TABLE accounts
    ADD COLUMN normal_balance     text,
    -- Nullable, and only meaningful on balance-sheet accounts: the indirect
    -- cash flow statement needs to know which activity a movement belongs to,
    -- and there is nowhere else to put it.
    ADD COLUMN cash_flow_category text;

UPDATE accounts
   SET normal_balance = CASE
           WHEN type IN ('asset', 'expense') THEN 'debit'
           ELSE 'credit'
       END
 WHERE normal_balance IS NULL;

ALTER TABLE accounts
    ALTER COLUMN normal_balance SET NOT NULL;

ALTER TABLE accounts
    ADD CONSTRAINT accounts_normal_balance_known
        CHECK (normal_balance IN ('debit', 'credit')),
    ADD CONSTRAINT accounts_cash_flow_category_known
        CHECK (cash_flow_category IS NULL
               OR cash_flow_category IN ('operating', 'investing', 'financing'));

-- Defaulted from `type` so the ordinary account needs no thought, and a contra
-- account is a deliberate override rather than something every caller must
-- remember to state. Same shape as the currency defaults in 0002.
CREATE OR REPLACE FUNCTION account_normal_balance_default() RETURNS trigger AS $fn$
BEGIN
    IF NEW.normal_balance IS NULL THEN
        NEW.normal_balance := CASE
            WHEN NEW.type IN ('asset', 'expense') THEN 'debit'
            ELSE 'credit'
        END;
    END IF;
    RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

CREATE TRIGGER trg_accounts_normal_balance_default
    BEFORE INSERT ON accounts
    FOR EACH ROW EXECUTE FUNCTION account_normal_balance_default();
