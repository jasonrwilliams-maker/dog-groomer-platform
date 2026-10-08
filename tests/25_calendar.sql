-- The calendar: grooms and vaccine expiries, by date.
--
-- Four things are proven:
--   1. A groom is on the day it happened, with who groomed.
--   2. A vaccine's expiry is the one the dog's compliance rests on: a newer
--      certificate replaces the older one on the calendar.
--   3. Rabies is marked as stopping grooms when it lapses; Bordetella is not.
--   4. A dog no longer on the books is not on the calendar.

BEGIN;
SET search_path = groom, public;
SELECT plan(5);

CREATE TEMP TABLE t_dog AS
SELECT add_dog(add_client('Lena', 'Ortiz', '410-555-0900', NULL, '00000000-0000-0000-0000-00000000b002'),
               'Nugget', NULL, 'curly', 'male', NULL, '00000000-0000-0000-0000-00000000b002') AS id;

-- --- 1. A groom ----------------------------------------------------------------------------------------
INSERT INTO visit (dog_id, performed_by, visit_date, check_in, check_out, overall_note)
VALUES ((SELECT id FROM t_dog), '00000000-0000-0000-0000-00000000b002', CURRENT_DATE - 14, '09:00', '10:30', 'Short summer cut');

SELECT results_eq(
  $$ SELECT on_date, groomer, note FROM v_calendar_event WHERE dog_id = (SELECT id FROM t_dog) AND kind = 'groom' $$,
  $$ VALUES (CURRENT_DATE - 14, 'Tanya'::text, 'Short summer cut'::text) $$,
  'A groom is on the day it happened, with who groomed');

-- --- 2. The expiry that counts -------------------------------------------------------------------------
SELECT record_counter_shot((SELECT id FROM t_dog), 'rabies', CURRENT_DATE - 1100, CURRENT_DATE - 5,
                           '00000000-0000-0000-0000-00000000b002');
SELECT record_counter_shot((SELECT id FROM t_dog), 'rabies', CURRENT_DATE - 3, CURRENT_DATE + 1092,
                           '00000000-0000-0000-0000-00000000b002');
SELECT record_counter_shot((SELECT id FROM t_dog), 'bordetella', CURRENT_DATE - 30, CURRENT_DATE + 335,
                           '00000000-0000-0000-0000-00000000b002');

SELECT results_eq(
  $$ SELECT on_date FROM v_calendar_event WHERE dog_id = (SELECT id FROM t_dog) AND vaccine = 'Rabies' $$,
  $$ VALUES (CURRENT_DATE + 1092) $$,
  'Rabies shows its current expiry only, not the certificate it replaced');

-- --- 3. What stops a groom -----------------------------------------------------------------------------
SELECT is(
  (SELECT stops_grooms FROM v_calendar_event WHERE dog_id = (SELECT id FROM t_dog) AND vaccine = 'Rabies'),
  true, 'Rabies lapsing stops grooms');
SELECT is(
  (SELECT stops_grooms FROM v_calendar_event WHERE dog_id = (SELECT id FROM t_dog) AND vaccine = 'Bordetella'),
  false, 'Bordetella lapsing does not');

-- --- 4. Off the books ----------------------------------------------------------------------------------
UPDATE dog SET is_active = false WHERE id = (SELECT id FROM t_dog);
SELECT is_empty(
  $$ SELECT 1 FROM v_calendar_event WHERE dog_id = (SELECT id FROM t_dog) $$,
  'A dog no longer on the books is not on the calendar');

SELECT * FROM finish();
ROLLBACK;
