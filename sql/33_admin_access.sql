-- =============================================================================
-- 33. Opening Admin
--
-- Everyday work stays as it is: tap your name and go. Picking a name is a
-- profile, not proof, and that is fine for checking a dog in. Admin is
-- different: verifying shots, fixing dates, clearing allergy changes. Until
-- now anyone could tap a manager's name and do all of it.
--
-- Admin now opens only for a manager who proves it is them, one of two ways:
--
--   * A passkey: the fingerprint, face or PIN of a device the manager owns,
--     their phone scanned from the counter tablet, or a laptop's own sign-in.
--     The shop never sees the fingerprint; the device signs a one-time
--     challenge and the backend checks the signature against the public key
--     kept here (manager_passkey). The checking is the standard WebAuthn
--     library's job (api/app/passkeys.py); this section keeps the keys and
--     decides who they open Admin for.
--   * A PIN, 4 to 8 digits, for a dead phone. Kept hashed (bcrypt). Five wrong
--     tries in a row lock PIN entry for fifteen minutes; a passkey still works.
--
-- Opening Admin starts a session of 30 minutes (shop_policy), then it locks
-- again. The backend keeps a random token per session and this table only its
-- hash, so a copy of the database opens nothing.
--
-- Setting up: a manager with no PIN and no passkey yet sets one up the first
-- time they open Admin, which is the only moment nobody has to vouch for them.
-- After that only that manager, with Admin open, changes their own PIN or
-- passkeys, and the last way in cannot be removed.
--
--   GR036  Admin opened by someone who isn't a manager, with a wrong PIN, too
--          many tries, or a passkey that isn't theirs
--   GR037  a manager's PIN or passkeys changed by anyone but that manager,
--          verified, or the last way in removed
-- =============================================================================

SET search_path = groom, public;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;

INSERT INTO policy_enforcement (error_code, level, relaxable, description) VALUES
  ('GR036', 'block', false, 'Admin opened without a manager''s own passkey or PIN'),
  ('GR037', 'block', false, 'A manager''s Admin access changed by anyone but that manager');

INSERT INTO shop_policy (key, value_type, int_value, description) VALUES
  ('admin_session_minutes', 'integer', 30, 'How long Admin stays open after a manager verifies.'),
  ('admin_pin_tries',       'integer', 5,  'Wrong PINs in a row before PIN entry is locked.'),
  ('admin_pin_lock_minutes','integer', 15, 'How long PIN entry stays locked after too many wrong tries.');

ALTER TABLE groomer ADD COLUMN admin_pin_hash text;
COMMENT ON COLUMN groomer.admin_pin_hash IS 'bcrypt hash of the manager''s Admin PIN. Never the PIN itself.';

CREATE TABLE manager_passkey (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    groomer_id     uuid NOT NULL REFERENCES groomer(id) ON DELETE RESTRICT,
    credential_id  bytea NOT NULL UNIQUE,
    public_key     bytea NOT NULL,
    sign_count     bigint NOT NULL DEFAULT 0 CHECK (sign_count >= 0),
    label          text NOT NULL,
    added_at       timestamptz NOT NULL DEFAULT now(),
    last_used_at   timestamptz
);
CREATE INDEX manager_passkey_groomer_idx ON manager_passkey (groomer_id);
COMMENT ON TABLE manager_passkey IS
  'A manager''s passkey: the public half only. The private key never leaves their device.';

CREATE TABLE admin_session (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    groomer_id  uuid NOT NULL REFERENCES groomer(id) ON DELETE RESTRICT,
    token_hash  text NOT NULL UNIQUE,
    opened_with text NOT NULL CHECK (opened_with IN ('passkey', 'pin', 'setup')),
    opened_at   timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    closed_at   timestamptz
);

-- Every try at opening Admin, right or wrong: the PIN lock counts these, and
-- a manager can see if someone has been guessing.
CREATE TABLE admin_access_attempt (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    groomer_id   uuid NOT NULL REFERENCES groomer(id) ON DELETE RESTRICT,
    method       text NOT NULL CHECK (method IN ('passkey', 'pin')),
    succeeded    boolean NOT NULL,
    attempted_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX admin_access_attempt_idx ON admin_access_attempt (groomer_id, attempted_at DESC);

-- A passkey ceremony's one-time challenge, good for five minutes, used once.
CREATE TABLE passkey_challenge (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    groomer_id  uuid NOT NULL REFERENCES groomer(id) ON DELETE CASCADE,
    purpose     text NOT NULL CHECK (purpose IN ('register', 'open')),
    challenge   bytea NOT NULL,
    expires_at  timestamptz NOT NULL DEFAULT now() + interval '5 minutes'
);

-- -----------------------------------------------------------------------------
-- Who may do what
-- -----------------------------------------------------------------------------

CREATE FUNCTION is_active_manager(p_groomer_id uuid) RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM groomer g WHERE g.id = p_groomer_id AND g.is_active AND g.role = 'manager')
$$;

-- The manager whose Admin this token opens, or NULL: unknown, locked, run out,
-- or no longer a manager.
CREATE FUNCTION admin_session_manager(p_token_hash text) RETURNS uuid
LANGUAGE sql STABLE AS $$
    SELECT s.groomer_id FROM admin_session s
     WHERE s.token_hash = p_token_hash AND s.closed_at IS NULL AND s.expires_at > now()
       AND is_active_manager(s.groomer_id)
$$;

-- A manager with no PIN and no passkey has never set up Admin.
CREATE FUNCTION admin_is_set_up(p_groomer_id uuid) RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM groomer g WHERE g.id = p_groomer_id AND g.admin_pin_hash IS NOT NULL)
        OR EXISTS (SELECT 1 FROM manager_passkey k WHERE k.groomer_id = p_groomer_id)
$$;

-- That manager, verified; or their very first setup. Never NULL: with no
-- session the comparison is unknown, and unknown must mean no.
CREATE FUNCTION may_change_admin_access(p_groomer_id uuid, p_token_hash text) RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT is_active_manager(p_groomer_id)
       AND (COALESCE(admin_session_manager(p_token_hash) = p_groomer_id, false)
            OR NOT admin_is_set_up(p_groomer_id))
$$;

CREATE FUNCTION require_may_change_admin_access(p_groomer_id uuid, p_token_hash text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT may_change_admin_access(p_groomer_id, p_token_hash) THEN
        RAISE EXCEPTION 'Only that manager, with Admin open, can change how they open Admin'
            USING ERRCODE = 'GR037',
                  HINT = 'Open Admin as yourself first.';
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- Opening and closing
-- -----------------------------------------------------------------------------

CREATE FUNCTION open_admin_session(p_groomer_id uuid, p_with text, p_token_hash text) RETURNS timestamptz
LANGUAGE plpgsql AS $$
DECLARE
    v_expires timestamptz := now() + make_interval(mins => shop_policy_int('admin_session_minutes'));
BEGIN
    IF NOT is_active_manager(p_groomer_id) THEN
        RAISE EXCEPTION 'Only a manager can open Admin' USING ERRCODE = 'GR036';
    END IF;
    INSERT INTO admin_session (groomer_id, token_hash, opened_with, expires_at)
    VALUES (p_groomer_id, p_token_hash, p_with, v_expires);
    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    SELECT p_groomer_id, g.display_name, 'view', 'admin_session', p_groomer_id,
           jsonb_build_object('opened_with', p_with, 'until', v_expires)
      FROM groomer g WHERE g.id = p_groomer_id;
    RETURN v_expires;
END $$;

-- Returns when Admin locks again, or NULL for a wrong PIN. A wrong PIN is
-- recorded and then answered with NULL rather than raised: raising would roll
-- the record of the try back, and the lock would never count it.
CREATE FUNCTION open_admin_with_pin(p_groomer_id uuid, p_pin text, p_token_hash text) RETURNS timestamptz
LANGUAGE plpgsql AS $$
DECLARE
    v_hash  text;
    v_wrong integer;
BEGIN
    IF NOT is_active_manager(p_groomer_id) THEN
        RAISE EXCEPTION 'Only a manager can open Admin' USING ERRCODE = 'GR036';
    END IF;
    SELECT admin_pin_hash INTO v_hash FROM groomer WHERE id = p_groomer_id;
    IF v_hash IS NULL THEN
        RAISE EXCEPTION 'No Admin PIN is set up for this manager' USING ERRCODE = 'GR036',
              HINT = 'Use a passkey instead.';
    END IF;

    -- Wrong tries since the last right one, within the lock window.
    SELECT count(*) INTO v_wrong FROM admin_access_attempt a
     WHERE a.groomer_id = p_groomer_id AND a.method = 'pin' AND NOT a.succeeded
       AND a.attempted_at > now() - make_interval(mins => shop_policy_int('admin_pin_lock_minutes'))
       AND a.attempted_at > COALESCE((SELECT max(s.attempted_at) FROM admin_access_attempt s
                                       WHERE s.groomer_id = p_groomer_id AND s.succeeded), '-infinity');
    IF v_wrong >= shop_policy_int('admin_pin_tries') THEN
        RAISE EXCEPTION 'Too many wrong PINs' USING ERRCODE = 'GR036',
              HINT = format('PIN entry is locked for up to %s minutes. A passkey still works.',
                            shop_policy_int('admin_pin_lock_minutes'));
    END IF;

    IF crypt(p_pin, v_hash) <> v_hash THEN
        INSERT INTO admin_access_attempt (groomer_id, method, succeeded) VALUES (p_groomer_id, 'pin', false);
        RETURN NULL;
    END IF;
    INSERT INTO admin_access_attempt (groomer_id, method, succeeded) VALUES (p_groomer_id, 'pin', true);
    RETURN open_admin_session(p_groomer_id, 'pin', p_token_hash);
END $$;

-- Called once the backend has checked the passkey's signature. Here: is it
-- this manager's passkey? Its counter moves on, so a copied key shows up.
CREATE FUNCTION open_admin_with_passkey(p_groomer_id uuid, p_credential_id bytea, p_sign_count bigint,
                                        p_token_hash text) RETURNS timestamptz
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE manager_passkey SET sign_count = GREATEST(sign_count, p_sign_count), last_used_at = now()
     WHERE credential_id = p_credential_id AND groomer_id = p_groomer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'That passkey doesn''t open Admin for this manager' USING ERRCODE = 'GR036',
              HINT = 'Use your own phone or device, or your PIN.';
    END IF;
    INSERT INTO admin_access_attempt (groomer_id, method, succeeded) VALUES (p_groomer_id, 'passkey', true);
    RETURN open_admin_session(p_groomer_id, 'passkey', p_token_hash);
END $$;

CREATE FUNCTION close_admin_session(p_token_hash text) RETURNS void
LANGUAGE sql AS $$
    UPDATE admin_session SET closed_at = now() WHERE token_hash = p_token_hash AND closed_at IS NULL
$$;

-- -----------------------------------------------------------------------------
-- Setting up and changing
-- -----------------------------------------------------------------------------

CREATE FUNCTION set_admin_pin(p_groomer_id uuid, p_pin text, p_token_hash text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM require_may_change_admin_access(p_groomer_id, p_token_hash);
    IF p_pin IS NULL OR p_pin !~ '^[0-9]{4,8}$' THEN
        RAISE EXCEPTION 'A PIN is 4 to 8 digits' USING ERRCODE = 'check_violation';
    END IF;
    UPDATE groomer SET admin_pin_hash = crypt(p_pin, gen_salt('bf', 8)) WHERE id = p_groomer_id;
    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    SELECT p_groomer_id, g.display_name, 'update', 'groomer', p_groomer_id,
           jsonb_build_object('admin_pin', 'set')
      FROM groomer g WHERE g.id = p_groomer_id;
END $$;

CREATE FUNCTION add_manager_passkey(p_groomer_id uuid, p_credential_id bytea, p_public_key bytea,
                                    p_sign_count bigint, p_label text, p_token_hash text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v_id uuid;
BEGIN
    PERFORM require_may_change_admin_access(p_groomer_id, p_token_hash);
    INSERT INTO manager_passkey (groomer_id, credential_id, public_key, sign_count, label)
    VALUES (p_groomer_id, p_credential_id, p_public_key, p_sign_count,
            COALESCE(nullif_blank(p_label), 'Passkey'))
    RETURNING id INTO v_id;
    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    SELECT p_groomer_id, g.display_name, 'create', 'manager_passkey', v_id,
           jsonb_build_object('label', COALESCE(nullif_blank(p_label), 'Passkey'))
      FROM groomer g WHERE g.id = p_groomer_id;
    RETURN v_id;
END $$;

CREATE FUNCTION remove_manager_passkey(p_passkey_id uuid, p_token_hash text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_key manager_passkey;
BEGIN
    SELECT * INTO v_key FROM manager_passkey WHERE id = p_passkey_id;
    IF NOT FOUND OR admin_session_manager(p_token_hash) IS DISTINCT FROM v_key.groomer_id THEN
        RAISE EXCEPTION 'Only that manager, with Admin open, can remove their passkey' USING ERRCODE = 'GR037';
    END IF;
    -- Removing the last way in would leave Admin "not set up": open to whoever taps the name.
    IF NOT EXISTS (SELECT 1 FROM manager_passkey k WHERE k.groomer_id = v_key.groomer_id AND k.id <> v_key.id)
       AND (SELECT admin_pin_hash FROM groomer WHERE id = v_key.groomer_id) IS NULL THEN
        RAISE EXCEPTION 'That is your only way into Admin' USING ERRCODE = 'GR037',
              HINT = 'Set a PIN or add another passkey first.';
    END IF;
    DELETE FROM manager_passkey WHERE id = p_passkey_id;
    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    SELECT v_key.groomer_id, g.display_name, 'delete', 'manager_passkey', v_key.id,
           jsonb_build_object('label', v_key.label)
      FROM groomer g WHERE g.id = v_key.groomer_id;
END $$;

-- -----------------------------------------------------------------------------
-- Challenges
-- -----------------------------------------------------------------------------

CREATE FUNCTION new_passkey_challenge(p_groomer_id uuid, p_purpose text, p_challenge bytea) RETURNS void
LANGUAGE sql AS $$
    DELETE FROM passkey_challenge WHERE expires_at < now() OR (groomer_id = p_groomer_id AND purpose = p_purpose);
    INSERT INTO passkey_challenge (groomer_id, purpose, challenge) VALUES (p_groomer_id, p_purpose, p_challenge);
$$;

-- The challenge, used up: each one opens at most one ceremony.
CREATE FUNCTION take_passkey_challenge(p_groomer_id uuid, p_purpose text) RETURNS bytea
LANGUAGE sql AS $$
    DELETE FROM passkey_challenge
     WHERE groomer_id = p_groomer_id AND purpose = p_purpose AND expires_at > now()
    RETURNING challenge
$$;

ALTER FUNCTION is_active_manager(uuid)                         SET search_path = groom, public;
ALTER FUNCTION admin_session_manager(text)                     SET search_path = groom, public;
ALTER FUNCTION admin_is_set_up(uuid)                           SET search_path = groom, public;
ALTER FUNCTION may_change_admin_access(uuid, text)             SET search_path = groom, public;
ALTER FUNCTION require_may_change_admin_access(uuid, text)     SET search_path = groom, public;
ALTER FUNCTION open_admin_session(uuid, text, text)            SET search_path = groom, public;
ALTER FUNCTION open_admin_with_pin(uuid, text, text)           SET search_path = groom, public;
ALTER FUNCTION open_admin_with_passkey(uuid, bytea, bigint, text) SET search_path = groom, public;
ALTER FUNCTION close_admin_session(text)                       SET search_path = groom, public;
ALTER FUNCTION set_admin_pin(uuid, text, text)                 SET search_path = groom, public;
ALTER FUNCTION add_manager_passkey(uuid, bytea, bytea, bigint, text, text) SET search_path = groom, public;
ALTER FUNCTION remove_manager_passkey(uuid, text)              SET search_path = groom, public;
ALTER FUNCTION new_passkey_challenge(uuid, text, bytea)        SET search_path = groom, public;
ALTER FUNCTION take_passkey_challenge(uuid, text)              SET search_path = groom, public;
