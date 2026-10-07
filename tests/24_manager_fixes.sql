-- A manager verifies a shot typed in with no photo, or fixes a shot's dates.
--
-- Six things are proven:
--   1. A shot typed in with no photo is on the manager's list, with who typed it.
--   2. Only a manager verifies it (GR030), and only by saying how; the how is
--      kept on the record, and it comes off the list.
--   3. A hand-checked shot with a misread date is fixed by a manager: the
--      manager's dates stand, verified by the manager, as its second look, and
--      the groomer's dates are kept in the audit log.
--   4. Only a manager fixes dates (GR030), and fixed dates keep the counter's
--      rules: no expiry, no record; nothing in the future (GR021).
--   5. A fix that makes it the same shot as another record is refused (GR022).
--   6. A record read in the records tool is fixed there, not here.

BEGIN;
SET search_path = groom, public;
SELECT plan(16);

CREATE TEMP TABLE t_dog AS
SELECT add_dog(add_client('Ines', 'Moreau', '410-555-0700', NULL, '00000000-0000-0000-0000-00000000b002'),
               'Biscuit', NULL, 'curly', 'female', NULL, '00000000-0000-0000-0000-00000000b002') AS id;

-- --- 1. On the list -----------------------------------------------------------------------------------
CREATE TEMP TABLE t_typed AS
SELECT record_counter_shot((SELECT id FROM t_dog), 'bordetella', CURRENT_DATE - 20, CURRENT_DATE + 345,
                           '00000000-0000-0000-0000-00000000b002') AS id;

SELECT results_eq(
  $$ SELECT vaccine, entered_by FROM v_waiting_verification WHERE id = (SELECT id FROM t_typed) $$,
  $$ VALUES ('Bordetella'::text, 'Tanya'::text) $$,
  'A shot typed in with no photo waits on the manager''s list, with who typed it');

-- --- 2. Verified by a manager, saying how ---------------------------------------------------------------
SELECT throws_ok(
  $$ SELECT verify_counter_shot((SELECT id FROM t_typed), 'Called the vet', '00000000-0000-0000-0000-00000000b002') $$,
  'GR030', NULL, 'A groomer cannot verify it');

SELECT throws_ok(
  $$ SELECT verify_counter_shot((SELECT id FROM t_typed), '  ', '00000000-0000-0000-0000-00000000b001') $$,
  '23514', NULL, 'Verifying needs a word on how it was checked');

SELECT lives_ok(
  $$ SELECT verify_counter_shot((SELECT id FROM t_typed), 'Called the vet''s office', '00000000-0000-0000-0000-00000000b001') $$,
  'A manager verifies it');

SELECT results_eq(
  $$ SELECT verification_status::text, verified_by, verified_how, checked_by_hand
       FROM vaccination_record WHERE id = (SELECT id FROM t_typed) $$,
  $$ VALUES ('verified'::text, '00000000-0000-0000-0000-00000000b001'::uuid, 'Called the vet''s office'::text, false) $$,
  'Verified by the manager, with how kept on the record');

SELECT is_empty(
  $$ SELECT 1 FROM v_waiting_verification WHERE id = (SELECT id FROM t_typed) $$,
  'And it comes off the list');

-- --- 3. A misread date, fixed ---------------------------------------------------------------------------
CREATE TEMP TABLE t_doc AS
SELECT receive_paperwork((SELECT id FROM t_dog), 'private/counter/test-fix.pdf', 'application/pdf', 1000,
                         repeat('f', 64), ARRAY['private/counter/test-fix-p1.jpg'], true,
                         '00000000-0000-0000-0000-00000000b002') AS id;
-- The paper says it expires next year; the groomer typed it as a year earlier.
CREATE TEMP TABLE t_checked AS
SELECT record_checked_shot((SELECT id FROM t_dog), (SELECT id FROM t_doc), 'rabies',
                           CURRENT_DATE - 400, CURRENT_DATE - 35, '00000000-0000-0000-0000-00000000b002') AS id;

SELECT throws_ok(
  $$ SELECT correct_counter_shot((SELECT id FROM t_checked), CURRENT_DATE - 400, CURRENT_DATE + 695,
                                 '00000000-0000-0000-0000-00000000b002') $$,
  'GR030', NULL, 'A groomer cannot fix the dates');

SELECT lives_ok(
  $$ SELECT correct_counter_shot((SELECT id FROM t_checked), CURRENT_DATE - 400, CURRENT_DATE + 695,
                                 '00000000-0000-0000-0000-00000000b001') $$,
  'A manager fixes the expiry');

SELECT results_eq(
  $$ SELECT expires_on, verified_by, second_look_by, checked_by_hand
       FROM vaccination_record WHERE id = (SELECT id FROM t_checked) $$,
  $$ VALUES (CURRENT_DATE + 695, '00000000-0000-0000-0000-00000000b001'::uuid,
             '00000000-0000-0000-0000-00000000b001'::uuid, true) $$,
  'The manager''s dates stand, verified by the manager, as its second look');

SELECT is_empty(
  $$ SELECT 1 FROM v_hand_checked_open WHERE id = (SELECT id FROM t_checked) $$,
  'It comes off the checked-by-hand list');

SELECT is(
  (SELECT changed_fields -> 'expires_on' ->> 'before' FROM audit_log
    WHERE entity_id = (SELECT id FROM t_checked) AND changed_fields ? 'fixed_by_manager'),
  (CURRENT_DATE - 35)::text, 'The groomer''s date is kept in the audit log');

SELECT is(
  (SELECT state::text FROM v_check_in_vaccine WHERE dog_id = (SELECT id FROM t_dog) AND vaccine_code = 'rabies'),
  'current', 'And the dog reads Current for rabies');

-- --- 4. The counter's rules -----------------------------------------------------------------------------
SELECT throws_ok(
  $$ SELECT correct_counter_shot((SELECT id FROM t_checked), CURRENT_DATE + 3, CURRENT_DATE + 695,
                                 '00000000-0000-0000-0000-00000000b001') $$,
  'GR021', NULL, 'A fixed date cannot be in the future');

SELECT throws_ok(
  $$ SELECT correct_counter_shot((SELECT id FROM t_checked), CURRENT_DATE - 400, NULL,
                                 '00000000-0000-0000-0000-00000000b001') $$,
  'GR021', NULL, 'No expiry, no record');

-- --- 5. The same shot as another record -----------------------------------------------------------------
-- Last year's Bordetella, also on file.
SELECT record_counter_shot((SELECT id FROM t_dog), 'bordetella', CURRENT_DATE - 380, CURRENT_DATE - 15,
                           '00000000-0000-0000-0000-00000000b002');
SELECT throws_ok(
  $$ SELECT correct_counter_shot((SELECT id FROM t_typed), CURRENT_DATE - 381, CURRENT_DATE + 345,
                                 '00000000-0000-0000-0000-00000000b001') $$,
  'GR022', NULL, 'A fix that makes it the same shot as another record goes to the records tool');

-- --- 6. Records-tool records ----------------------------------------------------------------------------
UPDATE vaccination_record SET entry_method = 'extracted', document_id = (SELECT id FROM t_doc)
 WHERE id = (SELECT id FROM t_typed);
SELECT throws_ok(
  $$ SELECT correct_counter_shot((SELECT id FROM t_typed), CURRENT_DATE - 21, CURRENT_DATE + 344,
                                 '00000000-0000-0000-0000-00000000b001') $$,
  '23514', NULL, 'A record read in the records tool is fixed there');

SELECT * FROM finish();
ROLLBACK;
