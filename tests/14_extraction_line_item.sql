-- A line item is a row, its fields are still fields, and the review queue
-- empties itself.
--
-- The Doc Side email is replayed here: seven printed rows, seven expiry dates,
-- no administration dates. Six things are proven:
--   1. Shape. A field cannot claim a line item from a different extraction, a
--      line-item field name outside the contract is refused, and one slot
--      holds one value — while the same name on two different rows, or on a
--      row and at document level, is fine.
--   2. The review queue shows only terms nobody has ruled on, counts how often
--      each was seen, and a term leaves it the moment a ruling is inserted.
--   3. The queue reads the EFFECTIVE term: a reviewer's correction is looked
--      up by its corrected spelling, and a removed term never appears.
--   4. The pivot view shows one row per line item with corrections applied —
--      'removed' yields NULL, 'edited' yields the human's value.
--   5. can_create_record is false on every row of this document, for the same
--      reason test 04 creates no record from the invoice: a tracked vaccine
--      with one date is evidence, not a record.
--   6. Deleting an extraction takes its line items and their fields with it.

BEGIN;
SET search_path = groom, public;
SELECT plan(17);

-- --- Fixture: the Doc Side email, transcribed ---------------------------------
INSERT INTO document (id, owner_id, object_key, mime_type, byte_size, sha256,
                      doc_class, source, page_count) VALUES
  ('00000000-0000-0000-0000-0000000f1001',
   '00000000-0000-0000-0000-00000000a001',
   'docs/docside_email.pdf', 'application/pdf', 91200,
   repeat('b', 64), 'unknown', 'upload', 1);

INSERT INTO extraction (id, document_id, model_name, model_version,
                        prompt_version, raw_response, status) VALUES
  ('00000000-0000-0000-0000-0000000f1002',
   '00000000-0000-0000-0000-0000000f1001',
   'test-model', 'v0', 'p0', '{}'::jsonb, 'needs_review'),
  -- A second, unrelated extraction, used only to prove the composite FK.
  ('00000000-0000-0000-0000-0000000f1003',
   '00000000-0000-0000-0000-0000000f1001',
   'test-model', 'v0', 'p0', '{}'::jsonb, 'rejected');

-- Document-level field, dotted path, no line item.
INSERT INTO extraction_field (extraction_id, field_name, extracted_value, correction_action) VALUES
  ('00000000-0000-0000-0000-0000000f1002', 'clinic.name', 'Doc·Side Veterinary Medical Center', 'unreviewed'),
  ('00000000-0000-0000-0000-0000000f1002', 'patient.name', 'Nutmeg', 'unreviewed');

INSERT INTO extraction_line_item (id, extraction_id, n, page_number, source_region) VALUES
  ('00000000-0000-0000-0000-0000000f1101', '00000000-0000-0000-0000-0000000f1002', 1, 1, 'records_table'),
  ('00000000-0000-0000-0000-0000000f1102', '00000000-0000-0000-0000-0000000f1002', 2, 1, 'records_table'),
  ('00000000-0000-0000-0000-0000000f1103', '00000000-0000-0000-0000-0000000f1002', 3, 1, 'records_table'),
  ('00000000-0000-0000-0000-0000000f1104', '00000000-0000-0000-0000-0000000f1002', 4, 1, 'records_table'),
  ('00000000-0000-0000-0000-0000000f1105', '00000000-0000-0000-0000-0000000f1002', 5, 1, 'records_table'),
  -- A line item on the OTHER extraction.
  ('00000000-0000-0000-0000-0000000f1201', '00000000-0000-0000-0000-0000000f1003', 1, 1, NULL);

INSERT INTO extraction_field (extraction_id, line_item_id, field_name, extracted_value) VALUES
  -- Row 1: a seeded term, expiry only.
  ('00000000-0000-0000-0000-0000000f1002', '00000000-0000-0000-0000-0000000f1101', 'term',           'DHPP 3YR W/ LEPTO'),
  ('00000000-0000-0000-0000-0000000f1002', '00000000-0000-0000-0000-0000000f1101', 'expires_on_raw', '04/03/2028'),
  ('00000000-0000-0000-0000-0000000f1002', '00000000-0000-0000-0000-0000000f1101', 'expires_on',     '2028-04-03'),
  ('00000000-0000-0000-0000-0000000f1002', '00000000-0000-0000-0000-0000000f1101', 'status_raw',     'Active'),
  -- Row 2: rabies, seeded spelling.
  ('00000000-0000-0000-0000-0000000f1002', '00000000-0000-0000-0000-0000000f1102', 'term',           'Rabies Vaccine 3 Yr Canine'),
  ('00000000-0000-0000-0000-0000000f1002', '00000000-0000-0000-0000-0000000f1102', 'expires_on_raw', '03/07/2028'),
  ('00000000-0000-0000-0000-0000000f1002', '00000000-0000-0000-0000-0000000f1102', 'expires_on',     '2028-03-07'),
  -- Row 3: a term nobody has ruled on.
  ('00000000-0000-0000-0000-0000000f1002', '00000000-0000-0000-0000-0000000f1103', 'term',           'Canine Influenza H3N2/H3N8'),
  ('00000000-0000-0000-0000-0000000f1002', '00000000-0000-0000-0000-0000000f1103', 'expires_on',     '2027-04-02'),
  -- Row 4: the same unruled term again, different typography.
  ('00000000-0000-0000-0000-0000000f1002', '00000000-0000-0000-0000-0000000f1104', 'term',           'canine influenza h3n2 / h3n8'),
  -- Row 5: the model misread a seeded term; a reviewer will fix it.
  ('00000000-0000-0000-0000-0000000f1002', '00000000-0000-0000-0000-0000000f1105', 'term',           'Bordetella Annual Injectible'),
  ('00000000-0000-0000-0000-0000000f1002', '00000000-0000-0000-0000-0000000f1105', 'expires_on',     '2027-04-02'),
  -- The model invented an administration date on row 5. A reviewer will remove it.
  ('00000000-0000-0000-0000-0000000f1002', '00000000-0000-0000-0000-0000000f1105', 'administered_on', '2026-06-09');

-- --- 1. Shape ------------------------------------------------------------------
SELECT throws_ok(
  $$ INSERT INTO extraction_field (extraction_id, line_item_id, field_name, extracted_value)
     VALUES ('00000000-0000-0000-0000-0000000f1002',
             '00000000-0000-0000-0000-0000000f1201', 'term', 'smuggled') $$,
  '23503',
  NULL,
  'A field cannot point at a line item from a different extraction');

SELECT throws_ok(
  $$ INSERT INTO extraction_field (extraction_id, line_item_id, field_name, extracted_value)
     VALUES ('00000000-0000-0000-0000-0000000f1002',
             '00000000-0000-0000-0000-0000000f1101', 'price', '48.00') $$,
  '23514',
  NULL,
  'A line-item field outside the contract is refused at insert');

SELECT throws_ok(
  $$ INSERT INTO extraction_field (extraction_id, line_item_id, field_name, extracted_value)
     VALUES ('00000000-0000-0000-0000-0000000f1002',
             '00000000-0000-0000-0000-0000000f1101', 'term', 'a second term') $$,
  '23505',
  NULL,
  'One slot, one value: the same field twice on one line item is refused');

SELECT throws_ok(
  $$ INSERT INTO extraction_field (extraction_id, field_name, extracted_value)
     VALUES ('00000000-0000-0000-0000-0000000f1002', 'clinic.name', 'again') $$,
  '23505',
  NULL,
  'The document-level uniqueness the old constraint enforced still holds');

SELECT lives_ok(
  $$ INSERT INTO extraction_field (extraction_id, line_item_id, field_name, extracted_value)
     VALUES ('00000000-0000-0000-0000-0000000f1002',
             '00000000-0000-0000-0000-0000000f1102', 'tag_number', '240-680'),
            ('00000000-0000-0000-0000-0000000f1002',
             NULL, 'patient.tag_number', '240-680') $$,
  'The same fact in two slots — a tag on the row and in the patient block — coexists');

-- --- 2. The review queue -------------------------------------------------------
SELECT results_eq(
  $$ SELECT normalized, times_seen FROM v_unmapped_terms $$,
  $$ VALUES ('canine influenza h3n2/h3n8', 2::bigint),
            ('bordetella annual injectible', 1::bigint) $$,
  'The queue lists only unruled terms, collapsed by normalisation, busiest first');

INSERT INTO document_term (raw_term, vaccine_type_id, confidence, rationale)
VALUES ('Canine Influenza H3N2/H3N8', NULL, 'medium',
        'A real vaccine, but not one this shop tracks and not in vaccine_type; ruled not-a-vaccine for now.');

SELECT is((SELECT count(*) FROM v_unmapped_terms WHERE normalized LIKE 'canine influenza%'), 0::bigint,
  'One ruling and both spellings leave the queue on the next read');

-- --- 3. The queue reads the effective term -------------------------------------
UPDATE extraction_field
   SET correction_action = 'edited', corrected_value = 'Bordetella Annual Injectable'
 WHERE line_item_id = '00000000-0000-0000-0000-0000000f1105' AND field_name = 'term';

SELECT is((SELECT count(*) FROM v_unmapped_terms), 0::bigint,
  'A corrected term is looked up by its corrected spelling and leaves the queue');

UPDATE extraction_field
   SET correction_action = 'removed'
 WHERE line_item_id = '00000000-0000-0000-0000-0000000f1105' AND field_name = 'administered_on';

-- --- 4. The pivot view ---------------------------------------------------------
SELECT is((SELECT term FROM v_extraction_line_item WHERE line_item_id = '00000000-0000-0000-0000-0000000f1105'),
  'Bordetella Annual Injectable',
  'The pivot shows the edited value, not what the model said');

SELECT is((SELECT administered_on FROM v_extraction_line_item WHERE line_item_id = '00000000-0000-0000-0000-0000000f1105'),
  NULL,
  'A removed field pivots to NULL: the hallucination is gone from the row');

SELECT is((SELECT removed_count FROM v_extraction_line_item WHERE line_item_id = '00000000-0000-0000-0000-0000000f1105'),
  1::bigint,
  '...and is still counted, so the error analysis does not lose it');

SELECT results_eq(
  $$ SELECT n, disposition::text, vaccine_code FROM v_extraction_line_item
      WHERE extraction_id = '00000000-0000-0000-0000-0000000f1002' ORDER BY n $$,
  $$ VALUES (1, 'tracked', 'dhpp'), (2, 'tracked', 'rabies'),
            (3, 'not_a_vaccine', NULL), (4, 'not_a_vaccine', NULL),
            (5, 'tracked', 'bordetella') $$,
  'Layer 2 sits beside Layer 1: every row carries its resolution');

-- --- 5. Evidence, not records --------------------------------------------------
SELECT is((SELECT count(*) FROM v_extraction_line_item
            WHERE extraction_id = '00000000-0000-0000-0000-0000000f1002' AND can_create_record),
  0::bigint,
  'Three tracked vaccines with expiry dates and no administration dates: nothing can become a record');

INSERT INTO extraction_field (extraction_id, line_item_id, field_name, extracted_value, correction_action) VALUES
  ('00000000-0000-0000-0000-0000000f1002', '00000000-0000-0000-0000-0000000f1102', 'administered_on', '2025-03-08', 'confirmed');

SELECT results_eq(
  $$ SELECT n FROM v_extraction_line_item
      WHERE extraction_id = '00000000-0000-0000-0000-0000000f1002' AND can_create_record $$,
  $$ VALUES (2) $$,
  'Supply the missing date on one row and exactly that row becomes eligible');

-- --- 6. Cascade ----------------------------------------------------------------
DELETE FROM extraction WHERE id = '00000000-0000-0000-0000-0000000f1002';

SELECT is((SELECT count(*) FROM extraction_line_item
            WHERE extraction_id = '00000000-0000-0000-0000-0000000f1002'), 0::bigint,
  'Deleting the extraction removes its line items');

SELECT is((SELECT count(*) FROM extraction_field
            WHERE extraction_id = '00000000-0000-0000-0000-0000000f1002'), 0::bigint,
  '...and every field, document-level and line-item alike');

SELECT is((SELECT count(*) FROM extraction_line_item
            WHERE extraction_id = '00000000-0000-0000-0000-0000000f1003'), 1::bigint,
  'The other extraction is untouched');

SELECT * FROM finish();
ROLLBACK;
