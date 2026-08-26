-- =============================================================================
-- GENERATED FILE -- DO NOT EDIT.
--
-- A snapshot of the schema as produced by applying every migration in
-- db/migrations/ in order, dumped with pg_dump --schema-only. It exists to be
-- read and to be diffed in review: one file showing the current shape of the
-- database, without replaying the migration history in your head.
--
-- Nothing applies this file. Databases are built by the migration runner:
--
--     python -m accounting_api.migrate
--
-- Regenerate after adding a migration:
--
--     npm run db:snapshot
--
-- The hand-written, commented DDL lives in db/migrations/. Read those for the
-- reasoning; read this for the current state.
-- =============================================================================

--
-- PostgreSQL database dump
--


-- Dumped from database version 16.15
-- Dumped by pg_dump version 16.14

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: ledger_query; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA ledger_query;


--
-- Name: btree_gist; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;


--
-- Name: EXTENSION btree_gist; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION btree_gist IS 'support for indexing common datatypes in GiST';


--
-- Name: account_normal_balance_default(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.account_normal_balance_default() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.normal_balance IS NULL THEN
        NEW.normal_balance := CASE
            WHEN NEW.type IN ('asset', 'expense') THEN 'debit'
            ELSE 'credit'
        END;
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: app_current_workspace(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_current_workspace() RETURNS uuid
    LANGUAGE sql STABLE
    AS $$
    SELECT nullif(current_setting('app.workspace_id', true), '')::uuid;
$$;


--
-- Name: app_ledger_purge_enabled(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_ledger_purge_enabled() RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
    SELECT coalesce(current_setting('app.ledger_purge', true), 'off') = 'on';
$$;


--
-- Name: guard_entry_author_is_a_member(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_entry_author_is_a_member() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.created_by_user_id IS NOT NULL
       AND NOT EXISTS (
           SELECT 1 FROM workspace_members m
            WHERE m.workspace_id = NEW.workspace_id
              AND m.user_id = NEW.created_by_user_id
       )
    THEN
        RAISE EXCEPTION
            'journal_entries: user % is not a member of workspace %',
            NEW.created_by_user_id, NEW.workspace_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: guard_journal_entry_immutability(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_journal_entry_immutability() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: guard_journal_line_immutability(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_journal_line_immutability() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: guard_mutable_row(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_mutable_row() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: guard_posting_period_is_open(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_posting_period_is_open() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: guard_workspace_keeps_an_owner(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_workspace_keeps_an_owner() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    remaining integer;
BEGIN
    -- Only demotions and removals of an owner can strand a workspace.
    IF TG_OP = 'UPDATE' AND (OLD.role <> 'owner' OR NEW.role = 'owner') THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'DELETE' AND OLD.role <> 'owner' THEN
        RETURN OLD;
    END IF;

    -- The workspace itself going away takes its memberships with it, which is
    -- not stranding anyone.
    IF NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
        RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
    END IF;

    SELECT count(*) INTO remaining
      FROM workspace_members m
     WHERE m.workspace_id = OLD.workspace_id
       AND m.role = 'owner'
       AND m.user_id <> OLD.user_id;

    IF remaining = 0 THEN
        RAISE EXCEPTION
            'workspace_members: workspace % would be left with no owner; '
            'promote another member first.', OLD.workspace_id
            USING ERRCODE = 'restrict_violation';
    END IF;

    RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
END;
$$;


--
-- Name: guard_workspace_version(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_workspace_version() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    new.version    := old.version + 1;
    new.updated_at := now();
    RETURN new;
END;
$$;


--
-- Name: journal_line_currency_defaults(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.journal_line_currency_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.accounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    type text NOT NULL,
    parent_account_id uuid,
    is_archived boolean DEFAULT false NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    normal_balance text NOT NULL,
    cash_flow_category text,
    CONSTRAINT accounts_cash_flow_category_known CHECK (((cash_flow_category IS NULL) OR (cash_flow_category = ANY (ARRAY['operating'::text, 'investing'::text, 'financing'::text])))),
    CONSTRAINT accounts_code_check CHECK ((length(TRIM(BOTH FROM code)) > 0)),
    CONSTRAINT accounts_name_check CHECK ((length(TRIM(BOTH FROM name)) > 0)),
    CONSTRAINT accounts_normal_balance_known CHECK ((normal_balance = ANY (ARRAY['debit'::text, 'credit'::text]))),
    CONSTRAINT accounts_parent_not_self CHECK ((parent_account_id <> id)),
    CONSTRAINT accounts_type_check CHECK ((type = ANY (ARRAY['asset'::text, 'liability'::text, 'equity'::text, 'revenue'::text, 'expense'::text])))
);


--
-- Name: accounts; Type: VIEW; Schema: ledger_query; Owner: -
--

CREATE VIEW ledger_query.accounts AS
 SELECT id AS account_id,
    code AS account_code,
    name AS account_name,
    type AS account_type,
    parent_account_id,
    is_archived
   FROM public.accounts a
  WHERE (workspace_id = public.app_current_workspace());


--
-- Name: anomaly_flags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.anomaly_flags (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    journal_entry_id uuid,
    detector text DEFAULT 'zscore'::text NOT NULL,
    reason text NOT NULL,
    severity text NOT NULL,
    resolved boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT anomaly_flags_detector_check CHECK ((detector = ANY (ARRAY['zscore'::text, 'iqr'::text, 'duplicate'::text]))),
    CONSTRAINT anomaly_flags_severity_check CHECK ((severity = ANY (ARRAY['low'::text, 'medium'::text, 'high'::text])))
);


--
-- Name: anomaly_flags; Type: VIEW; Schema: ledger_query; Owner: -
--

CREATE VIEW ledger_query.anomaly_flags AS
 SELECT id AS flag_id,
    journal_entry_id AS entry_id,
    detector,
    reason,
    severity,
    resolved,
    created_at
   FROM public.anomaly_flags f
  WHERE (workspace_id = public.app_current_workspace());


--
-- Name: journal_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.journal_entries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    entry_date date NOT NULL,
    memo text,
    source text DEFAULT 'manual'::text NOT NULL,
    created_by_device_id uuid,
    reverses_entry_id uuid,
    posted_at timestamp with time zone,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by_user_id uuid,
    posted_by_user_id uuid,
    CONSTRAINT journal_entries_reversal_is_sourced CHECK (((reverses_entry_id IS NULL) OR (source = 'reversal'::text))),
    CONSTRAINT journal_entries_reversal_not_self CHECK ((reverses_entry_id <> id)),
    CONSTRAINT journal_entries_source_check CHECK ((source = ANY (ARRAY['manual'::text, 'ocr_import'::text, 'csv_import'::text, 'ai_categorized'::text, 'reversal'::text, 'period_close'::text])))
);


--
-- Name: journal_entries; Type: VIEW; Schema: ledger_query; Owner: -
--

CREATE VIEW ledger_query.journal_entries AS
 SELECT id AS entry_id,
    entry_date,
    memo,
    source,
        CASE
            WHEN (posted_at IS NULL) THEN 'draft'::text
            ELSE 'posted'::text
        END AS status,
    posted_at,
    reverses_entry_id
   FROM public.journal_entries e
  WHERE (workspace_id = public.app_current_workspace());


--
-- Name: journal_lines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.journal_lines (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    journal_entry_id uuid NOT NULL,
    account_id uuid NOT NULL,
    debit numeric(24,6) DEFAULT 0 NOT NULL,
    credit numeric(24,6) DEFAULT 0 NOT NULL,
    memo text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    base_currency character(3) NOT NULL,
    currency character(3) NOT NULL,
    original_debit numeric(24,6) DEFAULT 0 NOT NULL,
    original_credit numeric(24,6) DEFAULT 0 NOT NULL,
    fx_rate numeric(24,12) DEFAULT 1 NOT NULL,
    fx_rate_source text,
    CONSTRAINT journal_lines_base_currency_rate_is_identity CHECK (((currency <> base_currency) OR ((fx_rate = (1)::numeric) AND (original_debit = debit) AND (original_credit = credit)))),
    CONSTRAINT journal_lines_fx_rate_positive CHECK ((fx_rate > (0)::numeric)),
    CONSTRAINT journal_lines_original_single_sided CHECK (((original_debit >= (0)::numeric) AND (original_credit >= (0)::numeric) AND ((original_debit > (0)::numeric) = (debit > (0)::numeric)) AND ((original_credit > (0)::numeric) = (credit > (0)::numeric)))),
    CONSTRAINT journal_lines_single_currency_until_l1 CHECK ((currency = base_currency)),
    CONSTRAINT journal_lines_single_sided CHECK (((debit >= (0)::numeric) AND (credit >= (0)::numeric) AND ((debit > (0)::numeric) <> (credit > (0)::numeric))))
);


--
-- Name: journal_lines; Type: VIEW; Schema: ledger_query; Owner: -
--

CREATE VIEW ledger_query.journal_lines AS
 SELECT l.id AS line_id,
    l.journal_entry_id AS entry_id,
    e.entry_date,
        CASE
            WHEN (e.posted_at IS NULL) THEN 'draft'::text
            ELSE 'posted'::text
        END AS status,
    a.code AS account_code,
    a.name AS account_name,
    a.type AS account_type,
    l.debit,
    l.credit,
    l.memo
   FROM ((public.journal_lines l
     JOIN public.journal_entries e ON ((e.id = l.journal_entry_id)))
     JOIN public.accounts a ON ((a.id = l.account_id)))
  WHERE (l.workspace_id = public.app_current_workspace());


--
-- Name: categorization_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.categorization_rules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    match_pattern text NOT NULL,
    account_id uuid NOT NULL,
    confidence_source text DEFAULT 'user'::text NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT categorization_rules_confidence_source_check CHECK ((confidence_source = ANY (ARRAY['user'::text, 'ai_suggested'::text]))),
    CONSTRAINT categorization_rules_match_pattern_check CHECK ((length(TRIM(BOTH FROM match_pattern)) > 0))
);


--
-- Name: currencies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.currencies (
    code character(3) NOT NULL,
    name text NOT NULL,
    minor_unit smallint NOT NULL,
    CONSTRAINT currencies_code_is_uppercase_alpha CHECK ((code ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT currencies_minor_unit_check CHECK (((minor_unit >= 0) AND (minor_unit <= 4))),
    CONSTRAINT currencies_name_check CHECK ((length(TRIM(BOTH FROM name)) > 0)),
    CONSTRAINT currencies_toman_is_a_display_unit_not_a_currency CHECK ((code <> 'IRT'::bpchar))
);


--
-- Name: devices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.devices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    user_id uuid,
    label text,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    kind text NOT NULL,
    file_path text NOT NULL,
    ocr_status text DEFAULT 'pending'::text NOT NULL,
    ocr_raw_text text,
    extracted_fields jsonb,
    extraction_confidence numeric(4,3),
    linked_journal_entry_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT documents_extraction_confidence_check CHECK (((extraction_confidence >= (0)::numeric) AND (extraction_confidence <= (1)::numeric))),
    CONSTRAINT documents_kind_check CHECK ((kind = ANY (ARRAY['receipt'::text, 'invoice'::text, 'statement'::text]))),
    CONSTRAINT documents_ocr_status_check CHECK ((ocr_status = ANY (ARRAY['pending'::text, 'processing'::text, 'done'::text, 'failed'::text])))
);


--
-- Name: fiscal_years; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fiscal_years (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    label text NOT NULL,
    starts_on date NOT NULL,
    ends_on date NOT NULL,
    closed_at timestamp with time zone,
    closed_by_user_id uuid,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT fiscal_years_closer_implies_closed CHECK (((closed_by_user_id IS NULL) OR (closed_at IS NOT NULL))),
    CONSTRAINT fiscal_years_ends_after_start CHECK ((ends_on > starts_on)),
    CONSTRAINT fiscal_years_label_check CHECK ((length(TRIM(BOTH FROM label)) > 0))
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version integer NOT NULL,
    name text NOT NULL,
    checksum text NOT NULL,
    applied_at timestamp with time zone DEFAULT now() NOT NULL,
    duration_ms integer NOT NULL
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email text NOT NULL,
    display_name text,
    is_active boolean DEFAULT true NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT users_email_check CHECK ((length(TRIM(BOTH FROM email)) > 0))
);


--
-- Name: workspace_ai_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workspace_ai_config (
    workspace_id uuid NOT NULL,
    mode text NOT NULL,
    model text NOT NULL,
    api_key_encrypted text,
    api_base text,
    organization text,
    version integer DEFAULT 1 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT workspace_ai_config_mode_check CHECK ((mode = ANY (ARRAY['cloud_openai'::text, 'cloud_anthropic'::text, 'cloud_azure_openai'::text, 'cloud_custom_endpoint'::text, 'local_ollama'::text]))),
    CONSTRAINT workspace_ai_config_model_check CHECK ((length(TRIM(BOTH FROM model)) > 0)),
    CONSTRAINT workspace_ai_config_offline_has_no_key CHECK (((mode <> 'local_ollama'::text) OR (api_key_encrypted IS NULL)))
);


--
-- Name: workspace_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workspace_members (
    workspace_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role text NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT workspace_members_role_check CHECK ((role = ANY (ARRAY['owner'::text, 'bookkeeper'::text, 'viewer'::text])))
);


--
-- Name: workspaces; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workspaces (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    base_currency character(3) DEFAULT 'USD'::bpchar NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    display_unit text,
    display_exponent smallint DEFAULT 0 NOT NULL,
    fiscal_calendar text DEFAULT 'gregorian'::text NOT NULL,
    books_locked_through date,
    CONSTRAINT workspaces_display_exponent_sane CHECK (((display_exponent >= 0) AND (display_exponent <= 6))),
    CONSTRAINT workspaces_display_shift_is_named CHECK (((display_exponent = 0) OR (display_unit IS NOT NULL))),
    CONSTRAINT workspaces_display_unit_not_blank CHECK (((display_unit IS NULL) OR (length(TRIM(BOTH FROM display_unit)) > 0))),
    CONSTRAINT workspaces_fiscal_calendar_known CHECK ((fiscal_calendar = ANY (ARRAY['gregorian'::text, 'solar_hijri'::text]))),
    CONSTRAINT workspaces_name_check CHECK ((length(TRIM(BOTH FROM name)) > 0))
);


--
-- Name: accounts accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_pkey PRIMARY KEY (id);


--
-- Name: accounts accounts_workspace_id_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_workspace_id_code_key UNIQUE (workspace_id, code);


--
-- Name: accounts accounts_workspace_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_workspace_id_id_key UNIQUE (workspace_id, id);


--
-- Name: anomaly_flags anomaly_flags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anomaly_flags
    ADD CONSTRAINT anomaly_flags_pkey PRIMARY KEY (id);


--
-- Name: categorization_rules categorization_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categorization_rules
    ADD CONSTRAINT categorization_rules_pkey PRIMARY KEY (id);


--
-- Name: currencies currencies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.currencies
    ADD CONSTRAINT currencies_pkey PRIMARY KEY (code);


--
-- Name: devices devices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT devices_pkey PRIMARY KEY (id);


--
-- Name: devices devices_workspace_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT devices_workspace_id_id_key UNIQUE (workspace_id, id);


--
-- Name: documents documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_pkey PRIMARY KEY (id);


--
-- Name: fiscal_years fiscal_years_do_not_overlap; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fiscal_years
    ADD CONSTRAINT fiscal_years_do_not_overlap EXCLUDE USING gist (workspace_id WITH =, daterange(starts_on, ends_on, '[]'::text) WITH &&);


--
-- Name: fiscal_years fiscal_years_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fiscal_years
    ADD CONSTRAINT fiscal_years_pkey PRIMARY KEY (id);


--
-- Name: fiscal_years fiscal_years_workspace_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fiscal_years
    ADD CONSTRAINT fiscal_years_workspace_id_id_key UNIQUE (workspace_id, id);


--
-- Name: fiscal_years fiscal_years_workspace_id_label_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fiscal_years
    ADD CONSTRAINT fiscal_years_workspace_id_label_key UNIQUE (workspace_id, label);


--
-- Name: journal_entries journal_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entries
    ADD CONSTRAINT journal_entries_pkey PRIMARY KEY (id);


--
-- Name: journal_entries journal_entries_workspace_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entries
    ADD CONSTRAINT journal_entries_workspace_id_id_key UNIQUE (workspace_id, id);


--
-- Name: journal_lines journal_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_lines
    ADD CONSTRAINT journal_lines_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: workspace_ai_config workspace_ai_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_ai_config
    ADD CONSTRAINT workspace_ai_config_pkey PRIMARY KEY (workspace_id);


--
-- Name: workspace_members workspace_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_members
    ADD CONSTRAINT workspace_members_pkey PRIMARY KEY (workspace_id, user_id);


--
-- Name: workspaces workspaces_id_base_currency_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspaces
    ADD CONSTRAINT workspaces_id_base_currency_unique UNIQUE (id, base_currency);


--
-- Name: workspaces workspaces_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspaces
    ADD CONSTRAINT workspaces_pkey PRIMARY KEY (id);


--
-- Name: idx_accounts_parent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_accounts_parent ON public.accounts USING btree (workspace_id, parent_account_id);


--
-- Name: idx_accounts_workspace; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_accounts_workspace ON public.accounts USING btree (workspace_id) WHERE (NOT is_archived);


--
-- Name: idx_anomaly_flags_open; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_anomaly_flags_open ON public.anomaly_flags USING btree (workspace_id) WHERE (NOT resolved);


--
-- Name: idx_categorization_rules_ws; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_categorization_rules_ws ON public.categorization_rules USING btree (workspace_id);


--
-- Name: idx_devices_workspace; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_devices_workspace ON public.devices USING btree (workspace_id);


--
-- Name: idx_documents_ocr_queue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_documents_ocr_queue ON public.documents USING btree (ocr_status) WHERE (ocr_status = ANY (ARRAY['pending'::text, 'processing'::text]));


--
-- Name: idx_documents_workspace; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_documents_workspace ON public.documents USING btree (workspace_id, created_at DESC);


--
-- Name: idx_fiscal_years_workspace; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fiscal_years_workspace ON public.fiscal_years USING btree (workspace_id, starts_on DESC);


--
-- Name: idx_journal_entries_author; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_journal_entries_author ON public.journal_entries USING btree (workspace_id, created_by_user_id);


--
-- Name: idx_journal_entries_drafts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_journal_entries_drafts ON public.journal_entries USING btree (workspace_id, updated_at DESC) WHERE (posted_at IS NULL);


--
-- Name: idx_journal_entries_workspace; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_journal_entries_workspace ON public.journal_entries USING btree (workspace_id, entry_date DESC);


--
-- Name: idx_journal_lines_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_journal_lines_account ON public.journal_lines USING btree (workspace_id, account_id);


--
-- Name: idx_journal_lines_entry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_journal_lines_entry ON public.journal_lines USING btree (journal_entry_id);


--
-- Name: idx_workspace_members_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_workspace_members_user ON public.workspace_members USING btree (user_id);


--
-- Name: uq_journal_entries_one_reversal; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_journal_entries_one_reversal ON public.journal_entries USING btree (reverses_entry_id) WHERE (reverses_entry_id IS NOT NULL);


--
-- Name: uq_users_email_lower; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_users_email_lower ON public.users USING btree (lower(email));


--
-- Name: accounts trg_accounts_normal_balance_default; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_accounts_normal_balance_default BEFORE INSERT ON public.accounts FOR EACH ROW EXECUTE FUNCTION public.account_normal_balance_default();


--
-- Name: accounts trg_accounts_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_accounts_version BEFORE UPDATE ON public.accounts FOR EACH ROW EXECUTE FUNCTION public.guard_mutable_row();


--
-- Name: categorization_rules trg_categorization_rules_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_categorization_rules_version BEFORE UPDATE ON public.categorization_rules FOR EACH ROW EXECUTE FUNCTION public.guard_mutable_row();


--
-- Name: fiscal_years trg_fiscal_years_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_fiscal_years_version BEFORE UPDATE ON public.fiscal_years FOR EACH ROW EXECUTE FUNCTION public.guard_mutable_row();


--
-- Name: journal_entries trg_journal_entries_author_is_a_member; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_journal_entries_author_is_a_member BEFORE INSERT ON public.journal_entries FOR EACH ROW EXECUTE FUNCTION public.guard_entry_author_is_a_member();


--
-- Name: journal_entries trg_journal_entries_immutability; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_journal_entries_immutability BEFORE INSERT OR DELETE OR UPDATE ON public.journal_entries FOR EACH ROW EXECUTE FUNCTION public.guard_journal_entry_immutability();


--
-- Name: journal_entries trg_journal_entries_period_open; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_journal_entries_period_open BEFORE INSERT OR UPDATE ON public.journal_entries FOR EACH ROW EXECUTE FUNCTION public.guard_posting_period_is_open();


--
-- Name: journal_lines trg_journal_lines_currency_defaults; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_journal_lines_currency_defaults BEFORE INSERT ON public.journal_lines FOR EACH ROW EXECUTE FUNCTION public.journal_line_currency_defaults();


--
-- Name: journal_lines trg_journal_lines_immutability; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_journal_lines_immutability BEFORE INSERT OR DELETE OR UPDATE ON public.journal_lines FOR EACH ROW EXECUTE FUNCTION public.guard_journal_line_immutability();


--
-- Name: users trg_users_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_users_version BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.guard_mutable_row();


--
-- Name: workspace_ai_config trg_workspace_ai_config_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_workspace_ai_config_version BEFORE UPDATE ON public.workspace_ai_config FOR EACH ROW EXECUTE FUNCTION public.guard_mutable_row();


--
-- Name: workspace_members trg_workspace_members_keep_an_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_workspace_members_keep_an_owner BEFORE DELETE OR UPDATE ON public.workspace_members FOR EACH ROW EXECUTE FUNCTION public.guard_workspace_keeps_an_owner();


--
-- Name: workspace_members trg_workspace_members_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_workspace_members_version BEFORE UPDATE ON public.workspace_members FOR EACH ROW EXECUTE FUNCTION public.guard_mutable_row();


--
-- Name: workspaces trg_workspaces_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_workspaces_version BEFORE UPDATE ON public.workspaces FOR EACH ROW EXECUTE FUNCTION public.guard_workspace_version();


--
-- Name: accounts accounts_parent_same_workspace; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_parent_same_workspace FOREIGN KEY (workspace_id, parent_account_id) REFERENCES public.accounts(workspace_id, id);


--
-- Name: accounts accounts_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: anomaly_flags anomaly_flags_entry_same_workspace; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anomaly_flags
    ADD CONSTRAINT anomaly_flags_entry_same_workspace FOREIGN KEY (workspace_id, journal_entry_id) REFERENCES public.journal_entries(workspace_id, id);


--
-- Name: anomaly_flags anomaly_flags_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anomaly_flags
    ADD CONSTRAINT anomaly_flags_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: categorization_rules categorization_rules_account_same_workspace; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categorization_rules
    ADD CONSTRAINT categorization_rules_account_same_workspace FOREIGN KEY (workspace_id, account_id) REFERENCES public.accounts(workspace_id, id);


--
-- Name: categorization_rules categorization_rules_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categorization_rules
    ADD CONSTRAINT categorization_rules_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: devices devices_user_is_a_member; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT devices_user_is_a_member FOREIGN KEY (workspace_id, user_id) REFERENCES public.workspace_members(workspace_id, user_id);


--
-- Name: devices devices_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT devices_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: documents documents_entry_same_workspace; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_entry_same_workspace FOREIGN KEY (workspace_id, linked_journal_entry_id) REFERENCES public.journal_entries(workspace_id, id);


--
-- Name: documents documents_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: fiscal_years fiscal_years_closed_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fiscal_years
    ADD CONSTRAINT fiscal_years_closed_by_user_id_fkey FOREIGN KEY (closed_by_user_id) REFERENCES public.users(id);


--
-- Name: fiscal_years fiscal_years_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fiscal_years
    ADD CONSTRAINT fiscal_years_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: journal_entries journal_entries_created_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entries
    ADD CONSTRAINT journal_entries_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES public.users(id);


--
-- Name: journal_entries journal_entries_device_same_workspace; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entries
    ADD CONSTRAINT journal_entries_device_same_workspace FOREIGN KEY (workspace_id, created_by_device_id) REFERENCES public.devices(workspace_id, id);


--
-- Name: journal_entries journal_entries_posted_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entries
    ADD CONSTRAINT journal_entries_posted_by_user_id_fkey FOREIGN KEY (posted_by_user_id) REFERENCES public.users(id);


--
-- Name: journal_entries journal_entries_reverses_same_workspace; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entries
    ADD CONSTRAINT journal_entries_reverses_same_workspace FOREIGN KEY (workspace_id, reverses_entry_id) REFERENCES public.journal_entries(workspace_id, id);


--
-- Name: journal_entries journal_entries_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entries
    ADD CONSTRAINT journal_entries_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: journal_lines journal_lines_account_same_workspace; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_lines
    ADD CONSTRAINT journal_lines_account_same_workspace FOREIGN KEY (workspace_id, account_id) REFERENCES public.accounts(workspace_id, id);


--
-- Name: journal_lines journal_lines_base_currency_matches_workspace; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_lines
    ADD CONSTRAINT journal_lines_base_currency_matches_workspace FOREIGN KEY (workspace_id, base_currency) REFERENCES public.workspaces(id, base_currency);


--
-- Name: journal_lines journal_lines_currency_is_known; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_lines
    ADD CONSTRAINT journal_lines_currency_is_known FOREIGN KEY (currency) REFERENCES public.currencies(code);


--
-- Name: journal_lines journal_lines_entry_same_workspace; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_lines
    ADD CONSTRAINT journal_lines_entry_same_workspace FOREIGN KEY (workspace_id, journal_entry_id) REFERENCES public.journal_entries(workspace_id, id) ON DELETE CASCADE;


--
-- Name: journal_lines journal_lines_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_lines
    ADD CONSTRAINT journal_lines_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: workspace_ai_config workspace_ai_config_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_ai_config
    ADD CONSTRAINT workspace_ai_config_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: workspace_members workspace_members_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_members
    ADD CONSTRAINT workspace_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: workspace_members workspace_members_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_members
    ADD CONSTRAINT workspace_members_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: workspaces workspaces_base_currency_is_known; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspaces
    ADD CONSTRAINT workspaces_base_currency_is_known FOREIGN KEY (base_currency) REFERENCES public.currencies(code);


--
-- Name: accounts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY;

--
-- Name: accounts accounts_workspace_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY accounts_workspace_isolation ON public.accounts USING ((workspace_id = public.app_current_workspace())) WITH CHECK ((workspace_id = public.app_current_workspace()));


--
-- Name: anomaly_flags; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.anomaly_flags ENABLE ROW LEVEL SECURITY;

--
-- Name: anomaly_flags anomaly_flags_workspace_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY anomaly_flags_workspace_isolation ON public.anomaly_flags USING ((workspace_id = public.app_current_workspace())) WITH CHECK ((workspace_id = public.app_current_workspace()));


--
-- Name: categorization_rules; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.categorization_rules ENABLE ROW LEVEL SECURITY;

--
-- Name: categorization_rules categorization_rules_workspace_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY categorization_rules_workspace_isolation ON public.categorization_rules USING ((workspace_id = public.app_current_workspace())) WITH CHECK ((workspace_id = public.app_current_workspace()));


--
-- Name: devices; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY;

--
-- Name: devices devices_workspace_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY devices_workspace_isolation ON public.devices USING ((workspace_id = public.app_current_workspace())) WITH CHECK ((workspace_id = public.app_current_workspace()));


--
-- Name: documents; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.documents ENABLE ROW LEVEL SECURITY;

--
-- Name: documents documents_workspace_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY documents_workspace_isolation ON public.documents USING ((workspace_id = public.app_current_workspace())) WITH CHECK ((workspace_id = public.app_current_workspace()));


--
-- Name: fiscal_years; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.fiscal_years ENABLE ROW LEVEL SECURITY;

--
-- Name: fiscal_years fiscal_years_workspace_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY fiscal_years_workspace_isolation ON public.fiscal_years USING ((workspace_id = public.app_current_workspace())) WITH CHECK ((workspace_id = public.app_current_workspace()));


--
-- Name: journal_entries; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.journal_entries ENABLE ROW LEVEL SECURITY;

--
-- Name: journal_entries journal_entries_workspace_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY journal_entries_workspace_isolation ON public.journal_entries USING ((workspace_id = public.app_current_workspace())) WITH CHECK ((workspace_id = public.app_current_workspace()));


--
-- Name: journal_lines; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.journal_lines ENABLE ROW LEVEL SECURITY;

--
-- Name: journal_lines journal_lines_workspace_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY journal_lines_workspace_isolation ON public.journal_lines USING ((workspace_id = public.app_current_workspace())) WITH CHECK ((workspace_id = public.app_current_workspace()));


--
-- Name: users; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

--
-- Name: users users_visible_to_co_members; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY users_visible_to_co_members ON public.users FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.workspace_members m
  WHERE ((m.user_id = users.id) AND (m.workspace_id = public.app_current_workspace())))));


--
-- Name: workspace_ai_config; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.workspace_ai_config ENABLE ROW LEVEL SECURITY;

--
-- Name: workspace_ai_config workspace_ai_config_workspace_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY workspace_ai_config_workspace_isolation ON public.workspace_ai_config USING ((workspace_id = public.app_current_workspace())) WITH CHECK ((workspace_id = public.app_current_workspace()));


--
-- Name: workspace_members; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.workspace_members ENABLE ROW LEVEL SECURITY;

--
-- Name: workspace_members workspace_members_workspace_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY workspace_members_workspace_isolation ON public.workspace_members USING ((workspace_id = public.app_current_workspace())) WITH CHECK ((workspace_id = public.app_current_workspace()));


--
-- Name: workspaces; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.workspaces ENABLE ROW LEVEL SECURITY;

--
-- Name: workspaces workspaces_workspace_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY workspaces_workspace_isolation ON public.workspaces USING ((id = public.app_current_workspace())) WITH CHECK ((id = public.app_current_workspace()));


--
-- PostgreSQL database dump complete
--


