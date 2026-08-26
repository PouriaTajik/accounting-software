-- =============================================================================
-- Auth role hardening verification.
--
-- roles.sql claims accounting_auth cannot reach any ledger table, and that
-- accounting_app cannot reach credentials or sessions. This proves both, the
-- same way verify_roles.sql proves nl_query's boundary. Runs inside a
-- transaction that is rolled back, so it is safe against a live database (a
-- scratch one is still the sane choice).
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/schema.sql
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--        -v nl_query_password="'<secret>'" -v app_password="'<secret>'" \
--        -v auth_password="'<secret>'" -f db/roles.sql
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/verify_auth.sql
--
-- Run as the role that created accounting_auth/accounting_app: the script
-- grants both to itself so it can SET ROLE into them, and rolls that grant
-- back at the end along with everything else.
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

DO $precheck$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'accounting_auth') THEN
        RAISE EXCEPTION
            'role accounting_auth does not exist -- apply db/roles.sql before this script'
            USING HINT = 'psql "$DATABASE_URL" -v auth_password=''''<secret>'''' -f db/roles.sql';
    END IF;
END;
$precheck$;

CREATE FUNCTION pg_temp.assert_rejects(stmt text, label text) RETURNS void AS $fn$
BEGIN
    BEGIN
        EXECUTE stmt;
    EXCEPTION WHEN others THEN
        RAISE NOTICE 'PASS  % -- rejected: %', label, sqlerrm;
        RETURN;
    END;
    RAISE EXCEPTION 'FAIL  % -- was ALLOWED something it must not be', label;
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


-- --- fixtures: two tenants, a user in each, one shared user in both -----------

DO $seed$
DECLARE
    ws        uuid;
    other_ws  uuid;
    alice     uuid;
    bob       uuid;
BEGIN
    INSERT INTO workspaces (name) VALUES ('Auth Co') RETURNING id INTO ws;
    INSERT INTO workspaces (name) VALUES ('Other Auth Co') RETURNING id INTO other_ws;

    INSERT INTO users (email, display_name) VALUES ('alice@example.test', 'Alice')
        RETURNING id INTO alice;
    -- Bob belongs to both workspaces -- proves membership visibility is
    -- global for accounting_auth, not "whichever workspace happened to be
    -- seeded first".
    INSERT INTO users (email, display_name) VALUES ('bob@example.test', 'Bob')
        RETURNING id INTO bob;

    INSERT INTO workspace_members (workspace_id, user_id, role) VALUES (ws, alice, 'owner');
    INSERT INTO workspace_members (workspace_id, user_id, role) VALUES (ws, bob, 'bookkeeper');
    INSERT INTO workspace_members (workspace_id, user_id, role) VALUES (other_ws, bob, 'viewer');

    INSERT INTO user_credentials (user_id, password_hash) VALUES (alice, 'not-a-real-hash');

    INSERT INTO accounts (workspace_id, code, name, type)
         VALUES (ws, '1000', 'Cash', 'asset');

    PERFORM set_config('verify.ws', ws::text, false);
    PERFORM set_config('verify.other_ws', other_ws::text, false);
    PERFORM set_config('verify.alice', alice::text, false);
    PERFORM set_config('verify.bob', bob::text, false);
END;
$seed$;


-- --- grants that outlive the role switch --------------------------------------
-- Rolled back with the transaction.
DO $grant$
BEGIN
    EXECUTE format('GRANT accounting_auth TO %I', current_user);
    EXECUTE format('GRANT accounting_app TO %I', current_user);
END;
$grant$;


-- --- checks that must run as accounting_auth ----------------------------------

SET LOCAL ROLE accounting_auth;

DO $verify_auth$
DECLARE
    ws        uuid := current_setting('verify.ws')::uuid;
    other_ws  uuid := current_setting('verify.other_ws')::uuid;
    alice     uuid := current_setting('verify.alice')::uuid;
    bob       uuid := current_setting('verify.bob')::uuid;
    v_count   integer;
BEGIN
    -- 1. No reach into ledger data whatsoever -- this role exists to answer
    --    "who is this session", never "what is in the books".
    PERFORM pg_temp.assert_rejects(
        'SELECT * FROM public.accounts',
        'accounting_auth reading the accounts base table');
    PERFORM pg_temp.assert_rejects(
        'SELECT * FROM public.journal_entries',
        'accounting_auth reading the journal_entries base table');
    PERFORM pg_temp.assert_rejects(
        'SELECT * FROM public.journal_lines',
        'accounting_auth reading the journal_lines base table');
    PERFORM pg_temp.assert_rejects(
        'SELECT * FROM public.documents',
        'accounting_auth reading the documents base table');
    PERFORM pg_temp.assert_rejects(
        'SELECT * FROM public.workspace_ai_config',
        'accounting_auth reading stored AI credentials');
    PERFORM pg_temp.assert_rejects(
        'INSERT INTO public.workspace_members (workspace_id, user_id, role)
         VALUES (' || quote_literal(ws) || ', ' || quote_literal(alice) || ', ''owner'')',
        'accounting_auth writing workspace_members -- read-only by design');

    -- 2. Identity is global: no app.workspace_id is ever set for this role,
    --    and it can still see users and memberships across both tenants.
    --    This is the read the whole role exists for.
    SELECT count(*) INTO v_count FROM users WHERE id IN (alice, bob);
    PERFORM pg_temp.assert(v_count = 2,
        'accounting_auth reads users across every tenant, unscoped');

    SELECT count(*) INTO v_count FROM workspace_members WHERE user_id = bob;
    PERFORM pg_temp.assert(v_count = 2,
        'accounting_auth reads a user''s memberships in both workspaces at once');

    PERFORM pg_temp.assert(
        (SELECT role FROM workspace_members WHERE workspace_id = other_ws AND user_id = bob) = 'viewer',
        'accounting_auth sees the correct role per workspace, not just membership');

    -- 3. Registration's actual shape: insert a user, then their credentials.
    INSERT INTO users (email, display_name) VALUES ('carol@example.test', 'Carol');
    SELECT count(*) INTO v_count FROM users WHERE email = 'carol@example.test';
    PERFORM pg_temp.assert(v_count = 1,
        'accounting_auth can insert a new user (registration)');

    INSERT INTO user_credentials (user_id, password_hash)
         SELECT id, 'another-not-real-hash' FROM users WHERE email = 'carol@example.test';
    SELECT count(*) INTO v_count FROM user_credentials uc
     JOIN users u ON u.id = uc.user_id WHERE u.email = 'carol@example.test';
    PERFORM pg_temp.assert(v_count = 1,
        'accounting_auth can insert credentials for a user it just created');

    -- 4. Sessions: create, then read back by a fresh connection's-eye view
    --    (still this role, which is the point -- it owns the whole
    --    lifecycle).
    INSERT INTO sessions (user_id, token_hash, expires_at)
         VALUES (alice, 'deadbeef', now() + interval '1 day');

    SELECT count(*) INTO v_count FROM sessions WHERE token_hash = 'deadbeef';
    PERFORM pg_temp.assert(v_count = 1, 'accounting_auth can read the session back');

    UPDATE sessions SET revoked_at = now() WHERE token_hash = 'deadbeef';
    SELECT count(*) INTO v_count FROM sessions
     WHERE token_hash = 'deadbeef' AND revoked_at IS NOT NULL;
    PERFORM pg_temp.assert(v_count = 1, 'accounting_auth can revoke a session (logout)');

    -- 5. Password reset tokens: same create/read/mark-used lifecycle as
    --    sessions (0008).
    INSERT INTO password_reset_tokens (user_id, token_hash, expires_at)
         VALUES (alice, 'reset-token-hash', now() + interval '30 minutes');

    SELECT count(*) INTO v_count FROM password_reset_tokens WHERE token_hash = 'reset-token-hash';
    PERFORM pg_temp.assert(v_count = 1, 'accounting_auth can read a reset token back');

    UPDATE password_reset_tokens SET used_at = now() WHERE token_hash = 'reset-token-hash';
    SELECT count(*) INTO v_count FROM password_reset_tokens
     WHERE token_hash = 'reset-token-hash' AND used_at IS NOT NULL;
    PERFORM pg_temp.assert(v_count = 1, 'accounting_auth can mark a reset token used');
END;
$verify_auth$;

RESET ROLE;


-- --- checks that must run as accounting_app -----------------------------------
-- The mirror image: the role every ordinary request runs as must be unable
-- to reach credentials, sessions, or reset tokens at all, even though its
-- blanket grant on "ALL TABLES IN SCHEMA public" would otherwise cover all
-- three by default.

SET LOCAL ROLE accounting_app;

DO $verify_app$
DECLARE
    ws uuid := current_setting('verify.ws')::uuid;
BEGIN
    PERFORM set_config('app.workspace_id', ws::text, true);

    PERFORM pg_temp.assert_rejects(
        'SELECT * FROM public.user_credentials',
        'accounting_app reading password hashes');
    PERFORM pg_temp.assert_rejects(
        'SELECT * FROM public.sessions',
        'accounting_app reading session tokens');
    PERFORM pg_temp.assert_rejects(
        'INSERT INTO public.sessions (user_id, token_hash, expires_at)
         VALUES (' || quote_literal(current_setting('verify.alice')) || ', ''forged'', now())',
        'accounting_app forging a session');
    PERFORM pg_temp.assert_rejects(
        'SELECT * FROM public.password_reset_tokens',
        'accounting_app reading password reset tokens');
    PERFORM pg_temp.assert_rejects(
        'INSERT INTO public.password_reset_tokens (user_id, token_hash, expires_at)
         VALUES (' || quote_literal(current_setting('verify.alice')) || ', ''forged'', now())',
        'accounting_app forging a reset token');

    -- Not merely blocked by RLS -- ungranted outright, same assertion shape
    -- verify_roles.sql uses for nl_query's boundary.
    PERFORM pg_temp.assert(
        NOT has_table_privilege('accounting_app', 'public.user_credentials', 'SELECT'),
        'accounting_app holds no SELECT privilege on user_credentials at all');
    PERFORM pg_temp.assert(
        NOT has_table_privilege('accounting_app', 'public.sessions', 'SELECT'),
        'accounting_app holds no SELECT privilege on sessions at all');
    PERFORM pg_temp.assert(
        NOT has_table_privilege('accounting_app', 'public.password_reset_tokens', 'SELECT'),
        'accounting_app holds no SELECT privilege on password_reset_tokens at all');

    RAISE NOTICE '=== ALL AUTH CHECKS PASSED ===';
END;
$verify_app$;

RESET ROLE;

ROLLBACK;
