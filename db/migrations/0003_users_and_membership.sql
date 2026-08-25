-- =============================================================================
-- 0003 -- users, workspace membership, and entry authorship.
--
-- `devices.user_id` has been an unconstrained nullable uuid pointing at
-- nothing since 0001. This gives it something to point at, and gives the
-- workspace boundary a notion of who is inside it.
--
-- Identity is deliberately global while membership is per-workspace. A person
-- with books for two companies is one person; `users` is therefore the second
-- documented exception to "workspace_id on every table", after `currencies`.
-- The tenant-scoped table is `workspace_members`, and that is what RLS keys
-- off in 0004.
--
-- NOT IN SCOPE HERE: authentication. No password hashes, no OIDC subject, no
-- sessions. How a user proves who they are is undecided and differs by
-- deployment -- the desktop app may have no login at all, while hosted needs
-- one -- and guessing at it now would bake a choice into the ledger schema.
-- `users` is identity storage; credentials get their own table when that
-- decision is made.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Users
-- -----------------------------------------------------------------------------

CREATE TABLE users (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email         text NOT NULL CHECK (length(trim(email)) > 0),
    display_name  text,
    -- Deactivation rather than deletion: a user who posted entries is part of
    -- the audit trail and must remain resolvable after they leave.
    is_active     boolean NOT NULL DEFAULT true,
    version       integer NOT NULL DEFAULT 1,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);

-- Case-insensitive uniqueness without the citext extension, which would be one
-- more thing to install on managed Postgres and the embedded desktop instance.
CREATE UNIQUE INDEX uq_users_email_lower ON users (lower(email));

CREATE TRIGGER trg_users_version
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION guard_mutable_row();


-- -----------------------------------------------------------------------------
-- Membership: who is in a workspace, and what they may do
-- -----------------------------------------------------------------------------

-- Three roles, not four. `admin` was considered and left out: with `owner`
-- able to manage members and `bookkeeper` able to do everything to the ledger,
-- an intermediate tier has no distinct capability yet. It is a CHECK value, so
-- adding one later is a one-line migration -- inventing one now is a guess
-- that the UI would have to explain.
CREATE TABLE workspace_members (
    workspace_id  uuid NOT NULL REFERENCES workspaces (id) ON DELETE CASCADE,
    user_id       uuid NOT NULL REFERENCES users (id)      ON DELETE CASCADE,
    role          text NOT NULL CHECK (role IN ('owner', 'bookkeeper', 'viewer')),
    version       integer NOT NULL DEFAULT 1,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (workspace_id, user_id)
);

CREATE INDEX idx_workspace_members_user ON workspace_members (user_id);

CREATE TRIGGER trg_workspace_members_version
    BEFORE UPDATE ON workspace_members
    FOR EACH ROW EXECUTE FUNCTION guard_mutable_row();


-- A workspace whose last owner is removed or demoted cannot be administered by
-- anyone, and no application-level check survives a second device syncing a
-- membership change. Cross-row, so it cannot be a CHECK constraint.
CREATE OR REPLACE FUNCTION guard_workspace_keeps_an_owner() RETURNS trigger AS $fn$
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
$fn$ LANGUAGE plpgsql;

CREATE TRIGGER trg_workspace_members_keep_an_owner
    BEFORE UPDATE OR DELETE ON workspace_members
    FOR EACH ROW EXECUTE FUNCTION guard_workspace_keeps_an_owner();


-- -----------------------------------------------------------------------------
-- Devices belong to a member of their workspace
-- -----------------------------------------------------------------------------

-- Composite foreign key, the same trick used throughout: a device cannot be
-- attributed to someone who is not in its workspace. `user_id` stays nullable
-- for server-side installs with no identity model wired up yet, and a NULL
-- satisfies the constraint.
ALTER TABLE devices
    ADD CONSTRAINT devices_user_is_a_member
        FOREIGN KEY (workspace_id, user_id)
        REFERENCES workspace_members (workspace_id, user_id);


-- -----------------------------------------------------------------------------
-- Entry authorship
-- -----------------------------------------------------------------------------

-- Added now, while the ledger is empty, for the same reason the currency
-- columns were: journal_entries is immutable once posted, so a column added
-- later can never be backfilled for existing rows without disabling the
-- immutability trigger and rewriting posted history.
--
-- Plain reference to `users`, NOT a composite key into workspace_members. A
-- membership can be revoked, and revoking it must not rewrite or block who
-- authored past entries -- that is what an audit trail is for. The workspace
-- match is enforced at INSERT time instead, below, which is when it is
-- actually a question.
ALTER TABLE journal_entries
    ADD COLUMN created_by_user_id uuid REFERENCES users (id),
    -- Which device is already recorded; this is which person.
    ADD COLUMN posted_by_user_id  uuid REFERENCES users (id);

CREATE INDEX idx_journal_entries_author
    ON journal_entries (workspace_id, created_by_user_id);

CREATE OR REPLACE FUNCTION guard_entry_author_is_a_member() RETURNS trigger AS $fn$
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
$fn$ LANGUAGE plpgsql;

-- INSERT only. An entry's author is checked when the entry is written; later
-- membership changes leave history alone.
CREATE TRIGGER trg_journal_entries_author_is_a_member
    BEFORE INSERT ON journal_entries
    FOR EACH ROW EXECUTE FUNCTION guard_entry_author_is_a_member();
