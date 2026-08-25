-- =============================================================================
-- 0001 -- initial schema.
--
-- The starting point for BOTH deployment targets: the embedded Postgres
-- bundled with the desktop app, and hosted/on-prem multi-tenant Postgres.
-- There is no parallel SQLite schema, so a user upgrading from local to
-- hosted carries their data across without a migration rewrite.
--
-- This file is history. It has been applied to real databases, so editing it
-- is a drift error the runner will refuse (it checksums applied migrations).
-- Change the schema by adding the next numbered migration. For the schema as
-- it stands today, read db/schema.sql, which is generated.
--
-- Two invariants are enforced here, in the database, rather than in
-- application code -- because ElectricSQL will eventually let writes reach
-- this database from multiple devices, and an invariant that lives only in a
-- FastAPI handler is not an invariant:
--
--   1. A posted journal entry is immutable and undeletable. So are its lines.
--      Corrections are reversing entries.
--   2. An entry cannot reach the posted state unbalanced: debits must equal
--      credits, and there must be something to balance.
--
-- Mutable rows (drafts, accounts, rules, ai config) carry a `version` integer
-- that the database bumps on every UPDATE, so optimistic concurrency is
--   UPDATE ... WHERE id = $1 AND version = $2   -->   0 rows means conflict.
--
-- `workspace_id` is the tenant boundary on every table, including in
-- single-user local mode. Child tables carry their own `workspace_id` and
-- reference parents through composite (workspace_id, id) foreign keys, so a
-- row can never point at another tenant's row -- a cross-tenant reference is
-- structurally impossible rather than merely unlikely.
--
-- Requires PostgreSQL 13+, for the built-in gen_random_uuid(). No uuid-ossp
-- extension, so this applies cleanly on managed Postgres and on the embedded
-- desktop instance without superuser rights.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Session helpers
-- -----------------------------------------------------------------------------

-- The workspace the current session is acting on. Set per request:
--   SET LOCAL app.workspace_id = '<uuid>';
-- Read by the read-only NL-query views at the bottom of this file, which
-- return zero rows when it is unset -- so generated text-to-SQL cannot read a
-- tenant the request was not scoped to.
CREATE OR REPLACE FUNCTION app_current_workspace() RETURNS uuid AS $fn$
    SELECT nullif(current_setting('app.workspace_id', true), '')::uuid;
$fn$ LANGUAGE sql STABLE;

-- Break-glass switch for tenant offboarding only (workspace deletion, GDPR
-- erasure). Posted rows are undeletable unless a transaction opts in with:
--   SET LOCAL app.ledger_purge = 'on';
-- Nothing in the normal request path may set this.
CREATE OR REPLACE FUNCTION app_ledger_purge_enabled() RETURNS boolean AS $fn$
    SELECT coalesce(current_setting('app.ledger_purge', true), 'off') = 'on';
$fn$ LANGUAGE sql STABLE;


-- -----------------------------------------------------------------------------
-- Tenancy
-- -----------------------------------------------------------------------------

CREATE TABLE workspaces (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name            text NOT NULL CHECK (length(trim(name)) > 0),
    -- Single-currency for now: every amount in this workspace is in this
    -- currency. Multi-currency is an open decision -- see db/README.md.
    base_currency   char(3) NOT NULL DEFAULT 'USD',
    version         integer NOT NULL DEFAULT 1,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Every connected desktop instance, for the cowork/on-prem realtime feature.
-- `user_id` is deliberately an unconstrained uuid: there is no users table
-- yet, and roles/permissions is still an open decision (db/README.md). It is
-- nullable so a server-side install can register a device before an identity
-- model exists.
CREATE TABLE devices (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id    uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    user_id         uuid,
    label           text,
    last_seen_at    timestamptz NOT NULL DEFAULT now(),
    created_at      timestamptz NOT NULL DEFAULT now(),

    UNIQUE (workspace_id, id)   -- composite FK target
);

-- The single seam the AI abstraction layer reads from. Switching a workspace
-- between "cloud with the client's own API key" and "fully offline Ollama" is
-- one row update here -- no redeploy, no code branch.
CREATE TABLE workspace_ai_config (
    workspace_id        uuid PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
    mode                text NOT NULL CHECK (mode IN (
                            'cloud_openai',
                            'cloud_anthropic',
                            'cloud_azure_openai',
                            'cloud_custom_endpoint',
                            'local_ollama')),
    model               text NOT NULL CHECK (length(trim(model)) > 0),
    -- Encrypted by the application before it ever reaches this column.
    -- Never logged, never returned by any API response.
    api_key_encrypted   text,
    api_base            text,   -- custom endpoint URL, or local Ollama host
    organization        text,   -- OpenAI org id, where applicable
    version             integer NOT NULL DEFAULT 1,
    updated_at          timestamptz NOT NULL DEFAULT now(),

    -- An offline workspace must not be carrying a cloud key.
    CONSTRAINT workspace_ai_config_offline_has_no_key CHECK (
        mode <> 'local_ollama' OR api_key_encrypted IS NULL
    )
);


-- -----------------------------------------------------------------------------
-- Chart of accounts
-- -----------------------------------------------------------------------------

CREATE TABLE accounts (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id        uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    code                text NOT NULL CHECK (length(trim(code)) > 0),
    name                text NOT NULL CHECK (length(trim(name)) > 0),
    type                text NOT NULL CHECK (type IN
                            ('asset','liability','equity','revenue','expense')),
    parent_account_id   uuid,
    is_archived         boolean NOT NULL DEFAULT false,
    version             integer NOT NULL DEFAULT 1,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),

    UNIQUE (workspace_id, code),
    UNIQUE (workspace_id, id),   -- composite FK target
    CONSTRAINT accounts_parent_not_self CHECK (parent_account_id <> id),
    -- A parent account must live in the same workspace.
    CONSTRAINT accounts_parent_same_workspace
        FOREIGN KEY (workspace_id, parent_account_id)
        REFERENCES accounts (workspace_id, id)
);


-- -----------------------------------------------------------------------------
-- Double-entry ledger
-- -----------------------------------------------------------------------------

-- Append-only once posted. `posted_at IS NULL` means draft: freely mutable,
-- with `version` guarding concurrent edits. Setting `posted_at` is a one-way
-- door enforced by trigger, not by convention.
CREATE TABLE journal_entries (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id            uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    entry_date              date NOT NULL,
    memo                    text,
    source                  text NOT NULL DEFAULT 'manual' CHECK (source IN (
                                'manual',
                                'ocr_import',
                                'csv_import',
                                'ai_categorized',
                                'reversal')),
    -- Null for entries created server-side (hosted CSV import, API) where no
    -- desktop device originated the write.
    created_by_device_id    uuid,
    -- Set when this entry reverses another. This is what makes "corrections
    -- are reversing entries" auditable rather than merely stated.
    reverses_entry_id       uuid,
    posted_at               timestamptz,                 -- NULL while draft
    version                 integer NOT NULL DEFAULT 1,  -- only meaningful pre-posting
    created_at              timestamptz NOT NULL DEFAULT now(),
    updated_at              timestamptz NOT NULL DEFAULT now(),

    UNIQUE (workspace_id, id),   -- composite FK target
    CONSTRAINT journal_entries_device_same_workspace
        FOREIGN KEY (workspace_id, created_by_device_id)
        REFERENCES devices (workspace_id, id),
    CONSTRAINT journal_entries_reverses_same_workspace
        FOREIGN KEY (workspace_id, reverses_entry_id)
        REFERENCES journal_entries (workspace_id, id),
    CONSTRAINT journal_entries_reversal_not_self CHECK (reverses_entry_id <> id),
    CONSTRAINT journal_entries_reversal_is_sourced CHECK (
        reverses_entry_id IS NULL OR source = 'reversal'
    )
);

-- An entry may be reversed at most once.
CREATE UNIQUE INDEX uq_journal_entries_one_reversal
    ON journal_entries (reverses_entry_id)
    WHERE reverses_entry_id IS NOT NULL;

CREATE TABLE journal_lines (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Carried explicitly rather than inherited through the parent entry, so
    -- ElectricSQL can sync this table with a workspace-scoped shape, and so
    -- the composite FKs below can pin both parents to the same tenant.
    workspace_id        uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    journal_entry_id    uuid NOT NULL,
    account_id          uuid NOT NULL,
    debit               numeric(18,2) NOT NULL DEFAULT 0,
    credit              numeric(18,2) NOT NULL DEFAULT 0,
    memo                text,
    created_at          timestamptz NOT NULL DEFAULT now(),

    -- Exactly one side carries a positive amount. (The previous
    -- `debit = 0 OR credit = 0` admitted a line that was zero on both sides,
    -- and admitted negative amounts on either side.)
    CONSTRAINT journal_lines_single_sided CHECK (
        debit >= 0 AND credit >= 0 AND (debit > 0) <> (credit > 0)
    ),
    CONSTRAINT journal_lines_entry_same_workspace
        FOREIGN KEY (workspace_id, journal_entry_id)
        REFERENCES journal_entries (workspace_id, id) ON DELETE CASCADE,
    CONSTRAINT journal_lines_account_same_workspace
        FOREIGN KEY (workspace_id, account_id)
        REFERENCES accounts (workspace_id, id)
);


-- -----------------------------------------------------------------------------
-- Ledger invariants, enforced in the database
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION guard_journal_entry_immutability() RETURNS trigger AS $fn$
DECLARE
    total_debit  numeric(18,2);
    total_credit numeric(18,2);
    line_count   integer;
BEGIN
    -- Posting is a transition, never an initial state. An INSERT that already
    -- carried `posted_at` would sail past the balance check below, since the
    -- entry has no lines yet at insert time. Forcing draft -> UPDATE -> posted
    -- keeps posting to exactly one validated code path.
    --
    -- NOTE for the phase-3 ElectricSQL spike: this means a device cannot sync
    -- an already-posted entry up as a raw INSERT. Write-through (device -> API
    -- -> draft insert -> post) satisfies it; direct table replication of the
    -- write path does not. That is a question the spike has to answer, not one
    -- to quietly relax here.
    IF TG_OP = 'INSERT' THEN
        IF new.posted_at IS NOT NULL THEN
            RAISE EXCEPTION
                'journal_entries: an entry must be inserted as a draft and posted by a subsequent UPDATE (entry %).',
                new.id
                USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN new;
    END IF;

    IF TG_OP = 'DELETE' THEN
        IF old.posted_at IS NOT NULL AND NOT app_ledger_purge_enabled() THEN
            RAISE EXCEPTION
                'journal_entries: entry % was posted at % and cannot be deleted; record a reversing entry instead.',
                old.id, old.posted_at
                USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN old;
    END IF;

    -- Posted rows are frozen. No column, not even the memo, may change.
    IF old.posted_at IS NOT NULL THEN
        RAISE EXCEPTION
            'journal_entries: entry % was posted at % and is immutable; record a reversing entry instead.',
            old.id, old.posted_at
            USING ERRCODE = 'restrict_violation';
    END IF;

    -- The tenant boundary is not reassignable.
    IF new.workspace_id IS DISTINCT FROM old.workspace_id THEN
        RAISE EXCEPTION
            'journal_entries: workspace_id is the tenant boundary and cannot be reassigned (entry %).',
            old.id
            USING ERRCODE = 'restrict_violation';
    END IF;

    -- Draft -> posted is the one-way door. Validate that the entry balances
    -- before letting it through, because afterwards nothing can be corrected
    -- in place.
    IF new.posted_at IS NOT NULL THEN
        SELECT coalesce(sum(l.debit), 0), coalesce(sum(l.credit), 0), count(*)
          INTO total_debit, total_credit, line_count
          FROM journal_lines l
         WHERE l.journal_entry_id = new.id;

        IF line_count < 2 THEN
            RAISE EXCEPTION
                'journal_entries: entry % needs at least two lines before posting (found %).',
                new.id, line_count
                USING ERRCODE = 'check_violation';
        END IF;

        IF total_debit <> total_credit THEN
            RAISE EXCEPTION
                'journal_entries: entry % is unbalanced (debits %, credits %) and cannot be posted.',
                new.id, total_debit, total_credit
                USING ERRCODE = 'check_violation';
        END IF;

        IF total_debit = 0 THEN
            RAISE EXCEPTION
                'journal_entries: entry % has zero total value and cannot be posted.',
                new.id
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    new.version    := old.version + 1;
    new.updated_at := now();
    RETURN new;
END;
$fn$ LANGUAGE plpgsql;

CREATE TRIGGER trg_journal_entries_immutability
    BEFORE INSERT OR UPDATE OR DELETE ON journal_entries
    FOR EACH ROW EXECUTE FUNCTION guard_journal_entry_immutability();

-- Without this, a posted entry would be immutable but its amounts would not:
-- you could UPDATE or DELETE its lines and change what a posted entry says.
CREATE OR REPLACE FUNCTION guard_journal_line_immutability() RETURNS trigger AS $fn$
DECLARE
    parent_posted timestamptz;
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        -- No row is found when the parent is already gone, i.e. this is the
        -- cascade from deleting a draft entry. That path is allowed.
        SELECT e.posted_at INTO parent_posted
          FROM journal_entries e WHERE e.id = old.journal_entry_id;

        IF parent_posted IS NOT NULL AND NOT app_ledger_purge_enabled() THEN
            RAISE EXCEPTION
                'journal_lines: line % belongs to posted entry % and is immutable; record a reversing entry instead.',
                old.id, old.journal_entry_id
                USING ERRCODE = 'restrict_violation';
        END IF;
    END IF;

    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        SELECT e.posted_at INTO parent_posted
          FROM journal_entries e WHERE e.id = new.journal_entry_id;

        IF parent_posted IS NOT NULL THEN
            RAISE EXCEPTION
                'journal_lines: cannot add or move a line into posted entry %.',
                new.journal_entry_id
                USING ERRCODE = 'restrict_violation';
        END IF;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN old;
    END IF;
    RETURN new;
END;
$fn$ LANGUAGE plpgsql;

CREATE TRIGGER trg_journal_lines_immutability
    BEFORE INSERT OR UPDATE OR DELETE ON journal_lines
    FOR EACH ROW EXECUTE FUNCTION guard_journal_line_immutability();


-- -----------------------------------------------------------------------------
-- Optimistic concurrency for the mutable tables
-- -----------------------------------------------------------------------------

-- The database owns the version counter, so a client that forgets to bump it
-- still cannot silently clobber a concurrent edit: the read-modify-write does
--   UPDATE ... WHERE id = $1 AND version = $2
-- and gets 0 rows back when someone else already wrote.
CREATE OR REPLACE FUNCTION guard_mutable_row() RETURNS trigger AS $fn$
BEGIN
    IF new.workspace_id IS DISTINCT FROM old.workspace_id THEN
        RAISE EXCEPTION
            '%: workspace_id is the tenant boundary and cannot be reassigned.', TG_TABLE_NAME
            USING ERRCODE = 'restrict_violation';
    END IF;
    new.version    := old.version + 1;
    new.updated_at := now();
    RETURN new;
END;
$fn$ LANGUAGE plpgsql;

CREATE TRIGGER trg_accounts_version
    BEFORE UPDATE ON accounts
    FOR EACH ROW EXECUTE FUNCTION guard_mutable_row();

CREATE TRIGGER trg_workspace_ai_config_version
    BEFORE UPDATE ON workspace_ai_config
    FOR EACH ROW EXECUTE FUNCTION guard_mutable_row();


-- -----------------------------------------------------------------------------
-- Documents
-- OCR capture is a primary data-entry path here, not a convenience, because
-- there is no bank feed (BUSINESS_PRINCIPLES.md).
-- -----------------------------------------------------------------------------

CREATE TABLE documents (
    id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id                uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    kind                        text NOT NULL CHECK (kind IN ('receipt','invoice','statement')),
    file_path                   text NOT NULL,
    ocr_status                  text NOT NULL DEFAULT 'pending' CHECK (ocr_status IN
                                    ('pending','processing','done','failed')),
    ocr_raw_text                text,
    -- Structured fields from AIProvider extraction: vendor, line items,
    -- amounts, tax. Shape deliberately unconstrained for now.
    extracted_fields            jsonb,
    -- How sure the extraction was. This drives the least-steps rule in
    -- BUSINESS_PRINCIPLES.md: high confidence auto-drafts an entry for
    -- one-tap approval, low confidence opens a review form.
    extraction_confidence       numeric(4,3) CHECK (extraction_confidence BETWEEN 0 AND 1),
    linked_journal_entry_id     uuid,
    created_at                  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT documents_entry_same_workspace
        FOREIGN KEY (workspace_id, linked_journal_entry_id)
        REFERENCES journal_entries (workspace_id, id)
);


-- -----------------------------------------------------------------------------
-- Categorization
-- -----------------------------------------------------------------------------

-- Consulted before any LLM call. A user's correction becomes a row here
-- without a separate "create a rule" step (BUSINESS_PRINCIPLES.md).
CREATE TABLE categorization_rules (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id        uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    match_pattern       text NOT NULL CHECK (length(trim(match_pattern)) > 0),
    account_id          uuid NOT NULL,
    confidence_source   text NOT NULL DEFAULT 'user' CHECK (confidence_source IN
                            ('user','ai_suggested')),
    version             integer NOT NULL DEFAULT 1,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT categorization_rules_account_same_workspace
        FOREIGN KEY (workspace_id, account_id)
        REFERENCES accounts (workspace_id, id)
);

CREATE TRIGGER trg_categorization_rules_version
    BEFORE UPDATE ON categorization_rules
    FOR EACH ROW EXECUTE FUNCTION guard_mutable_row();


-- -----------------------------------------------------------------------------
-- Anomaly detection
-- -----------------------------------------------------------------------------

-- Detection is statistical (z-score/IQR/duplicate matching); the LLM only
-- writes `reason`, the human-readable explanation of an already-flagged row.
CREATE TABLE anomaly_flags (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id        uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    journal_entry_id    uuid,
    detector            text NOT NULL DEFAULT 'zscore' CHECK (detector IN
                            ('zscore','iqr','duplicate')),
    reason              text NOT NULL,   -- AI-generated explanation
    severity            text NOT NULL CHECK (severity IN ('low','medium','high')),
    resolved            boolean NOT NULL DEFAULT false,
    created_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT anomaly_flags_entry_same_workspace
        FOREIGN KEY (workspace_id, journal_entry_id)
        REFERENCES journal_entries (workspace_id, id)
);


-- -----------------------------------------------------------------------------
-- Indexes
-- -----------------------------------------------------------------------------

CREATE INDEX idx_accounts_workspace        ON accounts (workspace_id) WHERE NOT is_archived;
CREATE INDEX idx_accounts_parent           ON accounts (workspace_id, parent_account_id);
CREATE INDEX idx_devices_workspace         ON devices (workspace_id);
CREATE INDEX idx_journal_entries_workspace ON journal_entries (workspace_id, entry_date DESC);
CREATE INDEX idx_journal_entries_drafts    ON journal_entries (workspace_id, updated_at DESC)
                                              WHERE posted_at IS NULL;
CREATE INDEX idx_journal_lines_entry       ON journal_lines (journal_entry_id);
CREATE INDEX idx_journal_lines_account     ON journal_lines (workspace_id, account_id);
CREATE INDEX idx_documents_workspace       ON documents (workspace_id, created_at DESC);
CREATE INDEX idx_documents_ocr_queue       ON documents (ocr_status)
                                              WHERE ocr_status IN ('pending','processing');
CREATE INDEX idx_categorization_rules_ws   ON categorization_rules (workspace_id);
CREATE INDEX idx_anomaly_flags_open        ON anomaly_flags (workspace_id) WHERE NOT resolved;


-- -----------------------------------------------------------------------------
-- Read-only projection for natural-language (text-to-SQL) queries
--
-- The LLM is shown ONLY this schema, and the SQL it generates runs as a role
-- that can reach nothing else (db/roles.sql). Every view filters on
-- app_current_workspace(), so tenant scoping does not depend on the model
-- remembering to write a WHERE clause, and an unscoped session sees nothing
-- rather than everything. api_key_encrypted, file paths and raw OCR text are
-- deliberately not projected.
-- -----------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS ledger_query;

CREATE OR REPLACE VIEW ledger_query.accounts AS
    SELECT a.id   AS account_id,
           a.code AS account_code,
           a.name AS account_name,
           a.type AS account_type,
           a.parent_account_id,
           a.is_archived
      FROM accounts a
     WHERE a.workspace_id = app_current_workspace();

CREATE OR REPLACE VIEW ledger_query.journal_entries AS
    SELECT e.id AS entry_id,
           e.entry_date,
           e.memo,
           e.source,
           CASE WHEN e.posted_at IS NULL THEN 'draft' ELSE 'posted' END AS status,
           e.posted_at,
           e.reverses_entry_id
      FROM journal_entries e
     WHERE e.workspace_id = app_current_workspace();

CREATE OR REPLACE VIEW ledger_query.journal_lines AS
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

CREATE OR REPLACE VIEW ledger_query.anomaly_flags AS
    SELECT f.id               AS flag_id,
           f.journal_entry_id AS entry_id,
           f.detector,
           f.reason,
           f.severity,
           f.resolved,
           f.created_at
      FROM anomaly_flags f
     WHERE f.workspace_id = app_current_workspace();
