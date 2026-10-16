-- Staff.
--
-- Eight things are proven:
--   1. Only a manager with Admin open changes the staff list (GR038).
--   2. A manager adds someone; a blank name or an email already on file is refused.
--   3. A name, email or role is changed, each change audited before and after.
--   4. The shop is never left without an active manager (GR039): the last one
--      can't be made a groomer or marked as gone, not even by themselves.
--   5. Someone marked as gone leaves the Welcome screen's list and the booking
--      choices, keeps their name on past records, and can come back. Nobody
--      with grooms booked ahead can be marked as gone (GR042).
--   6. A staff member is never deleted (GR040).
--   7. A manager resets another manager's Admin access: passkeys and PIN gone,
--      their Admin locked, and they set it up again themselves. Never your own,
--      never a groomer's (GR041), and the reset sets nothing for them.
--   8. A manager made a groomer, or marked as gone, loses their Admin access.

BEGIN;
SET search_path = groom, public;
SELECT plan(34);

-- Nadia is the fixture's manager, Tanya a groomer. Nadia opens Admin.
SELECT open_admin_session('00000000-0000-0000-0000-00000000b001', 'pin', 'nadia');

-- --- 1. Who may -----------------------------------------------------------------------------------------
SELECT throws_ok(
  $$ SELECT add_staff_member('Lee', 'lee@example.test', 'groomer', NULL) $$,
  'GR038', NULL, 'With Admin locked, nobody adds staff');
SELECT throws_ok(
  $$ SELECT add_staff_member('Lee', 'lee@example.test', 'groomer', 'made-up') $$,
  'GR038', NULL, 'A made-up session adds nobody');
SELECT throws_ok(
  $$ SELECT update_staff_member('00000000-0000-0000-0000-00000000b002', 'Tanya', 'tanya@example.test', 'manager', NULL) $$,
  'GR038', NULL, 'Tanya can''t make herself a manager');

-- --- 2. Adding -------------------------------------------------------------------------------------------
CREATE TEMP TABLE t_lee AS SELECT add_staff_member('  Lee  ', 'Lee@Example.test', 'groomer', 'nadia') AS id;
SELECT results_eq(
  $$ SELECT display_name, email, role::text, is_active FROM groomer WHERE id = (SELECT id FROM t_lee) $$,
  $$ VALUES ('Lee', 'lee@example.test', 'groomer', true) $$,
  'Nadia adds Lee as a groomer, name trimmed and email in small letters');
SELECT is((SELECT changed_fields->>'role' FROM audit_log
            WHERE entity_type = 'groomer' AND entity_id = (SELECT id FROM t_lee) AND action = 'create'
              AND actor_id = '00000000-0000-0000-0000-00000000b001'),
  'groomer', 'and it is in the audit log under Nadia''s name');
SELECT throws_ok(
  $$ SELECT add_staff_member('   ', 'blank@example.test', 'groomer', 'nadia') $$,
  '23514', 'Type their name', 'A blank name is refused');
SELECT throws_ok(
  $$ SELECT add_staff_member('Someone', 'not an email', 'groomer', 'nadia') $$,
  '23514', NULL, 'Something that isn''t an email is refused');
SELECT throws_ok(
  $$ SELECT add_staff_member('Tanya Two', 'TANYA@example.test', 'groomer', 'nadia') $$,
  '23505', 'Someone on the staff list already has that email', 'An email already on file is refused');
SELECT ok((SELECT id FROM groomer WHERE display_name = 'Lee') IN (SELECT id FROM t_lee)
          AND EXISTS (SELECT 1 FROM v_staff WHERE name = 'Lee' AND working_here),
  'Lee is on the staff list');

-- --- 3. Changing -----------------------------------------------------------------------------------------
SELECT is(update_staff_member((SELECT id FROM t_lee), 'Lee Park', 'lee@example.test', 'groomer', 'nadia'), true,
  'Nadia puts Lee''s name right');
SELECT is((SELECT changed_fields FROM audit_log
            WHERE entity_id = (SELECT id FROM t_lee) AND action = 'update' ORDER BY occurred_at DESC LIMIT 1),
  '{"display_name": {"before": "Lee", "after": "Lee Park"}}'::jsonb,
  'Only the name is recorded, before and after');
SELECT is(update_staff_member((SELECT id FROM t_lee), 'Lee Park', 'lee@example.test', 'groomer', 'nadia'), false,
  'Saving without a change changes and records nothing');
SELECT throws_ok(
  format($$ SELECT update_staff_member(%L, 'Lee Park', 'tanya@example.test', 'groomer', 'nadia') $$,
         (SELECT id FROM t_lee)),
  '23505', NULL, 'Lee can''t take Tanya''s email');
SELECT lives_ok(
  format($$ SELECT update_staff_member(%L, 'Lee Park', 'lee@example.test', 'manager', 'nadia') $$,
         (SELECT id FROM t_lee)),
  'Nadia makes Lee a manager');
SELECT ok(is_active_manager((SELECT id FROM t_lee)), 'and Lee is a manager now');

-- --- 4. Always a manager -------------------------------------------------------------------------------
-- Lee goes back to being a groomer, so Nadia is the only manager again.
SELECT update_staff_member((SELECT id FROM t_lee), 'Lee Park', 'lee@example.test', 'groomer', 'nadia');
SELECT throws_ok(
  $$ SELECT update_staff_member('00000000-0000-0000-0000-00000000b001', 'Nadia', 'nadia@example.test', 'groomer', 'nadia') $$,
  'GR039', NULL, 'The last manager can''t make herself a groomer');
SELECT throws_ok(
  $$ SELECT set_staff_working('00000000-0000-0000-0000-00000000b001', false, 'nadia') $$,
  'GR039', NULL, 'The last manager can''t mark herself as gone');
SELECT throws_ok(
  $$ UPDATE groomer SET is_active = false, left_at = now() WHERE role = 'manager' $$,
  'GR039', NULL, 'Not even by changing the table directly');

-- --- 5. Leaving and coming back --------------------------------------------------------------------------
INSERT INTO appointment (dog_id, groomer_id, service_type_id, starts_at, minutes, booked_by)
SELECT (SELECT id FROM dog ORDER BY name LIMIT 1), (SELECT id FROM t_lee), (SELECT id FROM service_type LIMIT 1),
       date_trunc('hour', shop_now()) + interval '2 days', 60, '00000000-0000-0000-0000-00000000b001';
SELECT throws_ok(
  format($$ SELECT set_staff_working(%L, false, 'nadia') $$, (SELECT id FROM t_lee)),
  'GR042', 'Lee Park still has 1 groom booked ahead', 'Lee can''t be marked as gone with a groom booked ahead');
UPDATE appointment SET status = 'cancelled', cancelled_by = '00000000-0000-0000-0000-00000000b001', cancelled_at = now()
 WHERE groomer_id = (SELECT id FROM t_lee);
INSERT INTO visit (dog_id, performed_by, visit_date)
SELECT (SELECT id FROM dog ORDER BY name LIMIT 1), (SELECT id FROM t_lee), CURRENT_DATE - 3;
SELECT is(set_staff_working((SELECT id FROM t_lee), false, 'nadia'), true,
  'Once it is moved, Nadia marks Lee as no longer working here');
SELECT ok(NOT EXISTS (SELECT 1 FROM groomer WHERE is_active AND id = (SELECT id FROM t_lee))
          AND (SELECT left_at FROM groomer WHERE id = (SELECT id FROM t_lee)) IS NOT NULL,
  'Lee is off the Welcome screen''s list, with the day they left');
SELECT ok(NOT EXISTS (SELECT 1 FROM booking_choices((SELECT id FROM dog ORDER BY name LIMIT 1),
                                                    date_trunc('hour', shop_now()) + interval '2 days', 60)
                       WHERE groomer_id = (SELECT id FROM t_lee)),
  'and out of the groomers a booking can go to');
SELECT is((SELECT g.display_name FROM visit v JOIN groomer g ON g.id = v.performed_by
            WHERE v.performed_by = (SELECT id FROM t_lee)),
  'Lee Park', 'Their past groom still names them');
SELECT is(set_staff_working((SELECT id FROM t_lee), true, 'nadia'), true, 'Lee comes back');
SELECT ok((SELECT is_active AND left_at IS NULL FROM groomer WHERE id = (SELECT id FROM t_lee)),
  'and is working here again');

-- --- 6. Never deleted -------------------------------------------------------------------------------------
SELECT throws_ok(
  $$ DELETE FROM groomer WHERE id = '00000000-0000-0000-0000-00000000b002' $$,
  'GR040', NULL, 'A staff member is never deleted');

-- --- 7. Resetting a manager's Admin access ------------------------------------------------------------
-- Mia, a second manager, set up a PIN and a passkey, and has Admin open.
CREATE TEMP TABLE t_mia AS SELECT add_staff_member('Mia', 'mia@example.test', 'manager', 'nadia') AS id;
SELECT set_admin_pin((SELECT id FROM t_mia), '1357', NULL);
SELECT open_admin_session((SELECT id FROM t_mia), 'pin', 'mia');
SELECT add_manager_passkey((SELECT id FROM t_mia), '\x09'::bytea, '\xcc'::bytea, 0, 'Mia''s phone', 'mia');

SELECT throws_ok(
  format($$ SELECT reset_admin_access(%L, 'mia') $$, (SELECT id FROM t_mia)),
  'GR041', NULL, 'Mia can''t reset her own Admin access');
SELECT throws_ok(
  $$ SELECT reset_admin_access('00000000-0000-0000-0000-00000000b002', 'nadia') $$,
  'GR041', NULL, 'A groomer has no Admin access to reset');
SELECT lives_ok(
  format($$ SELECT reset_admin_access(%L, 'nadia') $$, (SELECT id FROM t_mia)),
  'Nadia resets Mia''s Admin access');
SELECT ok(NOT admin_is_set_up((SELECT id FROM t_mia)) AND admin_session_manager('mia') IS NULL,
  'Mia''s passkey and PIN are gone, and her Admin is locked');
SELECT is((SELECT changed_fields FROM audit_log
            WHERE entity_id = (SELECT id FROM t_mia) AND actor_id = '00000000-0000-0000-0000-00000000b001'
              AND changed_fields ? 'admin_access'),
  '{"admin_access": "reset", "passkeys_removed": 1, "pin_cleared": true}'::jsonb,
  'The reset is in the audit log under Nadia''s name');
SELECT throws_ok(
  format($$ SELECT set_admin_pin(%L, '2468', 'nadia') $$, (SELECT id FROM t_mia)),
  'GR037', NULL, 'Nadia still can''t set a PIN for Mia');
SELECT lives_ok(
  format($$ SELECT set_admin_pin(%L, '8642', NULL) $$, (SELECT id FROM t_mia)),
  'Mia sets up a new PIN herself, as on her first day');

-- --- 8. No longer a manager, no Admin -------------------------------------------------------------------
SELECT update_staff_member((SELECT id FROM t_mia), 'Mia', 'mia@example.test', 'groomer', 'nadia');
SELECT ok((SELECT admin_pin_hash IS NULL FROM groomer WHERE id = (SELECT id FROM t_mia)),
  'Made a groomer, Mia''s PIN is gone, so it can''t open Admin if she is a manager again');

SELECT * FROM finish();
ROLLBACK;
