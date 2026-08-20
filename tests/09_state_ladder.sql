-- The compliance state ladder — resolution_precedence.md §2.
--
-- Seven states, evaluated at read time from date-independent facts plus today.
-- Two precedence rules carry real weight:
--   disputed outranks the date checks — a contested record's expiry date is not
--     something to schedule against
--   expired outranks requested_pending — the request is progress, not compliance

BEGIN;
SET search_path = groom, public;
SELECT plan(12);

-- Five more dogs, one per state that the fixture does not already cover.
INSERT INTO dog (id, owner_id, name, coat_type_id) VALUES
  ('00000000-0000-0000-0000-00000000d101', '00000000-0000-0000-0000-00000000a001',
   'Expired Dog',    (SELECT id FROM coat_type WHERE code = 'silky')),
  ('00000000-0000-0000-0000-00000000d102', '00000000-0000-0000-0000-00000000a001',
   'Unverified Dog', (SELECT id FROM coat_type WHERE code = 'silky')),
  ('00000000-0000-0000-0000-00000000d103', '00000000-0000-0000-0000-00000000a001',
   'Disputed Dog',   (SELECT id FROM coat_type WHERE code = 'silky')),
  ('00000000-0000-0000-0000-00000000d104', '00000000-0000-0000-0000-00000000a001',
   'Requested Dog',  (SELECT id FROM coat_type WHERE code = 'silky')),
  ('00000000-0000-0000-0000-00000000d105', '00000000-0000-0000-0000-00000000a001',
   'Lapsed And Chased Dog', (SELECT id FROM coat_type WHERE code = 'silky'));

-- Jaddi: verified, expires well beyond the warning window -> current
INSERT INTO vaccination_record
    (dog_id, vaccine_type_id, administered_on, expires_on, entry_method,
     verification_status, verified_by, verified_at)
VALUES
    ('00000000-0000-0000-0000-00000000d001',
     (SELECT id FROM vaccine_type WHERE code = 'rabies'),
     CURRENT_DATE - 165, CURRENT_DATE + 200, 'manual',
     'verified', '00000000-0000-0000-0000-00000000b001', now());

-- Luna: verified, expires in ten days -> expiring_soon
INSERT INTO vaccination_record
    (dog_id, vaccine_type_id, administered_on, expires_on, entry_method,
     verification_status, verified_by, verified_at)
VALUES
    ('00000000-0000-0000-0000-00000000d002',
     (SELECT id FROM vaccine_type WHERE code = 'rabies'),
     CURRENT_DATE - 355, CURRENT_DATE + 10, 'manual',
     'verified', '00000000-0000-0000-0000-00000000b001', now());

-- d101: verified but lapsed yesterday -> expired
INSERT INTO vaccination_record
    (dog_id, vaccine_type_id, administered_on, expires_on, entry_method,
     verification_status, verified_by, verified_at)
VALUES
    ('00000000-0000-0000-0000-00000000d101',
     (SELECT id FROM vaccine_type WHERE code = 'rabies'),
     CURRENT_DATE - 366, CURRENT_DATE - 1, 'manual',
     'verified', '00000000-0000-0000-0000-00000000b001', now());

-- d102: on file, nobody has checked it -> received_unverified
INSERT INTO vaccination_record
    (dog_id, vaccine_type_id, administered_on, expires_on, entry_method)
VALUES
    ('00000000-0000-0000-0000-00000000d102',
     (SELECT id FROM vaccine_type WHERE code = 'rabies'),
     CURRENT_DATE - 165, CURRENT_DATE + 200, 'manual');

-- d103: contested, and would otherwise read expiring_soon -> disputed_record
INSERT INTO vaccination_record
    (dog_id, vaccine_type_id, administered_on, expires_on, entry_method,
     verification_status, verified_by, verified_at)
VALUES
    ('00000000-0000-0000-0000-00000000d103',
     (SELECT id FROM vaccine_type WHERE code = 'rabies'),
     CURRENT_DATE - 345, CURRENT_DATE + 20, 'manual',
     'disputed', '00000000-0000-0000-0000-00000000b001', now());

-- d104: nothing on file, but we have asked -> requested_pending
INSERT INTO record_request (dog_id, owner_id, vaccine_type_id, channel, status)
VALUES
    ('00000000-0000-0000-0000-00000000d104', '00000000-0000-0000-0000-00000000a001',
     (SELECT id FROM vaccine_type WHERE code = 'rabies'), 'verbal_at_counter', 'queued');

-- d105: lapsed AND already chased -> still expired
INSERT INTO vaccination_record
    (dog_id, vaccine_type_id, administered_on, expires_on, entry_method,
     verification_status, verified_by, verified_at)
VALUES
    ('00000000-0000-0000-0000-00000000d105',
     (SELECT id FROM vaccine_type WHERE code = 'rabies'),
     CURRENT_DATE - 366, CURRENT_DATE - 1, 'manual',
     'verified', '00000000-0000-0000-0000-00000000b001', now());

INSERT INTO record_request (dog_id, owner_id, vaccine_type_id, channel, status)
VALUES
    ('00000000-0000-0000-0000-00000000d105', '00000000-0000-0000-0000-00000000a001',
     (SELECT id FROM vaccine_type WHERE code = 'rabies'), 'verbal_at_counter', 'sent');

-- --- The ladder --------------------------------------------------------------
SELECT is((SELECT state::text FROM v_dog_vaccine_compliance
            WHERE dog_id = '00000000-0000-0000-0000-00000000d001' AND vaccine_code = 'rabies'),
          'current',
          'Verified and well within date reads current');

SELECT is((SELECT state::text FROM v_dog_vaccine_compliance
            WHERE dog_id = '00000000-0000-0000-0000-00000000d002' AND vaccine_code = 'rabies'),
          'expiring_soon',
          'Ten days out falls inside the 30-day warning window');

SELECT is((SELECT state::text FROM v_dog_vaccine_compliance
            WHERE dog_id = '00000000-0000-0000-0000-00000000d003' AND vaccine_code = 'rabies'),
          'no_record',
          'A dog with nothing on file and nobody chasing reads no_record');

SELECT is((SELECT state::text FROM v_dog_vaccine_compliance
            WHERE dog_id = '00000000-0000-0000-0000-00000000d101' AND vaccine_code = 'rabies'),
          'expired',
          'Lapsed yesterday reads expired');

SELECT is((SELECT state::text FROM v_dog_vaccine_compliance
            WHERE dog_id = '00000000-0000-0000-0000-00000000d102' AND vaccine_code = 'rabies'),
          'received_unverified',
          'On file but unchecked reads received_unverified, not current');

SELECT is((SELECT state::text FROM v_dog_vaccine_compliance
            WHERE dog_id = '00000000-0000-0000-0000-00000000d103' AND vaccine_code = 'rabies'),
          'disputed_record',
          'Disputed outranks expiring_soon: a contested expiry is not schedulable');

SELECT is((SELECT state::text FROM v_dog_vaccine_compliance
            WHERE dog_id = '00000000-0000-0000-0000-00000000d104' AND vaccine_code = 'rabies'),
          'requested_pending',
          'No record but an open request reads requested_pending');

SELECT is((SELECT state::text FROM v_dog_vaccine_compliance
            WHERE dog_id = '00000000-0000-0000-0000-00000000d105' AND vaccine_code = 'rabies'),
          'expired',
          'Expired outranks requested_pending: the request is progress, not compliance');

-- --- Every active dog appears, structurally ---------------------------------
-- The detail view drives FROM dog CROSS JOIN tracked vaccines, so a dog cannot
-- be missing from the dashboard because a refresh job forgot about it.
SELECT is(
  (SELECT count(*) FROM v_dog_compliance_status),
  (SELECT count(*) FROM dog WHERE is_active),
  'Every active dog has exactly one rollup row'
);

SELECT is(
  (SELECT count(*) FROM v_dog_vaccine_compliance),
  (SELECT count(*) FROM dog WHERE is_active)
    * (SELECT count(*) FROM vaccine_type
        WHERE regulatory_required OR required_by_policy),
  'and one detail row per tracked vaccine'
);

-- --- Worst state wins -------------------------------------------------------
-- Jaddi's rabies is current, but nothing is on file for DHPP or Bordetella.
-- A dog compliant on one vaccine and missing two is not a compliant dog.
SELECT is(
  (SELECT state::text FROM v_dog_compliance_status
    WHERE dog_id = '00000000-0000-0000-0000-00000000d001'),
  'no_record',
  'The rollup takes the worst state across every tracked vaccine'
);

-- --- Blocking is per-vaccine configuration, not a global policy -------------
-- Only rabies carries blocks_service_if_expired. An expired Bordetella shows
-- red on the dashboard without cancelling the appointment.
SELECT is(
  (SELECT bool_or(m.blocks_service AND v.blocks_service_if_expired)
     FROM v_dog_vaccine_compliance v
     JOIN compliance_state_meta m ON m.state = v.state
    WHERE v.dog_id = '00000000-0000-0000-0000-00000000d001'),
  false,
  'A missing non-regulatory vaccine does not block service'
);

SELECT * FROM finish();
ROLLBACK;