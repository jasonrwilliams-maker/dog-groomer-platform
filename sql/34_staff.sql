-- =============================================================================
-- 34. Staff
--
-- The staff list was rows typed in by hand. A manager now keeps it from
-- Admin: add someone (name, email, groomer or manager), put their name or
-- email right, change their role, and mark them as no longer working here.
--
-- Nobody is ever deleted. Their name is on visits, bookings, checked shots,
-- notes and the audit log, and those stay as they were. Someone who has left
-- is marked so (is_active false): gone from the Welcome screen and from the
-- groomers a booking can go to, still named on every past record. If they
-- come back, they are marked as working here again.
--
-- Every change is made by a manager with Admin open: the session token's
-- hash says who, not a name picked on the screen. Every change is in the
-- audit log, before and after.
--
-- The shop always has at least one active manager. Without one nobody could
-- open Admin, and nobody could make a manager either. So the last manager
-- can't be made a groomer or marked as gone, by themselves or anyone else.
--
-- Resetting a manager's Admin access, for a lost or replaced phone:
--
--   Section 33 lets only that manager change their own PIN and passkeys
--   (GR037). A lost phone breaks that: their passkey is on it, and if they
--   have no PIN, or forgot it, nobody can get them back in.
--
--   The reset is one narrow exception, and it only takes away. Another
--   manager, with their own Admin open, removes every passkey and the PIN of
--   that manager and locks any Admin they have open. It sets nothing: the
--   manager who was reset sets up a new PIN or passkey themselves, the next
--   time they open Admin, exactly as on their first day. No manager ever
--   chooses, sees or holds another manager's way in, so GR037's promise
--   still holds for setting things: only you set your own.
--
--   Without one more change, the reset would hand the resetting manager a way
--   in: a manager who isn't set up may be set up by whoever asks, and the
--   manager who just did the reset is right there with Admin open. So setting
--   up for the first time is now refused while another manager's Admin is
--   open (may_change_admin_access, replaced below). Setting up is done from a
--   locked Admin, by tapping your own name.
--
--   The cost: until they set it up again, that manager is "not set up", and
--   whoever taps their name first could set it up instead. That is the same
--   gap every new manager has before their first sign-in. It is kept small
--   by doing the reset with them in the shop, ready to set up straight away;
--   the reset and the setup that follows are both in the audit log, so a
--   setup nobody expected can be seen and reset again.
--
--   Becoming a groomer, or leaving, resets Admin access the same way: a PIN
--   left behind would open Admin again the day they came back as a manager.
--
--   GR038  staff changed by someone who isn't a manager with Admin open
--   GR039  the shop left without an active manager
--   GR040  a staff member deleted instead of marked as no longer working here
--   GR041  Admin access reset for yourself, or for someone who isn't a manager
--   GR042  someone marked as gone while they still have grooms booked ahead
-- =============================================================================

SET search_path = groom, public;

INSERT INTO policy_enforcement (error_code, level, relaxable, description) VALUES
  ('GR038', 'block', false, 'Staff changed by someone who isn''t a manager with Admin open'),
  ('GR039', 'block', false, 'The shop left without an active manager'),
  ('GR040', 'block', false, 'A staff member deleted instead of marked as no longer working here'),
  ('GR041', 'block', false, 'Admin access reset for yourself, or for someone who isn''t a manager'),
  ('GR042', 'block', false, 'A staff member marked as gone with grooms still booked ahead');

ALTER TABLE groomer ADD COLUMN left_at timestamptz;
COMMENT ON COLUMN groomer.left_at IS 'When a manager marked them as no longer working here. NULL while they work here.';
ALTER TABLE groomer ADD CONSTRAINT groomer_left_when_inactive CHECK (is_active = (left_at IS NULL));
ALTER TABLE groomer ADD CONSTRAINT groomer_name_not_blank CHECK (btrim(display_name) <> '');

-- -----------------------------------------------------------------------------
-- Rules that hold however the table is changed
-- -----------------------------------------------------------------------------

CREATE FUNCTION groomer_never_deleted() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Staff are never deleted' USING ERRCODE = 'GR040',
          HINT = 'Mark them as no longer working here. Their name stays on past records.';
END $$;

CREATE TRIGGER groomer_never_deleted BEFORE DELETE ON groomer
    FOR EACH ROW EXECUTE FUNCTION groomer_never_deleted();

-- Checked after the statement, so a change that swaps one manager for
-- another in one go is judged on where it ends up.
CREATE FUNCTION shop_keeps_a_manager() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM groomer g WHERE g.is_active AND g.role = 'manager') THEN
        RAISE EXCEPTION 'The shop must keep at least one manager' USING ERRCODE = 'GR039',
              HINT = 'Make someone else a manager first.';
    END IF;
    RETURN NULL;
END $$;

CREATE TRIGGER shop_keeps_a_manager AFTER UPDATE OF role, is_active ON groomer
    FOR EACH STATEMENT EXECUTE FUNCTION shop_keeps_a_manager();

-- -----------------------------------------------------------------------------
-- Who may
-- -----------------------------------------------------------------------------

-- Section 33's rule, tightened: a first setup only with no other manager's
-- Admin open, so a manager who resets someone can't then set them up.
CREATE OR REPLACE FUNCTION may_change_admin_access(p_groomer_id uuid, p_token_hash text) RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT is_active_manager(p_groomer_id)
       AND (COALESCE(admin_session_manager(p_token_hash) = p_groomer_id, false)
            OR (NOT admin_is_set_up(p_groomer_id) AND admin_session_manager(p_token_hash) IS NULL))
$$;

-- The manager with Admin open, or a refusal.
CREATE FUNCTION staff_manager(p_token_hash text) RETURNS groomer
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_me groomer;
BEGIN
    SELECT * INTO v_me FROM groomer WHERE id = admin_session_manager(p_token_hash);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Only a manager, with Admin open, can change the staff list' USING ERRCODE = 'GR038',
              HINT = 'Open Admin as yourself first.';
    END IF;
    RETURN v_me;
END $$;

CREATE FUNCTION staff_email(p_email text, p_except uuid) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_email text := lower(nullif_blank(p_email));
BEGIN
    IF v_email IS NULL OR v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
        RAISE EXCEPTION 'Type their email, like name@example.com' USING ERRCODE = 'check_violation';
    END IF;
    IF EXISTS (SELECT 1 FROM groomer g WHERE lower(g.email) = v_email AND g.id IS DISTINCT FROM p_except) THEN
        RAISE EXCEPTION 'Someone on the staff list already has that email' USING ERRCODE = 'unique_violation',
              HINT = 'If they worked here before, mark them as working here again instead.';
    END IF;
    RETURN v_email;
END $$;

-- Takes away every way this manager opens Admin, and locks any Admin they
-- have open. Returns how many passkeys went and whether a PIN did, for the
-- audit log. No checks: its callers make them.
CREATE FUNCTION clear_admin_access(p_groomer_id uuid, OUT passkeys integer, OUT had_pin boolean)
LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM manager_passkey WHERE groomer_id = p_groomer_id;
    GET DIAGNOSTICS passkeys = ROW_COUNT;
    SELECT admin_pin_hash IS NOT NULL INTO had_pin FROM groomer WHERE id = p_groomer_id;
    UPDATE groomer SET admin_pin_hash = NULL WHERE id = p_groomer_id;
    UPDATE admin_session SET closed_at = now() WHERE groomer_id = p_groomer_id AND closed_at IS NULL;
    DELETE FROM passkey_challenge WHERE groomer_id = p_groomer_id;
END $$;

-- -----------------------------------------------------------------------------
-- Adding and changing
-- -----------------------------------------------------------------------------

CREATE FUNCTION add_staff_member(p_name text, p_email text, p_role groomer_role, p_token_hash text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v_me    groomer := staff_manager(p_token_hash);
    v_name  text    := btrim(p_name);
    v_email text;
    v_id    uuid;
BEGIN
    IF nullif_blank(v_name) IS NULL THEN
        RAISE EXCEPTION 'Type their name' USING ERRCODE = 'check_violation';
    END IF;
    v_email := staff_email(p_email, NULL);
    INSERT INTO groomer (display_name, email, role) VALUES (v_name, v_email, COALESCE(p_role, 'groomer'))
    RETURNING id INTO v_id;
    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    VALUES (v_me.id, v_me.display_name, 'create', 'groomer', v_id,
            jsonb_build_object('display_name', v_name, 'email', v_email, 'role', COALESCE(p_role, 'groomer')));
    RETURN v_id;
END $$;

-- Name, email and role together, as the form sends them. Each field that
-- changed is recorded before and after; a save that changes nothing records
-- nothing. Becoming a groomer takes away their Admin access.
CREATE FUNCTION update_staff_member(p_id uuid, p_name text, p_email text, p_role groomer_role,
                                    p_token_hash text) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
    v_me      groomer := staff_manager(p_token_hash);
    v_old     groomer;
    v_name    text := btrim(p_name);
    v_email   text;
    v_changes jsonb := '{}';
    v_cleared record;
BEGIN
    SELECT * INTO v_old FROM groomer WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No such staff member' USING ERRCODE = 'no_data_found';
    END IF;
    IF nullif_blank(v_name) IS NULL THEN
        RAISE EXCEPTION 'Type their name' USING ERRCODE = 'check_violation';
    END IF;
    v_email := staff_email(p_email, p_id);
    p_role  := COALESCE(p_role, v_old.role);

    IF v_name <> v_old.display_name THEN
        v_changes := v_changes || jsonb_build_object('display_name', jsonb_build_object('before', v_old.display_name, 'after', v_name));
    END IF;
    IF v_email <> lower(v_old.email) THEN
        v_changes := v_changes || jsonb_build_object('email', jsonb_build_object('before', v_old.email, 'after', v_email));
    END IF;
    IF p_role <> v_old.role THEN
        v_changes := v_changes || jsonb_build_object('role', jsonb_build_object('before', v_old.role, 'after', p_role));
    END IF;
    IF v_changes = '{}' THEN
        RETURN false;
    END IF;

    UPDATE groomer SET display_name = v_name, email = v_email, role = p_role WHERE id = p_id;
    IF v_old.role = 'manager' AND p_role = 'groomer' THEN
        SELECT * INTO v_cleared FROM clear_admin_access(p_id);
        v_changes := v_changes || jsonb_build_object('admin_access', 'reset',
                         'passkeys_removed', v_cleared.passkeys, 'pin_cleared', v_cleared.had_pin);
    END IF;
    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    VALUES (v_me.id, v_me.display_name, 'update', 'groomer', p_id, v_changes);
    RETURN true;
END $$;

-- Marks someone as no longer working here, or as working here again.
-- Leaving with grooms booked ahead is refused: those dogs would be booked
-- with someone who isn't coming in. Leaving takes away Admin access.
CREATE FUNCTION set_staff_working(p_id uuid, p_working boolean, p_token_hash text) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
    v_me      groomer := staff_manager(p_token_hash);
    v_old     groomer;
    v_ahead   integer;
    v_changes jsonb;
    v_cleared record;
BEGIN
    SELECT * INTO v_old FROM groomer WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No such staff member' USING ERRCODE = 'no_data_found';
    END IF;
    IF v_old.is_active = p_working THEN
        RETURN false;
    END IF;

    IF NOT p_working THEN
        SELECT count(*) INTO v_ahead FROM appointment a
         WHERE a.groomer_id = p_id AND a.status = 'booked' AND a.ends_at > shop_now();
        IF v_ahead > 0 THEN
            RAISE EXCEPTION '% still has % booked ahead', v_old.display_name,
                  CASE WHEN v_ahead = 1 THEN '1 groom' ELSE v_ahead || ' grooms' END
                  USING ERRCODE = 'GR042',
                  HINT = 'Move those grooms to someone else, or cancel them, first.';
        END IF;
    END IF;

    UPDATE groomer SET is_active = p_working, left_at = CASE WHEN p_working THEN NULL ELSE now() END
     WHERE id = p_id;
    v_changes := jsonb_build_object('working_here', jsonb_build_object('before', v_old.is_active, 'after', p_working));
    IF NOT p_working THEN
        SELECT * INTO v_cleared FROM clear_admin_access(p_id);
        IF v_cleared.passkeys > 0 OR v_cleared.had_pin THEN
            v_changes := v_changes || jsonb_build_object('admin_access', 'reset',
                             'passkeys_removed', v_cleared.passkeys, 'pin_cleared', v_cleared.had_pin);
        END IF;
    END IF;
    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    VALUES (v_me.id, v_me.display_name, 'update', 'groomer', p_id, v_changes);
    RETURN true;
END $$;

-- Another manager's lost phone. Takes their passkeys and PIN away and locks
-- their Admin; they set up a new way in themselves next time they open it.
-- Never your own: you change yours with your own Admin open.
CREATE FUNCTION reset_admin_access(p_id uuid, p_token_hash text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_me      groomer := staff_manager(p_token_hash);
    v_cleared record;
BEGIN
    IF p_id = v_me.id THEN
        RAISE EXCEPTION 'You can''t reset your own Admin access' USING ERRCODE = 'GR041',
              HINT = 'Change your own with Passkeys and PIN, at the top of Admin.';
    END IF;
    IF NOT is_active_manager(p_id) THEN
        RAISE EXCEPTION 'Only a manager has Admin access to reset' USING ERRCODE = 'GR041';
    END IF;
    SELECT * INTO v_cleared FROM clear_admin_access(p_id);
    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    VALUES (v_me.id, v_me.display_name, 'update', 'groomer', p_id,
            jsonb_build_object('admin_access', 'reset',
                               'passkeys_removed', v_cleared.passkeys, 'pin_cleared', v_cleared.had_pin));
END $$;

-- -----------------------------------------------------------------------------
-- The staff list
-- -----------------------------------------------------------------------------

CREATE VIEW v_staff AS
SELECT g.id, g.display_name AS name, g.email, g.role::text AS role, g.is_active AS working_here, g.left_at,
       g.created_at AS added_at,
       CASE WHEN g.role = 'manager' AND g.is_active THEN admin_is_set_up(g.id) END AS admin_set_up,
       (SELECT count(*) FROM appointment a
         WHERE a.groomer_id = g.id AND a.status = 'booked' AND a.ends_at > shop_now())::int AS booked_ahead
  FROM groomer g;

ALTER FUNCTION may_change_admin_access(uuid, text)               SET search_path = groom, public;
ALTER FUNCTION groomer_never_deleted()                           SET search_path = groom, public;
ALTER FUNCTION shop_keeps_a_manager()                            SET search_path = groom, public;
ALTER FUNCTION staff_manager(text)                               SET search_path = groom, public;
ALTER FUNCTION staff_email(text, uuid)                           SET search_path = groom, public;
ALTER FUNCTION clear_admin_access(uuid)                          SET search_path = groom, public;
ALTER FUNCTION add_staff_member(text, text, groomer_role, text)  SET search_path = groom, public;
ALTER FUNCTION update_staff_member(uuid, text, text, groomer_role, text) SET search_path = groom, public;
ALTER FUNCTION set_staff_working(uuid, boolean, text)            SET search_path = groom, public;
ALTER FUNCTION reset_admin_access(uuid, text)                    SET search_path = groom, public;
