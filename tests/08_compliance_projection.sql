-- Compliance projection equivalence.
--
-- dog_vaccine_compliance is a maintained table, refreshed by triggers on every
-- write to vaccination_record and record_request. v_dog_vaccine_compliance_recompute
-- derives the same facts live from source. They must never disagree.
--
-- This is the highest-stakes test in the suite. A bug in the refresh triggers
-- does not produce an error — it produces a dashboard that is quietly wrong,
-- which is the worst failure mode the system has.

BEGIN;
SET search_path = groom, public;
SELECT plan(12);

-- The divergence query, defined once. Symmetric: rows in the table that the
-- recompute does not produce, plus rows the recompute produces that the table
-- does not have.
CREATE TEMP VIEW compliance_divergence AS
    SELECT dog_id, vaccine_type_id, latest_record_id, expires_on,
           record_verification, open_request_id, request_count
      FROM groom.dog_vaccine_compliance
    EXCEPT
    SELECT dog_id, vaccine_type_id, latest_record_id, expires_on,
           record_verification, open_request_id, request_count
      FROM groom.v_dog_vaccine_compliance_recompute
  UNION ALL
    SELECT dog_id, vaccine_type_id, latest_record_id, expires_on,
           record_verification, open_request_id, request_count
      FROM groom.v_dog_vaccine_compliance_recompute
    EXCEPT
    SELECT dog_id, vaccine_type_id, latest_record_id, expires_on,
           record_verification, open_request_id, request_count
      FROM groom.dog_vaccine_compliance;

SELECT is_empty(
  'SELECT * FROM compliance_divergence',
  'Baseline: three dogs with no records, projection agrees with recompute'
);

-- Three vaccines are tracked (rabies by law, DHPP and Bordetella by policy).
-- Leptospirosis is neither, so it is recorded but never projected.
SELECT is(
  (SELECT count(*) FROM dog_vaccine_compliance
    WHERE dog_id = '00000000-0000-0000-0000-00000000d001'),
  3::bigint,
  'Each dog gets one row per tracked vaccine, not one row total'
);

-- --- A rabies certificate arrives -------------------------------------------
INSERT INTO vaccination_record
    (id, dog_id, vaccine_type_id, administered_on, expires_on, entry_method)
VALUES
    ('00000000-0000-0000-0000-00000000f101',
     '00000000-0000-0000-0000-00000000d001',
     (SELECT id FROM vaccine_type WHERE code = 'rabies'),
     DATE '2024-06-01', DATE '2027-06-01', 'manual');

SELECT is(
  (SELECT c.expires_on FROM dog_vaccine_compliance c
     JOIN vaccine_type vt ON vt.id = c.vaccine_type_id
    WHERE c.dog_id = '00000000-0000-0000-0000-00000000d001' AND vt.code = 'rabies'),
  DATE '2027-06-01',
  'The projection picks up the new certificate'
);

SELECT is_empty(
  'SELECT * FROM compliance_divergence',
  'and still agrees with the recompute'
);

-- --- An older certificate is backfilled after the current one ---------------
-- Latest EXPIRY governs, not latest created_at. A historical record entered
-- today must not displace a certificate that is still valid.
INSERT INTO vaccination_record
    (id, dog_id, vaccine_type_id, administered_on, expires_on, entry_method)
VALUES
    ('00000000-0000-0000-0000-00000000f102',
     '00000000-0000-0000-0000-00000000d001',
     (SELECT id FROM vaccine_type WHERE code = 'rabies'),
     DATE '2022-05-01', DATE '2025-05-01', 'manual');

SELECT is(
  (SELECT c.expires_on FROM dog_vaccine_compliance c
     JOIN vaccine_type vt ON vt.id = c.vaccine_type_id
    WHERE c.dog_id = '00000000-0000-0000-0000-00000000d001' AND vt.code = 'rabies'),
  DATE '2027-06-01',
  'A backfilled older certificate does not displace the current one'
);

SELECT is_empty(
  'SELECT * FROM compliance_divergence',
  'and the projection still agrees'
);

-- --- A request is opened for a different dog --------------------------------
INSERT INTO record_request
    (dog_id, owner_id, vaccine_type_id, channel, status)
VALUES
    ('00000000-0000-0000-0000-00000000d002',
     '00000000-0000-0000-0000-00000000a001',
     (SELECT id FROM vaccine_type WHERE code = 'rabies'),
     'verbal_at_counter', 'queued');

SELECT is(
  (SELECT c.open_request_id IS NOT NULL FROM dog_vaccine_compliance c
     JOIN vaccine_type vt ON vt.id = c.vaccine_type_id
    WHERE c.dog_id = '00000000-0000-0000-0000-00000000d002' AND vt.code = 'rabies'),
  true,
  'Opening a request updates that dog''s projection'
);

SELECT is_empty(
  'SELECT * FROM compliance_divergence',
  'and the projection agrees after a request write'
);

-- --- The current certificate is deleted -------------------------------------
-- Superseded records are retained, so the projection should fall back to the
-- older one rather than to nothing.
DELETE FROM vaccination_record
 WHERE id = '00000000-0000-0000-0000-00000000f101';

SELECT is(
  (SELECT c.expires_on FROM dog_vaccine_compliance c
     JOIN vaccine_type vt ON vt.id = c.vaccine_type_id
    WHERE c.dog_id = '00000000-0000-0000-0000-00000000d001' AND vt.code = 'rabies'),
  DATE '2025-05-01',
  'Deleting the governing record falls back to the retained older one'
);

SELECT is_empty(
  'SELECT * FROM compliance_divergence',
  'and the projection agrees after a delete'
);

-- --- A second vaccine on the same dog ---------------------------------------
-- The Jaddi invoice lists DHPP, Leptospira, Bordetella and Rabies on one page.
-- A DHPP record must land in its own projection row without touching rabies.
INSERT INTO vaccination_record
    (dog_id, vaccine_type_id, administered_on, expires_on, entry_method)
VALUES
    ('00000000-0000-0000-0000-00000000d001',
     (SELECT id FROM vaccine_type WHERE code = 'dhpp'),
     DATE '2025-04-04', DATE '2028-04-04', 'manual');

SELECT is(
  (SELECT c.expires_on FROM dog_vaccine_compliance c
     JOIN vaccine_type vt ON vt.id = c.vaccine_type_id
    WHERE c.dog_id = '00000000-0000-0000-0000-00000000d001' AND vt.code = 'dhpp'),
  DATE '2028-04-04',
  'A DHPP record lands in its own row and leaves rabies alone'
);

SELECT is_empty(
  'SELECT * FROM compliance_divergence',
  'and the projection still agrees across all tracked vaccines'
);

SELECT * FROM finish();
ROLLBACK;