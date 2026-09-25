-- Layer 3: a reviewed page becomes paperwork, and only a reviewed page does.
--
-- The fixture is one page for Jaddi carrying every kind of line Layer 3 has to
-- decide on:
--   1. Rabies, both dates printed — becomes a record.
--   2. DHPP, the held-out photo's case: the expiry is too faint to read, the
--      model supplied a clean one anyway, and the reviewer marks it unreadable.
--      Evidence, no record, and not a hallucination either.
--   3. A Lyme test — not a vaccine.
--   4. Rabies again, same shot printed a second time — must not become a
--      second record.
--   5. Bordetella from an old certificate, long expired — a true record that
--      does not answer the shop's outstanding request for a current one.
--
-- Ten things are proven:
--   1. Four refusals, one per code: not awaiting review (GR015), review
--      unfinished (GR016), wrong dog (GR017), unusable date (GR018). Each
--      refusal writes nothing.
--   2. Each line's outcome, returned and stored.
--   3. The record carries the page's values, verified and signed by the
--      reviewer.
--   4. A shot printed twice is one record.
--   5. A missing date asks the owner — once, on the channel they allow — and
--      the dog stays non-compliant rather than 'requested'.
--   6. A current record closes the open request for it; an expired one does not.
--   7. The dashboard projection still equals a live recompute.
--   8. A second reading of the same page adds nothing, and a reading that
--      disagrees with the record on file is flagged, not written — including
--      a misread day a few days off, the photo's actual error. A booster months
--      later is a new shot. The window is the shop's setting.
--   9. Confirmed evidence cannot be deleted.
--  10. An unreadable date is counted as a capture problem, not charged to the
--      model as an invented value.

BEGIN;
SET search_path = groom, public;
SELECT plan(36);

-- --- Fixture -----------------------------------------------------------------
-- Jaddi (d001) and Luna (d002) belong to owner a001; Biscuit (d003) to a002.
-- The page is filed under Jaddi and Luna, as a household invoice would be.
INSERT INTO document (id, owner_id, object_key, mime_type, byte_size, sha256,
                      doc_class, source, page_count) VALUES
  ('00000000-0000-0000-0000-0000000f3001', '00000000-0000-0000-0000-00000000a001',
   'docs/confirm_page.pdf', 'application/pdf', 1000, repeat('d', 64), 'vet_invoice', 'upload', 1);
INSERT INTO document_dog (document_id, dog_id) VALUES
  ('00000000-0000-0000-0000-0000000f3001', '00000000-0000-0000-0000-00000000d001'),
  ('00000000-0000-0000-0000-0000000f3001', '00000000-0000-0000-0000-00000000d002');

INSERT INTO extraction (id, document_id, model_name, model_version, prompt_version,
                        raw_response, status) VALUES
  ('00000000-0000-0000-0000-0000000f3002', '00000000-0000-0000-0000-0000000f3001',
   'test-model', 'test-model-1', 'p0', '{}'::jsonb, 'needs_review');

INSERT INTO extraction_line_item (id, extraction_id, n) VALUES
  ('00000000-0000-0000-0000-0000000f3101', '00000000-0000-0000-0000-0000000f3002', 1),
  ('00000000-0000-0000-0000-0000000f3102', '00000000-0000-0000-0000-0000000f3002', 2),
  ('00000000-0000-0000-0000-0000000f3103', '00000000-0000-0000-0000-0000000f3002', 3),
  ('00000000-0000-0000-0000-0000000f3104', '00000000-0000-0000-0000-0000000f3002', 4),
  ('00000000-0000-0000-0000-0000000f3105', '00000000-0000-0000-0000-0000000f3002', 5);

-- The rabies expiry is relative to today, so the record stays current however
-- long this suite lives.
CREATE TEMP TABLE t_dates AS
SELECT to_char(CURRENT_DATE + 400, 'YYYY-MM-DD') AS rabies_exp;

INSERT INTO extraction_field (extraction_id, line_item_id, field_name, extracted_value) VALUES
  ('00000000-0000-0000-0000-0000000f3002', '00000000-0000-0000-0000-0000000f3101', 'term',              'Rabies Vaccine 3 Yr Canine'),
  ('00000000-0000-0000-0000-0000000f3002', '00000000-0000-0000-0000-0000000f3101', 'administered_on',   '2025-10-15'),
  ('00000000-0000-0000-0000-0000000f3002', '00000000-0000-0000-0000-0000000f3101', 'expires_on',        (SELECT rabies_exp FROM t_dates)),
  ('00000000-0000-0000-0000-0000000f3002', '00000000-0000-0000-0000-0000000f3101', 'lot_serial_number', 'RB-4471'),
  ('00000000-0000-0000-0000-0000000f3002', '00000000-0000-0000-0000-0000000f3102', 'term',              'DHPP 3YR'),
  ('00000000-0000-0000-0000-0000000f3002', '00000000-0000-0000-0000-0000000f3102', 'administered_on',   '2025-10-15'),
  ('00000000-0000-0000-0000-0000000f3002', '00000000-0000-0000-0000-0000000f3102', 'expires_on',        '2026-10-15'),
  ('00000000-0000-0000-0000-0000000f3002', '00000000-0000-0000-0000-0000000f3103', 'term',              'Canine Lyme Test'),
  ('00000000-0000-0000-0000-0000000f3002', '00000000-0000-0000-0000-0000000f3103', 'administered_on',   '2025-10-15'),
  ('00000000-0000-0000-0000-0000000f3002', '00000000-0000-0000-0000-0000000f3104', 'term',              'Rabies Vaccine 3 Yr Canine'),
  ('00000000-0000-0000-0000-0000000f3002', '00000000-0000-0000-0000-0000000f3104', 'administered_on',   '2025-10-15'),
  ('00000000-0000-0000-0000-0000000f3002', '00000000-0000-0000-0000-0000000f3104', 'expires_on',        (SELECT rabies_exp FROM t_dates)),
  ('00000000-0000-0000-0000-0000000f3002', '00000000-0000-0000-0000-0000000f3105', 'term',              'Bordetella Annual Injectable'),
  ('00000000-0000-0000-0000-0000000f3002', '00000000-0000-0000-0000-0000000f3105', 'administered_on',   '2024-01-10'),
  ('00000000-0000-0000-0000-0000000f3002', '00000000-0000-0000-0000-0000000f3105', 'expires_on',        '2025-01-10');

-- The shop is already chasing Jaddi's rabies and bordetella.
INSERT INTO record_request (id, dog_id, owner_id, vaccine_type_id, channel, recipient_address,
                            status, unsubscribe_token) VALUES
  ('00000000-0000-0000-0000-0000000f3201', '00000000-0000-0000-0000-00000000d001',
   '00000000-0000-0000-0000-00000000a001', (SELECT id FROM vaccine_type WHERE code = 'rabies'),
   'email', 'jason@example.test', 'sent', 'tok-rabies'),
  ('00000000-0000-0000-0000-0000000f3202', '00000000-0000-0000-0000-00000000d001',
   '00000000-0000-0000-0000-00000000a001', (SELECT id FROM vaccine_type WHERE code = 'bordetella'),
   'email', 'jason@example.test', 'sent', 'tok-bordetella');

-- --- 1. Refusals -----------------------------------------------------------------
SELECT throws_ok(
  $$ SELECT * FROM confirm_extraction('00000000-0000-0000-0000-0000000f3002',
                                      '00000000-0000-0000-0000-00000000d001',
                                      '00000000-0000-0000-0000-00000000b001') $$,
  'GR016', NULL,
  'Nothing reviewed yet: the page cannot be confirmed');

-- The reviewer works the page. Line 2's expiry is too faint to read.
UPDATE extraction_field SET correction_action = 'confirmed'
 WHERE extraction_id = '00000000-0000-0000-0000-0000000f3002'
   AND line_item_id IN ('00000000-0000-0000-0000-0000000f3101', '00000000-0000-0000-0000-0000000f3102',
                        '00000000-0000-0000-0000-0000000f3104')
   AND field_name IN ('term', 'administered_on', 'expires_on', 'lot_serial_number');
UPDATE extraction_field SET correction_action = 'unreadable'
 WHERE line_item_id = '00000000-0000-0000-0000-0000000f3102' AND field_name = 'expires_on';

SELECT throws_ok(
  $$ SELECT * FROM confirm_extraction('00000000-0000-0000-0000-0000000f3002',
                                      '00000000-0000-0000-0000-00000000d001',
                                      '00000000-0000-0000-0000-00000000b001') $$,
  'GR016', NULL,
  'One tracked line still unchecked — the old bordetella certificate — is enough to refuse');

UPDATE extraction_field SET correction_action = 'confirmed'
 WHERE line_item_id = '00000000-0000-0000-0000-0000000f3105';

SELECT throws_ok(
  $$ SELECT * FROM confirm_extraction('00000000-0000-0000-0000-0000000f3002',
                                      '00000000-0000-0000-0000-00000000d003',
                                      '00000000-0000-0000-0000-00000000b001') $$,
  'GR017', NULL,
  'Biscuit is another household''s dog: the page cannot become his paperwork');

-- A reviewer "corrects" the rabies shot to a day that does not exist.
UPDATE extraction_field SET correction_action = 'edited', corrected_value = '2025-02-30'
 WHERE line_item_id = '00000000-0000-0000-0000-0000000f3101' AND field_name = 'administered_on';

SELECT throws_ok(
  $$ SELECT * FROM confirm_extraction('00000000-0000-0000-0000-0000000f3002',
                                      '00000000-0000-0000-0000-00000000d001',
                                      '00000000-0000-0000-0000-00000000b001') $$,
  'GR018', NULL,
  'February 30th cannot go on a vaccination record');

UPDATE extraction_field SET correction_action = 'edited', corrected_value = to_char(CURRENT_DATE + 1, 'YYYY-MM-DD')
 WHERE line_item_id = '00000000-0000-0000-0000-0000000f3101' AND field_name = 'administered_on';

SELECT throws_ok(
  $$ SELECT * FROM confirm_extraction('00000000-0000-0000-0000-0000000f3002',
                                      '00000000-0000-0000-0000-00000000d001',
                                      '00000000-0000-0000-0000-00000000b001') $$,
  'GR018', NULL,
  'Nor can a shot given tomorrow');

UPDATE extraction_field SET correction_action = 'confirmed', corrected_value = NULL
 WHERE line_item_id = '00000000-0000-0000-0000-0000000f3101' AND field_name = 'administered_on';

SELECT is((SELECT count(*) FROM vaccination_record WHERE dog_id = '00000000-0000-0000-0000-00000000d001')
          + (SELECT count(*) FROM extraction_confirmation), 0::bigint,
  'Every refusal left nothing behind: no record, no confirmation');

-- --- 2. Outcomes ---------------------------------------------------------------------
CREATE TEMP TABLE t_result AS
SELECT * FROM confirm_extraction('00000000-0000-0000-0000-0000000f3002',
                                 '00000000-0000-0000-0000-00000000d001',
                                 '00000000-0000-0000-0000-00000000b001');

SELECT results_eq(
  $$ SELECT n, vaccine_code, outcome::text FROM t_result ORDER BY n $$,
  $$ VALUES (1, 'rabies', 'record_created'), (2, 'dhpp', 'missing_date'),
            (3, NULL, 'not_tracked'),       (4, 'rabies', 'already_on_file'),
            (5, 'bordetella', 'record_created') $$,
  'Every line has an outcome: two records, a duplicate, a missing date, a test');

SELECT is((SELECT count(*) FROM line_item_outcome
            WHERE extraction_id = '00000000-0000-0000-0000-0000000f3002'), 5::bigint,
  'The outcomes are stored, not just returned');

SELECT is((SELECT status::text FROM extraction WHERE id = '00000000-0000-0000-0000-0000000f3002'),
  'accepted', 'The extraction leaves the review queue');

-- --- 3. The record ---------------------------------------------------------------------
SELECT results_eq(
  $$ SELECT administered_on, expires_on, lot_serial_number, entry_method::text,
            verification_status::text, verified_by, document_id
       FROM vaccination_record vr
       JOIN t_result r ON r.vaccination_record_id = vr.id
      WHERE r.n = 1 $$,
  $$ SELECT '2025-10-15'::date, (SELECT rabies_exp FROM t_dates)::date, 'RB-4471', 'extracted',
            'verified', '00000000-0000-0000-0000-00000000b001'::uuid,
            '00000000-0000-0000-0000-0000000f3001'::uuid $$,
  'The rabies record carries the page''s dates and lot, verified by the reviewer, tied to its document');

SELECT is((SELECT count(*) FROM audit_log
            WHERE entity_type = 'vaccination_record' AND action = 'create'
              AND actor_id = '00000000-0000-0000-0000-00000000b001' AND actor_label = 'Nadia'),
  2::bigint, 'Each record''s creation is in the audit log under the reviewer''s name');

SELECT is((SELECT state::text FROM v_dog_vaccine_compliance
            WHERE dog_id = '00000000-0000-0000-0000-00000000d001' AND vaccine_code = 'rabies'),
  'current', 'Jaddi''s rabies is current on the dashboard');

SELECT is((SELECT count(*) FROM vaccination_record WHERE dog_id = '00000000-0000-0000-0000-00000000d002'),
  0::bigint, 'Luna shares the page but was not the dog confirmed: she gets nothing');

-- --- 4. Printed twice, recorded once --------------------------------------------------------
SELECT is((SELECT count(*) FROM vaccination_record vr
             JOIN vaccine_type vt ON vt.id = vr.vaccine_type_id
            WHERE vr.dog_id = '00000000-0000-0000-0000-00000000d001' AND vt.code = 'rabies'),
  1::bigint, 'One rabies shot, printed twice, is one record');

SELECT is((SELECT vaccination_record_id FROM t_result WHERE n = 4),
          (SELECT vaccination_record_id FROM t_result WHERE n = 1),
  'The second printing points at the record the first one made');

-- --- 5. A missing date -------------------------------------------------------------------------
SELECT is((SELECT count(*) FROM vaccination_record vr
             JOIN vaccine_type vt ON vt.id = vr.vaccine_type_id
            WHERE vr.dog_id = '00000000-0000-0000-0000-00000000d001' AND vt.code = 'dhpp'),
  0::bigint, 'The DHPP line with its unreadable expiry creates no record');

SELECT results_eq(
  $$ SELECT rr.status::text, rr.channel::text, rr.created_by
       FROM record_request rr JOIN t_result r ON r.record_request_id = rr.id WHERE r.n = 2 $$,
  $$ VALUES ('insufficient', 'email', '00000000-0000-0000-0000-00000000b001'::uuid) $$,
  'The owner is marked as owing a readable DHPP certificate, by email, which they allow');

SELECT results_eq(
  $$ SELECT removed, unreadable, removal_rate FROM v_model_review_outcomes WHERE prompt_version = 'p0' $$,
  $$ VALUES (0::bigint, 1::bigint, 0.0000::numeric) $$,
  'The faint date is counted as unreadable, and the model''s hallucination rate is untouched by it');

SELECT is((SELECT state::text FROM v_dog_vaccine_compliance
            WHERE dog_id = '00000000-0000-0000-0000-00000000d001' AND vaccine_code = 'dhpp'),
  'no_record', 'Jaddi''s DHPP stays non-compliant — an insufficient answer is not a pending one');

-- --- 6. Which records answer which requests --------------------------------------------------------
SELECT results_eq(
  $$ SELECT status::text, resolved_by_document_id FROM record_request
      WHERE id = '00000000-0000-0000-0000-0000000f3201' $$,
  $$ VALUES ('resolved', '00000000-0000-0000-0000-0000000f3001'::uuid) $$,
  'The current rabies record closes the open rabies request, naming the page that closed it');

SELECT is((SELECT status::text FROM record_request WHERE id = '00000000-0000-0000-0000-0000000f3202'),
  'sent', 'An expired bordetella certificate is true history, but the request for a current one stays open');

SELECT is((SELECT state::text FROM v_dog_vaccine_compliance
            WHERE dog_id = '00000000-0000-0000-0000-00000000d001' AND vaccine_code = 'bordetella'),
  'expired', 'And the dashboard says so');

-- --- 7. The projection -------------------------------------------------------------------------------
SELECT is_empty(
  $$ (SELECT dog_id, vaccine_type_id, latest_record_id, expires_on, record_verification,
             open_request_id, request_count FROM dog_vaccine_compliance
      EXCEPT
      SELECT dog_id, vaccine_type_id, latest_record_id, expires_on, record_verification,
             open_request_id, request_count FROM v_dog_vaccine_compliance_recompute)
     UNION ALL
     (SELECT dog_id, vaccine_type_id, latest_record_id, expires_on, record_verification,
             open_request_id, request_count FROM v_dog_vaccine_compliance_recompute
      EXCEPT
      SELECT dog_id, vaccine_type_id, latest_record_id, expires_on, record_verification,
             open_request_id, request_count FROM dog_vaccine_compliance) $$,
  'After confirmation, the dashboard table still equals a live recompute');

-- --- 1, continued: confirming twice -----------------------------------------------------------------
SELECT throws_ok(
  $$ SELECT * FROM confirm_extraction('00000000-0000-0000-0000-0000000f3002',
                                      '00000000-0000-0000-0000-00000000d001',
                                      '00000000-0000-0000-0000-00000000b001') $$,
  'GR015', NULL,
  'A confirmed page cannot be confirmed again');

-- --- 8. The same page, read again ----------------------------------------------------------------------
-- A second model run on the same document reads rabies exactly as the first
-- did. A third reads a different rabies expiry, and a different reviewer
-- confirms it — so two confirmed readings of one shot now disagree.
INSERT INTO extraction (id, document_id, model_name, model_version, prompt_version,
                        raw_response, status) VALUES
  ('00000000-0000-0000-0000-0000000f3003', '00000000-0000-0000-0000-0000000f3001',
   'test-model', 'test-model-1', 'p1', '{}'::jsonb, 'needs_review'),
  ('00000000-0000-0000-0000-0000000f3004', '00000000-0000-0000-0000-0000000f3001',
   'test-model', 'test-model-1', 'p2', '{}'::jsonb, 'needs_review');
INSERT INTO extraction_line_item (id, extraction_id, n) VALUES
  ('00000000-0000-0000-0000-0000000f3301', '00000000-0000-0000-0000-0000000f3003', 1),
  ('00000000-0000-0000-0000-0000000f3401', '00000000-0000-0000-0000-0000000f3004', 1);
INSERT INTO extraction_field (extraction_id, line_item_id, field_name, extracted_value, correction_action) VALUES
  ('00000000-0000-0000-0000-0000000f3003', '00000000-0000-0000-0000-0000000f3301', 'term',            'Rabies Vaccine 3 Yr Canine', 'confirmed'),
  ('00000000-0000-0000-0000-0000000f3003', '00000000-0000-0000-0000-0000000f3301', 'administered_on', '2025-10-15', 'confirmed'),
  ('00000000-0000-0000-0000-0000000f3003', '00000000-0000-0000-0000-0000000f3301', 'expires_on',      (SELECT rabies_exp FROM t_dates), 'confirmed'),
  ('00000000-0000-0000-0000-0000000f3004', '00000000-0000-0000-0000-0000000f3401', 'term',            'Rabies Vaccine 3 Yr Canine', 'confirmed'),
  ('00000000-0000-0000-0000-0000000f3004', '00000000-0000-0000-0000-0000000f3401', 'administered_on', '2025-10-15', 'confirmed'),
  ('00000000-0000-0000-0000-0000000f3004', '00000000-0000-0000-0000-0000000f3401', 'expires_on',      '2026-10-15', 'confirmed');

SELECT results_eq(
  $$ SELECT outcome::text FROM confirm_extraction('00000000-0000-0000-0000-0000000f3003',
                                                  '00000000-0000-0000-0000-00000000d001',
                                                  '00000000-0000-0000-0000-00000000b002') $$,
  $$ VALUES ('already_on_file') $$,
  'A second reading of a shot already on file adds nothing');

SELECT results_eq(
  $$ SELECT outcome::text FROM confirm_extraction('00000000-0000-0000-0000-0000000f3004',
                                                  '00000000-0000-0000-0000-00000000d001',
                                                  '00000000-0000-0000-0000-00000000b002') $$,
  $$ VALUES ('conflicts_with_record') $$,
  'A reading that disagrees with the record on file is flagged as a conflict...');

SELECT results_eq(
  $$ SELECT count(*), max(expires_on) FROM vaccination_record vr
       JOIN vaccine_type vt ON vt.id = vr.vaccine_type_id
      WHERE vr.dog_id = '00000000-0000-0000-0000-00000000d001' AND vt.code = 'rabies' $$,
  $$ SELECT 1::bigint, (SELECT rabies_exp FROM t_dates)::date $$,
  '...and the record on file is left exactly as it was');

-- --- 8, continued: a misread day -------------------------------------------------------------------
-- The photo's actual error: the model read 'Oct 15' as 'Oct 19', and a reviewer
-- let it through. Jaddi's rabies shot on file was given Oct 15.
INSERT INTO extraction (id, document_id, model_name, model_version, prompt_version,
                        raw_response, status) VALUES
  ('00000000-0000-0000-0000-0000000f3006', '00000000-0000-0000-0000-0000000f3001',
   'test-model', 'test-model-1', 'p4', '{}'::jsonb, 'needs_review'),
  ('00000000-0000-0000-0000-0000000f3007', '00000000-0000-0000-0000-0000000f3001',
   'test-model', 'test-model-1', 'p5', '{}'::jsonb, 'needs_review'),
  ('00000000-0000-0000-0000-0000000f3008', '00000000-0000-0000-0000-0000000f3001',
   'test-model', 'test-model-1', 'p6', '{}'::jsonb, 'needs_review');
INSERT INTO extraction_line_item (id, extraction_id, n) VALUES
  ('00000000-0000-0000-0000-0000000f3601', '00000000-0000-0000-0000-0000000f3006', 1),
  ('00000000-0000-0000-0000-0000000f3701', '00000000-0000-0000-0000-0000000f3007', 1),
  ('00000000-0000-0000-0000-0000000f3801', '00000000-0000-0000-0000-0000000f3008', 1);
INSERT INTO extraction_field (extraction_id, line_item_id, field_name, extracted_value, correction_action) VALUES
  ('00000000-0000-0000-0000-0000000f3006', '00000000-0000-0000-0000-0000000f3601', 'term',            'Rabies Vaccine 3 Yr Canine', 'confirmed'),
  ('00000000-0000-0000-0000-0000000f3006', '00000000-0000-0000-0000-0000000f3601', 'administered_on', '2025-10-19', 'confirmed'),
  ('00000000-0000-0000-0000-0000000f3006', '00000000-0000-0000-0000-0000000f3601', 'expires_on',      (SELECT rabies_exp FROM t_dates), 'confirmed'),
  -- A bordetella booster, eighteen months after the expired one on file.
  ('00000000-0000-0000-0000-0000000f3007', '00000000-0000-0000-0000-0000000f3701', 'term',            'Bordetella Annual Injectable', 'confirmed'),
  ('00000000-0000-0000-0000-0000000f3007', '00000000-0000-0000-0000-0000000f3701', 'administered_on', '2025-07-10', 'confirmed'),
  ('00000000-0000-0000-0000-0000000f3007', '00000000-0000-0000-0000-0000000f3701', 'expires_on',      to_char(CURRENT_DATE + 100, 'YYYY-MM-DD'), 'confirmed'),
  ('00000000-0000-0000-0000-0000000f3008', '00000000-0000-0000-0000-0000000f3801', 'term',            'Rabies Vaccine 3 Yr Canine', 'confirmed'),
  ('00000000-0000-0000-0000-0000000f3008', '00000000-0000-0000-0000-0000000f3801', 'administered_on', '2025-10-19', 'confirmed'),
  ('00000000-0000-0000-0000-0000000f3008', '00000000-0000-0000-0000-0000000f3801', 'expires_on',      (SELECT rabies_exp FROM t_dates), 'confirmed');

SELECT results_eq(
  $$ SELECT outcome::text FROM confirm_extraction('00000000-0000-0000-0000-0000000f3006',
                                                  '00000000-0000-0000-0000-00000000d001',
                                                  '00000000-0000-0000-0000-00000000b002') $$,
  $$ VALUES ('conflicts_with_record') $$,
  'A shot given four days from one on file is the same shot read two ways: a conflict, not a second record');

SELECT is((SELECT count(*) FROM vaccination_record vr
             JOIN vaccine_type vt ON vt.id = vr.vaccine_type_id
            WHERE vr.dog_id = '00000000-0000-0000-0000-00000000d001' AND vt.code = 'rabies'),
  1::bigint, 'Jaddi still has one rabies record');

SELECT results_eq(
  $$ SELECT outcome::text FROM confirm_extraction('00000000-0000-0000-0000-0000000f3007',
                                                  '00000000-0000-0000-0000-00000000d001',
                                                  '00000000-0000-0000-0000-00000000b002') $$,
  $$ VALUES ('record_created') $$,
  'A booster eighteen months after the last shot is a new shot, not a duplicate');

SELECT is((SELECT status::text FROM record_request WHERE id = '00000000-0000-0000-0000-0000000f3202'),
  'resolved', '...and being current, it closes the bordetella request the expired one could not');

UPDATE shop_policy SET int_value = 0 WHERE key = 'duplicate_shot_window_days';

SELECT results_eq(
  $$ SELECT outcome::text FROM confirm_extraction('00000000-0000-0000-0000-0000000f3008',
                                                  '00000000-0000-0000-0000-00000000d001',
                                                  '00000000-0000-0000-0000-00000000b002') $$,
  $$ VALUES ('record_created') $$,
  'The window is the shop''s setting: at zero, only exact dates match, and the misread day becomes a record');

-- --- 5, continued: the Jaddi invoice, through the real function ---------------------------------------
-- Rabies and its date given; no expiry anywhere. Luna has no rabies record, and
-- her owner's email is not opted out.
INSERT INTO extraction (id, document_id, model_name, model_version, prompt_version,
                        raw_response, status) VALUES
  ('00000000-0000-0000-0000-0000000f3005', '00000000-0000-0000-0000-0000000f3001',
   'test-model', 'test-model-1', 'p3', '{}'::jsonb, 'needs_review');
INSERT INTO extraction_line_item (id, extraction_id, n) VALUES
  ('00000000-0000-0000-0000-0000000f3501', '00000000-0000-0000-0000-0000000f3005', 1);
INSERT INTO extraction_field (extraction_id, line_item_id, field_name, extracted_value, correction_action) VALUES
  ('00000000-0000-0000-0000-0000000f3005', '00000000-0000-0000-0000-0000000f3501', 'term',            'Rabies Vaccination 3 Yr.', 'confirmed'),
  ('00000000-0000-0000-0000-0000000f3005', '00000000-0000-0000-0000-0000000f3501', 'administered_on', '2025-03-08', 'confirmed');

SELECT results_eq(
  $$ SELECT outcome::text, record_request_id IS NOT NULL
       FROM confirm_extraction('00000000-0000-0000-0000-0000000f3005',
                               '00000000-0000-0000-0000-00000000d002',
                               '00000000-0000-0000-0000-00000000b001') $$,
  $$ VALUES ('missing_date', true) $$,
  'Rabies named, no expiry: no record, and the owner is asked for the certificate');

SELECT is((SELECT state::text FROM v_dog_vaccine_compliance
            WHERE dog_id = '00000000-0000-0000-0000-00000000d002' AND vaccine_code = 'rabies'),
  'no_record', 'Luna stays non-compliant, which is the honest answer');

-- --- 9. Evidence stays ------------------------------------------------------------------------------------
SELECT throws_ok(
  $$ DELETE FROM extraction WHERE id = '00000000-0000-0000-0000-0000000f3002' $$,
  '23503', NULL,
  'An extraction that produced a record cannot be deleted out from under it');

SELECT is(iso_date_or_null('10/15/2025'), NULL,
  'Only year-month-day becomes a date: a US-style date is not guessed at');

SELECT * FROM finish();
ROLLBACK;
