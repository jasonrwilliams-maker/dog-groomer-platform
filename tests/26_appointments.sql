-- Booking grooms ahead.
--
-- Eight things are proven:
--   1. A full groom is booked for 90 minutes unless the length is changed, and
--      shows on the calendar with its time.
--   2. Nobody is in two places at once: the groomer (GR031) or the dog.
--   3. A groom has to fit the shop's hours and the future; a long one can take
--      the whole day.
--   4. A regular client goes to their usual groomer: another needs a reason
--      (GR032), which is kept. A new client goes to whoever is free.
--   5. The choices put the usual groomer first, then whoever is free then.
--   6. Free start times leave out what is booked.
--   7. Vaccines that will be out of date by the day are a warning, not a refusal.
--   8. A booking can be moved, or cancelled with the reason kept, and a
--      cancelled one frees the time.

BEGIN;
SET search_path = groom, public;
SELECT plan(22);

-- Tomorrow at the shop, whatever today is.
CREATE TEMP TABLE t_day AS SELECT (shop_now()::date + 1) AS d;
CREATE FUNCTION pg_temp.at(p_hhmm text) RETURNS timestamp LANGUAGE sql AS
  $$ SELECT (SELECT d FROM t_day) + p_hhmm::time $$;

-- Rex: a regular of Tanya's (she groomed him last). Bo: a new client.
CREATE TEMP TABLE t_rex AS
SELECT add_dog(add_client('Ana', 'Ruiz', '410-555-0950', NULL, '00000000-0000-0000-0000-00000000b001'),
               'Rex', NULL, 'curly', 'male', NULL, '00000000-0000-0000-0000-00000000b001') AS id;
INSERT INTO visit (dog_id, performed_by, visit_date) VALUES ((SELECT id FROM t_rex), '00000000-0000-0000-0000-00000000b002', CURRENT_DATE - 40);
CREATE TEMP TABLE t_bo AS
SELECT add_dog(add_client('Cal', 'Ito', '410-555-0951', NULL, '00000000-0000-0000-0000-00000000b001'),
               'Bo', NULL, 'curly', 'male', NULL, '00000000-0000-0000-0000-00000000b001') AS id;

-- --- 1. A full groom, 60 minutes ----------------------------------------------------------------------
CREATE TEMP TABLE t_rex_appt AS
SELECT book_appointment((SELECT id FROM t_rex), '00000000-0000-0000-0000-00000000b002', pg_temp.at('09:00'),
                        (SELECT default_minutes FROM service_type WHERE code = 'full_groom'), 'full_groom', NULL, NULL,
                        '00000000-0000-0000-0000-00000000b001') AS id;
SELECT results_eq(
  $$ SELECT minutes, ends_at FROM appointment WHERE id = (SELECT id FROM t_rex_appt) $$,
  $$ VALUES (90, pg_temp.at('10:30')) $$,
  'A full groom is 90 minutes');
SELECT results_eq(
  $$ SELECT kind, starts_at, minutes, groomer FROM v_calendar_event WHERE appointment_id = (SELECT id FROM t_rex_appt) $$,
  $$ VALUES ('booking'::text, '09:00'::time, 90, 'Tanya'::text) $$,
  'It shows on the calendar with its time, length and groomer');

-- --- 2. Two places at once ----------------------------------------------------------------------------
SELECT throws_ok(
  $$ SELECT book_appointment((SELECT id FROM t_bo), '00000000-0000-0000-0000-00000000b002', pg_temp.at('09:30'), 60,
                             'full_groom', NULL, NULL, '00000000-0000-0000-0000-00000000b001') $$,
  'GR031', NULL, 'Tanya cannot be booked over Rex');
SELECT throws_ok(
  $$ SELECT book_appointment((SELECT id FROM t_rex), '00000000-0000-0000-0000-00000000b001', pg_temp.at('09:45'), 30,
                             'full_groom', NULL, 'owner asked', '00000000-0000-0000-0000-00000000b001') $$,
  'GR031', NULL, 'Nor can Rex be in two places');
SELECT lives_ok(
  $$ SELECT book_appointment((SELECT id FROM t_bo), '00000000-0000-0000-0000-00000000b002', pg_temp.at('10:30'), 60,
                             'full_groom', NULL, NULL, '00000000-0000-0000-0000-00000000b001') $$,
  'Starting as the last one ends is fine');
SELECT throws_ok(
  $$ INSERT INTO appointment (dog_id, groomer_id, service_type_id, starts_at, minutes, booked_by)
     VALUES ((SELECT id FROM t_bo), '00000000-0000-0000-0000-00000000b002', (SELECT id FROM service_type WHERE code = 'bath'),
             pg_temp.at('09:15'), 30, '00000000-0000-0000-0000-00000000b001') $$,
  '23P01', NULL, 'The table itself refuses a double-booked groomer');

-- --- 3. Hours, and the past ---------------------------------------------------------------------------
SELECT throws_ok(
  $$ SELECT book_appointment((SELECT id FROM t_bo), '00000000-0000-0000-0000-00000000b001', pg_temp.at('17:30'), 60,
                             'full_groom', NULL, NULL, '00000000-0000-0000-0000-00000000b001') $$,
  '23514', NULL, 'A groom running past closing is refused');
SELECT throws_ok(
  $$ SELECT book_appointment((SELECT id FROM t_bo), '00000000-0000-0000-0000-00000000b001', shop_now() - interval '1 day', 60,
                             'full_groom', NULL, NULL, '00000000-0000-0000-0000-00000000b001') $$,
  '23514', NULL, 'So is one in the past');
SELECT lives_ok(
  $$ SELECT book_appointment((SELECT id FROM t_bo), '00000000-0000-0000-0000-00000000b002', pg_temp.at('08:00') + interval '1 day', 600,
                             'full_groom', 'Matted all over', NULL, '00000000-0000-0000-0000-00000000b001') $$,
  'A matted dog can take the whole day, opening to closing');

-- --- 4. The usual groomer -----------------------------------------------------------------------------
SELECT is(regular_groomer((SELECT id FROM t_rex)), '00000000-0000-0000-0000-00000000b002'::uuid,
  'Rex''s usual groomer is whoever groomed him last');
SELECT throws_ok(
  $$ SELECT book_appointment((SELECT id FROM t_rex), '00000000-0000-0000-0000-00000000b001', pg_temp.at('14:00'), 60,
                             'full_groom', NULL, ' ', '00000000-0000-0000-0000-00000000b001') $$,
  'GR032', NULL, 'Booking him with Nadia needs a reason');
CREATE TEMP TABLE t_rex_nadia AS
SELECT book_appointment((SELECT id FROM t_rex), '00000000-0000-0000-0000-00000000b001', pg_temp.at('14:00'), 60,
                        'full_groom', NULL, 'Tanya on holiday', '00000000-0000-0000-0000-00000000b001') AS id;
SELECT results_eq(
  $$ SELECT other_groomer_reason, not_usual_groomer FROM v_appointment WHERE id = (SELECT id FROM t_rex_nadia) $$,
  $$ VALUES ('Tanya on holiday'::text, true) $$,
  'With one, it is booked and the reason is kept');
SELECT is(regular_groomer((SELECT id FROM t_bo)), '00000000-0000-0000-0000-00000000b002'::uuid,
  'A new client''s usual groomer is whoever they were first booked with');

-- --- 5. The choices -----------------------------------------------------------------------------------
SELECT results_eq(
  $$ SELECT groomer, is_regular, free_then FROM booking_choices((SELECT id FROM t_rex), pg_temp.at('10:00'), 60) $$,
  $$ VALUES ('Tanya'::text, true, false), ('Nadia'::text, false, true) $$,
  'Rex''s usual groomer comes first, even when busy then; then whoever is free');
SELECT is(
  (SELECT first_free FROM booking_choices((SELECT id FROM t_rex), pg_temp.at('10:00'), 60) WHERE groomer = 'Tanya'),
  pg_temp.at('08:00'), 'With her first free time that day: the hour before Rex');

-- --- 6. Free start times ------------------------------------------------------------------------------
SELECT is(
  (SELECT count(*) FROM free_starts('00000000-0000-0000-0000-00000000b002', (SELECT d FROM t_day), 60)
    WHERE free_starts < pg_temp.at('11:00')),
  1::bigint, 'Before 11, Tanya is free only at 8:00 for an hour');

-- --- 7. Vaccines warn -----------------------------------------------------------------------------------
SELECT record_counter_shot((SELECT id FROM t_rex), 'rabies', CURRENT_DATE - 1090, (SELECT d FROM t_day) + 10,
                           '00000000-0000-0000-0000-00000000b001');
SELECT is(
  (SELECT warning FROM appointment_warnings((SELECT id FROM t_rex), (SELECT d FROM t_day) + 30) WHERE vaccine = 'Rabies'),
  'expires before the appointment', 'Rabies running out before a later appointment is a warning');
SELECT lives_ok(
  $$ SELECT book_appointment((SELECT id FROM t_rex), '00000000-0000-0000-0000-00000000b002', pg_temp.at('09:00') + interval '30 days', 60,
                             'full_groom', NULL, NULL, '00000000-0000-0000-0000-00000000b001') $$,
  'And it is still booked');
SELECT is_empty(
  $$ SELECT 1 FROM appointment_warnings((SELECT id FROM t_rex), (SELECT d FROM t_day)) $$,
  'Nothing to warn about for tomorrow');

-- --- 8. Moving and cancelling ---------------------------------------------------------------------------
SELECT change_appointment((SELECT id FROM t_rex_appt), '00000000-0000-0000-0000-00000000b002', pg_temp.at('11:30'), 120,
                          'Owner running late', NULL, '00000000-0000-0000-0000-00000000b001');
SELECT results_eq(
  $$ SELECT starts_at, minutes, note FROM appointment WHERE id = (SELECT id FROM t_rex_appt) $$,
  $$ VALUES (pg_temp.at('11:30'), 120, 'Owner running late'::text) $$,
  'A booking is moved and made longer');
SELECT cancel_appointment((SELECT id FROM t_rex_appt), 'Owner sick', '00000000-0000-0000-0000-00000000b002');
SELECT results_eq(
  $$ SELECT status::text, cancel_reason FROM appointment WHERE id = (SELECT id FROM t_rex_appt) $$,
  $$ VALUES ('cancelled'::text, 'Owner sick'::text) $$,
  'Cancelled, with the reason kept');
SELECT ok(
  pg_temp.at('11:30') IN (SELECT free_starts('00000000-0000-0000-0000-00000000b002', (SELECT d FROM t_day), 60)),
  'And its time is free again');

SELECT * FROM finish();
ROLLBACK;
