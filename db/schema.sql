-- Core double-entry ledger schema.
--
-- Sync design (see ARCHITECTURE.md): every table carries `workspace_id` as
-- the tenant boundary from day one. Posted journal entries are append-only —
-- never UPDATEd — so multi-device sync via ElectricSQL has nothing to merge
-- once something is posted. Mutable "draft" tables carry a `version` column
-- for optimistic concurrency instead.

create extension if not exists "uuid-ossp";

create table workspaces (
    id uuid primary key default uuid_generate_v4(),
    name text not null,
    base_currency text not null default 'USD',
    created_at timestamptz not null default now()
);

-- The single seam the AI abstraction layer reads from. Switching a workspace
-- between "cloud with API key" and "fully offline" is one row update here —
-- no redeploy, no code branch.
create table workspace_ai_config (
    workspace_id uuid primary key references workspaces(id) on delete cascade,
    mode text not null,               -- e.g. 'cloud_openai' | 'cloud_anthropic' | 'local_ollama'
    model text not null,
    api_key_encrypted text,           -- encrypted at rest; never logged, never returned by API
    api_base text,                    -- custom endpoint or local Ollama host
    organization text,
    updated_at timestamptz not null default now()
);

create table accounts (
    id uuid primary key default uuid_generate_v4(),
    workspace_id uuid not null references workspaces(id) on delete cascade,
    code text not null,
    name text not null,
    type text not null check (type in ('asset','liability','equity','revenue','expense')),
    parent_account_id uuid references accounts(id),
    is_archived boolean not null default false,
    version integer not null default 1,
    updated_at timestamptz not null default now(),
    unique (workspace_id, code)
);

-- Append-only by convention (enforce in application layer + a trigger, see
-- below). Corrections are reversing entries, never edits to posted rows.
create table journal_entries (
    id uuid primary key default uuid_generate_v4(),
    workspace_id uuid not null references workspaces(id) on delete cascade,
    entry_date date not null,
    memo text,
    source text not null default 'manual',    -- 'manual' | 'ocr_import' | 'ai_categorized'
    created_by_device_id uuid not null,
    posted_at timestamptz,                    -- null while still a draft
    version integer not null default 1,       -- only meaningful pre-posting
    updated_at timestamptz not null default now()
);

create table journal_lines (
    id uuid primary key default uuid_generate_v4(),
    journal_entry_id uuid not null references journal_entries(id) on delete cascade,
    account_id uuid not null references accounts(id),
    debit numeric(18,2) not null default 0,
    credit numeric(18,2) not null default 0,
    memo text,
    check (debit = 0 or credit = 0)
);

-- Prevents mutation of already-posted entries at the database level, not
-- just in application code — this is what makes the sync story safe.
create or replace function forbid_posted_entry_mutation() returns trigger as $$
begin
    if old.posted_at is not null then
        raise exception 'journal_entries: cannot modify a posted entry (id=%). Use a reversing entry instead.', old.id;
    end if;
    return new;
end;
$$ language plpgsql;

create trigger trg_forbid_posted_entry_mutation
    before update on journal_entries
    for each row execute function forbid_posted_entry_mutation();

create table documents (
    id uuid primary key default uuid_generate_v4(),
    workspace_id uuid not null references workspaces(id) on delete cascade,
    kind text not null check (kind in ('receipt','invoice','statement')),
    file_path text not null,
    ocr_status text not null default 'pending',   -- pending | processing | done | failed
    ocr_raw_text text,
    extracted_fields jsonb,               -- vendor, line items, amounts, tax — from AI extraction
    linked_journal_entry_id uuid references journal_entries(id),
    created_at timestamptz not null default now()
);

create table categorization_rules (
    id uuid primary key default uuid_generate_v4(),
    workspace_id uuid not null references workspaces(id) on delete cascade,
    match_pattern text not null,
    account_id uuid not null references accounts(id),
    confidence_source text not null default 'user',   -- 'user' | 'ai_suggested'
    version integer not null default 1,
    updated_at timestamptz not null default now()
);

create table anomaly_flags (
    id uuid primary key default uuid_generate_v4(),
    workspace_id uuid not null references workspaces(id) on delete cascade,
    journal_entry_id uuid references journal_entries(id),
    reason text not null,                 -- human-readable explanation, AI-generated
    severity text not null check (severity in ('low','medium','high')),
    resolved boolean not null default false,
    created_at timestamptz not null default now()
);

-- Every connected desktop instance, for the cowork/on-prem realtime feature.
create table devices (
    id uuid primary key default uuid_generate_v4(),
    workspace_id uuid not null references workspaces(id) on delete cascade,
    user_id uuid not null,
    label text,
    last_seen_at timestamptz not null default now()
);

create index idx_journal_entries_workspace on journal_entries(workspace_id);
create index idx_journal_lines_entry on journal_lines(journal_entry_id);
create index idx_documents_workspace on documents(workspace_id);
