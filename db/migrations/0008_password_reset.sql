-- =============================================================================
-- 0008 -- password reset tokens.
--
-- Same shape as `sessions` (0007): identity-scoped, no workspace_id, and the
-- same ordering-safe RLS policy pattern -- `current_user = 'accounting_auth'`
-- rather than `TO accounting_auth`, because migrations run before
-- db/roles.sql (see 0007's header) and the role does not exist yet when this
-- file applies to a fresh database.
--
-- `used_at`, not deleting the row on use: a used or expired token staying
-- around is what lets a replay attempt be told apart from "no such token" if
-- that ever needs investigating, the same reasoning `sessions.revoked_at`
-- uses instead of deleting on logout.
-- =============================================================================

CREATE TABLE password_reset_tokens (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash  text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    used_at     timestamptz
);

CREATE UNIQUE INDEX uq_password_reset_tokens_token_hash ON password_reset_tokens (token_hash);
CREATE INDEX idx_password_reset_tokens_user ON password_reset_tokens (user_id);

ALTER TABLE password_reset_tokens ENABLE ROW LEVEL SECURITY;

CREATE POLICY password_reset_tokens_auth_only ON password_reset_tokens FOR ALL
    USING (current_user = 'accounting_auth')
    WITH CHECK (current_user = 'accounting_auth');
