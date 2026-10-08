-- Opening Admin.
--
-- Six things are proven:
--   1. A manager sets up Admin the first time with nobody to vouch for them;
--      after that only they, with Admin open, change it (GR037). A groomer never.
--   2. The PIN is kept hashed, 4 to 8 digits.
--   3. A right PIN opens Admin; a wrong one doesn't and is counted; five wrong
--      in a row lock PIN entry (GR036).
--   4. A passkey opens Admin only for the manager it belongs to (GR036).
--   5. Admin locks when its time runs out, or when it is locked.
--   6. The last way into Admin can't be removed (GR037).

BEGIN;
SET search_path = groom, public;
SELECT plan(18);

-- Nadia is the fixture's manager, Tanya a groomer.
INSERT INTO groomer (id, display_name, email, role) VALUES
  ('00000000-0000-0000-0000-00000000b003', 'Mia', 'mia@example.test', 'manager');

-- --- 1. Setting up ------------------------------------------------------------------------------------
SELECT is(may_change_admin_access('00000000-0000-0000-0000-00000000b001', NULL), true,
  'A manager who has never set up Admin may set it up');
SELECT throws_ok(
  $$ SELECT set_admin_pin('00000000-0000-0000-0000-00000000b002', '1234', NULL) $$,
  'GR037', NULL, 'A groomer cannot set up Admin');
SELECT lives_ok(
  $$ SELECT set_admin_pin('00000000-0000-0000-0000-00000000b001', '2468', NULL) $$,
  'Nadia sets her PIN the first time');
SELECT throws_ok(
  $$ SELECT set_admin_pin('00000000-0000-0000-0000-00000000b001', '1111', NULL) $$,
  'GR037', NULL, 'After that, changing it without Admin open is refused');

-- --- 2. Kept hashed -----------------------------------------------------------------------------------
SELECT ok((SELECT admin_pin_hash LIKE '$2%' AND admin_pin_hash NOT LIKE '%2468%'
             FROM groomer WHERE id = '00000000-0000-0000-0000-00000000b001'),
  'The PIN is kept as a bcrypt hash, never as itself');
SELECT throws_ok(
  $$ SELECT set_admin_pin('00000000-0000-0000-0000-00000000b003', '12ab', NULL) $$,
  '23514', 'A PIN is 4 to 8 digits', 'A PIN that isn''t 4 to 8 digits is refused');

-- --- 3. The PIN ---------------------------------------------------------------------------------------
SELECT is(open_admin_with_pin('00000000-0000-0000-0000-00000000b001', '0000', 'wrong'), NULL,
  'A wrong PIN doesn''t open Admin');
SELECT is((SELECT count(*)::int FROM admin_access_attempt WHERE NOT succeeded), 1, 'and is counted');
SELECT isnt(open_admin_with_pin('00000000-0000-0000-0000-00000000b001', '2468', 'nadia-pin'), NULL,
  'The right PIN opens it');
SELECT is(admin_session_manager('nadia-pin'), '00000000-0000-0000-0000-00000000b001'::uuid,
  'and the session is Nadia''s');
SELECT throws_ok(
  $$ SELECT open_admin_with_pin('00000000-0000-0000-0000-00000000b002', '2468', 'tanya') $$,
  'GR036', NULL, 'A groomer cannot open Admin');
SELECT open_admin_with_pin('00000000-0000-0000-0000-00000000b001', '9999', 'x') FROM generate_series(1, 5);
SELECT throws_ok(
  $$ SELECT open_admin_with_pin('00000000-0000-0000-0000-00000000b001', '2468', 'late') $$,
  'GR036', 'Too many wrong PINs', 'Five wrong in a row lock PIN entry, even for the right PIN');

-- --- 4. A passkey --------------------------------------------------------------------------------------
SELECT lives_ok(
  $$ SELECT add_manager_passkey('00000000-0000-0000-0000-00000000b001', '\x01'::bytea, '\xaa'::bytea, 0,
                                'Nadia''s phone', 'nadia-pin') $$,
  'With Admin open, Nadia adds a passkey');
SELECT throws_ok(
  $$ SELECT open_admin_with_passkey('00000000-0000-0000-0000-00000000b003', '\x01'::bytea, 1, 'mia') $$,
  'GR036', NULL, 'Nadia''s passkey doesn''t open Admin for Mia');
SELECT isnt(open_admin_with_passkey('00000000-0000-0000-0000-00000000b001', '\x01'::bytea, 7, 'nadia-key'), NULL,
  'It opens Admin for Nadia, even while PIN entry is locked');
SELECT is((SELECT sign_count FROM manager_passkey WHERE credential_id = '\x01'::bytea), 7::bigint,
  'and its counter moves on');

-- --- 5. Locking -----------------------------------------------------------------------------------------
UPDATE admin_session SET expires_at = now() - interval '1 second' WHERE token_hash = 'nadia-pin';
SELECT close_admin_session('nadia-key');
SELECT ok(admin_session_manager('nadia-pin') IS NULL AND admin_session_manager('nadia-key') IS NULL,
  'Admin locks when its time is up, or when it is locked');

-- --- 6. The last way in ------------------------------------------------------------------------------
SELECT add_manager_passkey('00000000-0000-0000-0000-00000000b003', '\x02'::bytea, '\xbb'::bytea, 0, 'Mia''s laptop', NULL);
SELECT open_admin_with_passkey('00000000-0000-0000-0000-00000000b003', '\x02'::bytea, 1, 'mia-key');
SELECT throws_ok(
  format($$ SELECT remove_manager_passkey(%L, 'mia-key') $$,
         (SELECT id FROM manager_passkey WHERE credential_id = '\x02'::bytea)),
  'GR037', 'That is your only way into Admin', 'Mia can''t remove her only way in');

SELECT * FROM finish();
ROLLBACK;
