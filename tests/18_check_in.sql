-- Check-in: a groom cannot start while a service-blocking vaccine is not in
-- order, and nothing else stops it.
--
-- Jaddi (d001) has no rabies record. Pip has current rabies and an expired
-- Bordetella. Noodle is a ten-week-old puppy, too young for rabies. Rex had
-- rabies, and it has lapsed.
--
-- Seven things are proven:
--   1. No rabies record, or an expired one, refuses the groom (GR020), names
--      the vaccine, and writes nothing.
--   2. An expired vaccine that does not block service does not stop it — and
--      making it block is a configuration change, not a code change.
--   3. A puppy too young for rabies can be groomed.
--   4. A started groom is dated in the shop's time zone and audited.
--   5. Checking in twice on one day is one visit.
--   6. History is not refused: a past visit for a blocked dog can still be
--      entered.
--   7. The card's vaccine lines say which line blocks.

BEGIN;
SET search_path = groom, public;
SELECT plan(14);

-- --- Fixture -------------------------------------------------------------------
INSERT INTO dog (id, owner_id, name, coat_type_id, date_of_birth) VALUES
  ('00000000-0000-0000-0000-0000000f6001', '00000000-0000-0000-0000-00000000a001', 'Pip',
   (SELECT id FROM coat_type WHERE code = 'curly'), CURRENT_DATE - 900),
  ('00000000-0000-0000-0000-0000000f6002', '00000000-0000-0000-0000-00000000a001', 'Noodle',
   (SELECT id FROM coat_type WHERE code = 'curly'), CURRENT_DATE - 70),
  ('00000000-0000-0000-0000-0000000f6003', '00000000-0000-0000-0000-00000000a001', 'Rex',
   (SELECT id FROM coat_type WHERE code = 'smooth'), CURRENT_DATE - 2000);

INSERT INTO vaccination_record (dog_id, vaccine_type_id, administered_on, expires_on, entry_method,
                                verification_status, verified_by, verified_at) VALUES
  ('00000000-0000-0000-0000-0000000f6001', (SELECT id FROM vaccine_type WHERE code = 'rabies'),
   CURRENT_DATE - 100, CURRENT_DATE + 900, 'manual', 'verified', '00000000-0000-0000-0000-00000000b001', now()),
  ('00000000-0000-0000-0000-0000000f6001', (SELECT id FROM vaccine_type WHERE code = 'bordetella'),
   CURRENT_DATE - 400, CURRENT_DATE - 35, 'manual', 'verified', '00000000-0000-0000-0000-00000000b001', now()),
  ('00000000-0000-0000-0000-0000000f6003', (SELECT id FROM vaccine_type WHERE code = 'rabies'),
   CURRENT_DATE - 1200, CURRENT_DATE - 105, 'manual', 'verified', '00000000-0000-0000-0000-00000000b001', now());

-- --- 1. Refused, by name, with nothing written ---------------------------------------
SELECT throws_ok(
  $$ SELECT start_visit('00000000-0000-0000-0000-00000000d001', '00000000-0000-0000-0000-00000000b001') $$,
  'GR020', 'Cannot start the groom: Rabies (no record on file)',
  'Jaddi has no rabies record: the groom cannot start, and the message says why');

SELECT throws_ok(
  $$ SELECT start_visit('00000000-0000-0000-0000-0000000f6003', '00000000-0000-0000-0000-00000000b001') $$,
  'GR020', 'Cannot start the groom: Rabies (expired)',
  'Rex''s rabies lapsed: refused just the same');

SELECT is((SELECT count(*) FROM visit WHERE dog_id IN ('00000000-0000-0000-0000-00000000d001',
                                                       '00000000-0000-0000-0000-0000000f6003')),
  0::bigint, 'A refused check-in leaves no visit behind');

-- --- 2. Non-blocking, and configuration ------------------------------------------------
UPDATE vaccine_type SET blocks_service_if_expired = true WHERE code = 'bordetella';

SELECT throws_ok(
  $$ SELECT start_visit('00000000-0000-0000-0000-0000000f6001', '00000000-0000-0000-0000-00000000b001') $$,
  'GR020', 'Cannot start the groom: Bordetella (expired)',
  'A shop that makes Bordetella block service gets a refusal for Pip — by a setting, not a code change');

UPDATE vaccine_type SET blocks_service_if_expired = false WHERE code = 'bordetella';

CREATE TEMP TABLE t_pip AS
SELECT start_visit('00000000-0000-0000-0000-0000000f6001', '00000000-0000-0000-0000-00000000b001') AS id;

SELECT isnt((SELECT id FROM t_pip), NULL,
  'Back to the default, Pip''s expired Bordetella does not stop the groom');

-- --- 3. The puppy ------------------------------------------------------------------------
SELECT lives_ok(
  $$ SELECT start_visit('00000000-0000-0000-0000-0000000f6002', '00000000-0000-0000-0000-00000000b002') $$,
  'Noodle is ten weeks old: too young for rabies is not a reason to turn her away');

-- --- 4. Dated where the shop is, and audited ---------------------------------------------------
SELECT results_eq(
  $$ SELECT visit_date, performed_by, check_out IS NULL FROM visit WHERE id = (SELECT id FROM t_pip) $$,
  $$ VALUES ((now() AT TIME ZONE 'America/New_York')::date, '00000000-0000-0000-0000-00000000b001'::uuid, true) $$,
  'The visit is dated in the shop''s time zone, signed by the groomer, and still open');

SELECT is((SELECT count(*) FROM audit_log
            WHERE entity_type = 'visit' AND entity_id = (SELECT id FROM t_pip)
              AND changed_fields->>'via' = 'start_visit'), 1::bigint,
  'Starting a groom is in the audit log');

-- --- 5. Twice is once -------------------------------------------------------------------------------
SELECT is(start_visit('00000000-0000-0000-0000-0000000f6001', '00000000-0000-0000-0000-00000000b002'),
          (SELECT id FROM t_pip),
  'Checking Pip in again today returns the visit already open');

SELECT is((SELECT count(*) FROM visit WHERE dog_id = '00000000-0000-0000-0000-0000000f6001'), 1::bigint,
  '...and does not open a second one');

-- --- 6. History is not refused -----------------------------------------------------------------------
SELECT lives_ok(
  $$ INSERT INTO visit (dog_id, performed_by, visit_date, check_in, check_out, overall_note)
     VALUES ('00000000-0000-0000-0000-00000000d001', '00000000-0000-0000-0000-00000000b001',
             CURRENT_DATE - 400, '09:00', '10:30', 'Entered from the paper book') $$,
  'A groom that already happened can still be recorded for a dog that is blocked today');

-- --- 7. The card -----------------------------------------------------------------------------------------
SELECT results_eq(
  $$ SELECT vaccine_code, state::text, blocks_service FROM v_check_in_vaccine
      WHERE dog_id = '00000000-0000-0000-0000-00000000d001' ORDER BY vaccine_code $$,
  $$ VALUES ('bordetella', 'no_record', false), ('dhpp', 'no_record', false), ('rabies', 'no_record', true) $$,
  'Jaddi''s card: three lines missing, and only rabies stops the groom');

SELECT results_eq(
  $$ SELECT vaccine_code, label FROM v_check_in_vaccine
      WHERE dog_id = '00000000-0000-0000-0000-0000000f6001' AND vaccine_code IN ('rabies', 'bordetella')
      ORDER BY vaccine_code $$,
  $$ VALUES ('bordetella', 'Expired'), ('rabies', 'Current') $$,
  'Pip''s card says what a person would: Bordetella expired, rabies current');

SELECT is((SELECT label FROM v_check_in_vaccine
            WHERE dog_id = '00000000-0000-0000-0000-0000000f6002' AND vaccine_code = 'rabies'),
  'Not yet due (puppy)', 'Noodle''s rabies line says why it is not a problem');

SELECT * FROM finish();
ROLLBACK;
