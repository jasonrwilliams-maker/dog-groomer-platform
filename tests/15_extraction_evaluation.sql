-- Evaluation is stored honestly, and the review report says why.
--
-- The fixture is the invoice's worst case: a tracked rabies reminder where the
-- model supplied a day to '03-28'. Both dates are present, so the row is a
-- record candidate — and nothing in sections 7, 15 or 16 can tell an invented
-- day from a printed one. Section 16 holds it back until a human has reviewed
-- it; this file proves the review report says which date to look at first.
--
-- Eight things are proven:
--   1. field_key is one derivation on both sides, and generated.
--   2. The review priority names its reasons: a date more precise than its
--      print, a date with no print at all, a value that will land in a record,
--      a term nobody has ruled on. Each is high. A field with none is low —
--      including every field on a tracked row that cannot become a record.
--   3. The review summary counts what a groomer needs first: rows, tracked
--      rows, records ready, records waiting on review and how many of those
--      rest on a suspect date, records blocked, unmapped terms.
--   4. An evaluation result that contradicts the scorer's own vocabulary
--      cannot be stored, nor can a duplicate scoring, nor an evaluation of an
--      extraction some other prompt produced.
--   5. The run summary reports two accuracies, and the honest one is lower.
--   6. History flags a field only past the shop's thresholds, only for the
--      same model and prompt, and only from the latest scoring of a run.
--   7. An unregistered reason fails closed to high.
--   8. Reviewers' corrections flag a field the same way evaluation does, and
--      a reviewed field leaves the work order.

BEGIN;
SET search_path = groom, public;
SELECT plan(31);

-- --- Fixture -------------------------------------------------------------------
INSERT INTO document (id, owner_id, object_key, mime_type, byte_size, sha256,
                      doc_class, source, page_count) VALUES
  ('00000000-0000-0000-0000-0000000f2001', '00000000-0000-0000-0000-00000000a001',
   'docs/eval_invoice.pdf', 'application/pdf', 1000, repeat('c', 64), 'vet_invoice', 'upload', 1);

INSERT INTO extraction (id, document_id, model_name, model_version, prompt_version,
                        raw_response, status) VALUES
  ('00000000-0000-0000-0000-0000000f2002', '00000000-0000-0000-0000-0000000f2001',
   'test-model', 'test-model-1', 'p0', '{}'::jsonb, 'needs_review'),
  ('00000000-0000-0000-0000-0000000f2003', '00000000-0000-0000-0000-0000000f2001',
   'test-model', 'test-model-1', 'p-other', '{}'::jsonb, 'accepted');

INSERT INTO extraction_line_item (id, extraction_id, n) VALUES
  ('00000000-0000-0000-0000-0000000f2101', '00000000-0000-0000-0000-0000000f2002', 1),
  ('00000000-0000-0000-0000-0000000f2102', '00000000-0000-0000-0000-0000000f2002', 2),
  ('00000000-0000-0000-0000-0000000f2103', '00000000-0000-0000-0000-0000000f2002', 3),
  ('00000000-0000-0000-0000-0000000f2104', '00000000-0000-0000-0000-0000000f2002', 4);

INSERT INTO extraction_field (extraction_id, line_item_id, field_name, extracted_value) VALUES
  ('00000000-0000-0000-0000-0000000f2002', NULL, 'clinic.phone', '410-522-0055'),
  ('00000000-0000-0000-0000-0000000f2002', NULL, 'clinic.email', 'front@clinic.example'),
  -- Row 1: tracked rabies. The print is a month; the ISO date has a day.
  ('00000000-0000-0000-0000-0000000f2002', '00000000-0000-0000-0000-0000000f2101', 'term',                'Rabies Vaccination 3 Yr.'),
  ('00000000-0000-0000-0000-0000000f2002', '00000000-0000-0000-0000-0000000f2101', 'administered_on_raw', '03-08-25'),
  ('00000000-0000-0000-0000-0000000f2002', '00000000-0000-0000-0000-0000000f2101', 'administered_on',     '2025-03-08'),
  ('00000000-0000-0000-0000-0000000f2002', '00000000-0000-0000-0000-0000000f2101', 'expires_on_raw',      '03-28'),
  ('00000000-0000-0000-0000-0000000f2002', '00000000-0000-0000-0000-0000000f2101', 'expires_on',          '2028-03-28'),
  -- Row 2: a diagnostic test, with a date that has no printed form at all.
  ('00000000-0000-0000-0000-0000000f2002', '00000000-0000-0000-0000-0000000f2102', 'term',                'Canine Lyme Test'),
  ('00000000-0000-0000-0000-0000000f2002', '00000000-0000-0000-0000-0000000f2102', 'administered_on',     '2025-10-15'),
  -- Row 3: nobody has ruled on it.
  ('00000000-0000-0000-0000-0000000f2002', '00000000-0000-0000-0000-0000000f2103', 'term',                'Mystery Shot'),
  -- Row 4: tracked bordetella, due month only, honestly left without an ISO expiry. Blocked.
  ('00000000-0000-0000-0000-0000000f2002', '00000000-0000-0000-0000-0000000f2104', 'term',                'Bordetella Annual Injectable'),
  ('00000000-0000-0000-0000-0000000f2002', '00000000-0000-0000-0000-0000000f2104', 'administered_on_raw', '03-08-25'),
  ('00000000-0000-0000-0000-0000000f2002', '00000000-0000-0000-0000-0000000f2104', 'administered_on',     '2025-03-08'),
  ('00000000-0000-0000-0000-0000000f2002', '00000000-0000-0000-0000-0000000f2104', 'expires_on_raw',      '03-26');

-- --- 1. One key, both sides ------------------------------------------------------
SELECT is((SELECT field_key FROM extraction_field
            WHERE extraction_id = '00000000-0000-0000-0000-0000000f2002' AND field_name = 'clinic.phone'),
  'clinic.phone', 'A document-level field keys by its dotted name');

SELECT is((SELECT field_key FROM extraction_field
            WHERE line_item_id = '00000000-0000-0000-0000-0000000f2101' AND field_name = 'expires_on'),
  'line_items[].expires_on', 'A line-item field keys without its row number');

SELECT is(printed_date_parts('03-28') || '/' || printed_date_parts('Oct 15, 2025'), '2/3',
  'A reminder month prints two date parts; a full date prints three');

SELECT results_eq($$ SELECT review_error_rate_pct(), review_min_observations() $$,
                  $$ VALUES (20, 3) $$,
  'The review thresholds read their shop_policy rows');

-- --- 2. Why each field deserves a look -----------------------------------------------
SELECT results_eq(
  $$ SELECT reasons, priority FROM v_field_review_priority
      WHERE line_item_id = '00000000-0000-0000-0000-0000000f2101' AND field_key = 'line_items[].expires_on' $$,
  $$ VALUES (ARRAY['date_more_precise_than_page', 'feeds_a_record'], 'high') $$,
  'The invented day is caught: an ISO date with more in it than its two-part print');

SELECT results_eq(
  $$ SELECT reasons, priority FROM v_field_review_priority
      WHERE line_item_id = '00000000-0000-0000-0000-0000000f2102' AND field_key = 'line_items[].administered_on' $$,
  $$ VALUES (ARRAY['date_without_printed_form'], 'high') $$,
  'A date with no printed form is high even on a row that is not a vaccine');

SELECT results_eq(
  $$ SELECT reasons FROM v_field_review_priority
      WHERE line_item_id = '00000000-0000-0000-0000-0000000f2101' AND field_key = 'line_items[].administered_on' $$,
  $$ VALUES (ARRAY['feeds_a_record']) $$,
  'A fully printed date on a tracked row is flagged only because it feeds a record');

SELECT results_eq(
  $$ SELECT reasons, priority FROM v_field_review_priority
      WHERE line_item_id = '00000000-0000-0000-0000-0000000f2104' AND field_key = 'line_items[].administered_on' $$,
  $$ VALUES ('{}'::text[], 'low') $$,
  'The same date on a tracked row that cannot become a record feeds nothing, and is low');

SELECT results_eq(
  $$ SELECT reasons FROM v_field_review_priority
      WHERE line_item_id = '00000000-0000-0000-0000-0000000f2103' AND field_key = 'line_items[].term' $$,
  $$ VALUES (ARRAY['unmapped_term']) $$,
  'A term with no ruling says so');

SELECT results_eq(
  $$ SELECT reasons, priority FROM v_field_review_priority
      WHERE extraction_id = '00000000-0000-0000-0000-0000000f2002' AND field_key = 'clinic.phone' $$,
  $$ VALUES ('{}'::text[], 'low') $$,
  'A field with no reason is low, and still listed');

-- --- 3. The report header ------------------------------------------------------------
SELECT results_eq(
  $$ SELECT line_items, tracked_rows, records_ready, records_awaiting_review, records_on_suspect_dates,
            tracked_rows_blocked, unmapped_terms, high
       FROM v_extraction_review_summary WHERE extraction_id = '00000000-0000-0000-0000-0000000f2002' $$,
  $$ VALUES (4::bigint, 2::bigint, 0::bigint, 1::bigint, 1::bigint, 1::bigint, 1::bigint, 5::bigint) $$,
  'Nothing ready before review; one record waiting, and the header says it rests on a suspect date; one tracked row blocked');

-- --- 4. Storing an evaluation, and what it refuses -------------------------------------
INSERT INTO eval_run (id, run_label, model_name, model_version, prompt_version,
                      ruler_version, contract_version, scored_at) VALUES
  ('00000000-0000-0000-0000-0000000f2201', 'run-A', 'test-model', 'test-model-1', 'p0',
   'r-1', 'v4.1', now());

INSERT INTO eval_document_result (id, eval_run_id, extraction_id, corpus_document_id,
                                  expected_items, got_items) VALUES
  ('00000000-0000-0000-0000-0000000f2301', '00000000-0000-0000-0000-0000000f2201',
   '00000000-0000-0000-0000-0000000f2002', 'doc-a', 3, 3);

INSERT INTO eval_field_result (eval_document_result_id, field_path, outcome, expected_value, got_value) VALUES
  ('00000000-0000-0000-0000-0000000f2301', 'clinic.phone',                 'wrong',    '410-522-0055', '(410) 522-0055'),
  ('00000000-0000-0000-0000-0000000f2301', 'clinic.fax',                   'correct',  NULL, NULL),
  ('00000000-0000-0000-0000-0000000f2301', 'clinic.name',                  'correct',  'Doc Side', 'Doc Side'),
  ('00000000-0000-0000-0000-0000000f2301', 'line_items[1].term',           'correct',  'Rabies Vaccination 3 Yr.', 'Rabies Vaccination 3 Yr.'),
  ('00000000-0000-0000-0000-0000000f2301', 'line_items[1].source_region',  'unscored', NULL, 'reminders'),
  ('00000000-0000-0000-0000-0000000f2301', 'clinic.website',               'spurious', NULL, 'docsidevet.com');

INSERT INTO eval_trap_result (eval_document_result_id, trap_id, field_path, wrong_value, outcome, got) VALUES
  ('00000000-0000-0000-0000-0000000f2301', 1, 'line_items[1].expires_on', '2028-03-28', 'hit',
   'line_items[1].expires_on = ''2028-03-28'''),
  ('00000000-0000-0000-0000-0000000f2301', 2, 'patient.date_of_birth', '2023-12-02', 'avoided', NULL),
  ('00000000-0000-0000-0000-0000000f2301', 3, 'vaccination_record', 'two DHPP records', 'other_layer', NULL);

SELECT results_eq(
  $$ SELECT field_key, line_item_n FROM eval_field_result WHERE field_path = 'line_items[1].term' $$,
  $$ VALUES ('line_items[].term', 1) $$,
  'The stored result derives the same field_key, and the row number, from its path');

SELECT throws_ok(
  $$ INSERT INTO eval_field_result (eval_document_result_id, field_path, outcome, expected_value, got_value)
     VALUES ('00000000-0000-0000-0000-0000000f2301', 'owner.city', 'spurious', 'Baltimore', 'Towson') $$,
  '23514', NULL, 'A spurious result where the key had a value is refused');

SELECT throws_ok(
  $$ INSERT INTO eval_field_result (eval_document_result_id, field_path, outcome, expected_value, got_value)
     VALUES ('00000000-0000-0000-0000-0000000f2301', 'owner.state', 'missed', 'MD', 'MD') $$,
  '23514', NULL, 'A missed result where the model produced a value is refused');

SELECT throws_ok(
  $$ INSERT INTO eval_field_result (eval_document_result_id, field_path, outcome, expected_value, got_value)
     VALUES ('00000000-0000-0000-0000-0000000f2301', 'owner.phone', 'wrong', '410-555-0100', '410-555-0100') $$,
  '23514', NULL, 'A wrong result where the two values agree is refused');

SELECT throws_ok(
  $$ INSERT INTO eval_trap_result (eval_document_result_id, trap_id, field_path, wrong_value, outcome)
     VALUES ('00000000-0000-0000-0000-0000000f2301', 9, 'owner.name', 'x', 'hit') $$,
  '23514', NULL, 'A trap hit must record what was produced');

SELECT throws_ok(
  $$ INSERT INTO eval_run (run_label, model_name, model_version, prompt_version, ruler_version, contract_version)
     VALUES ('run-A', 'test-model', 'test-model-1', 'p0', 'r-1', 'v4.1') $$,
  '23505', NULL, 'The same run under the same ruler is one evaluation, not two');

INSERT INTO eval_run (id, run_label, model_name, model_version, prompt_version,
                      ruler_version, contract_version) VALUES
  ('00000000-0000-0000-0000-0000000f2203', 'run-B', 'test-model', 'test-model-1', 'p-other', 'r-1', 'v4.1');

SELECT throws_ok(
  $$ INSERT INTO eval_document_result (eval_run_id, extraction_id, corpus_document_id, expected_items, got_items)
     VALUES ('00000000-0000-0000-0000-0000000f2203', '00000000-0000-0000-0000-0000000f2002', 'doc-a', 3, 3) $$,
  '23514', NULL, 'An evaluation of prompt p-other cannot claim an extraction p0 produced');

-- --- 5. Two accuracies -------------------------------------------------------------------
SELECT results_eq(
  $$ SELECT scored, correct, wrong, spurious, field_accuracy, informative, informative_accuracy,
            traps_hit, traps_scorable, traps_other_layer
       FROM v_eval_run_summary WHERE eval_run_id = '00000000-0000-0000-0000-0000000f2201' $$,
  $$ VALUES (5::bigint, 3::bigint, 1::bigint, 1::bigint, 0.6000::numeric, 4::bigint, 0.5000::numeric,
             1::bigint, 2::bigint, 1::bigint) $$,
  'Two nulls agreeing count toward field_accuracy and not toward informative_accuracy');

-- --- 6. History, within the shop's thresholds -----------------------------------------------
SELECT is((SELECT reasons FROM v_field_review_priority
            WHERE extraction_id = '00000000-0000-0000-0000-0000000f2002' AND field_key = 'clinic.phone'),
  '{}'::text[], 'One bad read in evaluation is noise below review_min_observations');

UPDATE shop_policy SET int_value = 1 WHERE key = 'review_min_observations';

SELECT results_eq(
  $$ SELECT reasons, priority FROM v_field_review_priority
      WHERE extraction_id = '00000000-0000-0000-0000-0000000f2002' AND field_key = 'clinic.phone' $$,
  $$ VALUES (ARRAY['weak_in_evaluation'], 'medium') $$,
  'Lower the threshold and the same history flags the field, at medium');

SELECT is((SELECT reason_labels FROM v_field_review_priority
            WHERE extraction_id = '00000000-0000-0000-0000-0000000f2002' AND field_key = 'clinic.phone'),
  ARRAY['In testing, this model often gets this field wrong.'],
  'The reason carries a label a groomer can read');

-- --- 7. Fail closed -------------------------------------------------------------------------
DELETE FROM review_reason WHERE code = 'weak_in_evaluation';

SELECT is((SELECT priority FROM v_field_review_priority
            WHERE extraction_id = '00000000-0000-0000-0000-0000000f2002' AND field_key = 'clinic.phone'),
  'high', 'A reason with no registered row raises the field to high rather than vanishing');

INSERT INTO review_reason (code, priority, plain_language_label, sort_order) VALUES
  ('weak_in_evaluation', 'medium', 'In testing, this model often gets this field wrong.', 5);

-- --- 6, continued: same prompt only; latest scoring only ----------------------------------------
INSERT INTO eval_document_result (id, eval_run_id, extraction_id, corpus_document_id, expected_items, got_items) VALUES
  ('00000000-0000-0000-0000-0000000f2303', '00000000-0000-0000-0000-0000000f2203',
   '00000000-0000-0000-0000-0000000f2003', 'doc-a', 3, 3);
INSERT INTO eval_field_result (eval_document_result_id, field_path, outcome, expected_value, got_value) VALUES
  ('00000000-0000-0000-0000-0000000f2303', 'clinic.email', 'wrong', 'front@clinic.example', 'info@clinic.example');

SELECT is((SELECT reasons FROM v_field_review_priority
            WHERE extraction_id = '00000000-0000-0000-0000-0000000f2002' AND field_key = 'clinic.email'),
  '{}'::text[], 'Another prompt''s weakness on a field does not flag this prompt''s');

-- run-A scored again after the key was corrected: the phone was an accepted alternate all along.
INSERT INTO eval_run (id, run_label, model_name, model_version, prompt_version,
                      ruler_version, contract_version, scored_at) VALUES
  ('00000000-0000-0000-0000-0000000f2202', 'run-A', 'test-model', 'test-model-1', 'p0',
   'r-2', 'v4.1', now() + interval '1 minute');
INSERT INTO eval_document_result (id, eval_run_id, extraction_id, corpus_document_id, expected_items, got_items) VALUES
  ('00000000-0000-0000-0000-0000000f2302', '00000000-0000-0000-0000-0000000f2202',
   '00000000-0000-0000-0000-0000000f2002', 'doc-a', 3, 3);
INSERT INTO eval_field_result (eval_document_result_id, field_path, outcome, expected_value, got_value, accepted_alternate) VALUES
  ('00000000-0000-0000-0000-0000000f2302', 'clinic.phone', 'correct', '410-522-0055', '(410) 522-0055', true);

SELECT is((SELECT reasons FROM v_field_review_priority
            WHERE extraction_id = '00000000-0000-0000-0000-0000000f2002' AND field_key = 'clinic.phone'),
  '{}'::text[], 'Re-scored under the corrected ruler, the run no longer counts against the field');

-- --- 8. Reviewers teach the report too ---------------------------------------------------------
UPDATE extraction_field SET correction_action = 'removed'
 WHERE line_item_id = '00000000-0000-0000-0000-0000000f2102' AND field_name = 'administered_on';

SELECT results_eq(
  $$ SELECT reasons FROM v_field_review_priority
      WHERE line_item_id = '00000000-0000-0000-0000-0000000f2101' AND field_key = 'line_items[].administered_on' $$,
  $$ VALUES (ARRAY['feeds_a_record', 'often_corrected']) $$,
  'A reviewer removing one invented date flags the same field on every other row');

UPDATE extraction_field SET correction_action = 'confirmed'
 WHERE line_item_id = '00000000-0000-0000-0000-0000000f2103' AND field_name = 'term';

SELECT is((SELECT count(*) FROM v_field_review_priority
            WHERE (line_item_id = '00000000-0000-0000-0000-0000000f2102' AND field_key = 'line_items[].administered_on')
               OR (line_item_id = '00000000-0000-0000-0000-0000000f2103' AND field_key = 'line_items[].term')),
  0::bigint, 'A field a reviewer has ruled on leaves the work order');

SELECT results_eq(
  $$ SELECT fields_reviewed, confirmed, edited, removed, edit_rate, removal_rate
       FROM v_model_review_outcomes WHERE prompt_version = 'p0' $$,
  $$ VALUES (2::bigint, 1::bigint, 0::bigint, 1::bigint, 0.0000::numeric, 0.5000::numeric) $$,
  'In production the reviewer is the key: one of two checked values was not on the page');

-- Partly-read values (answer_key_contract.md v4.3). Last, so nothing above
-- counts these rows.
SELECT lives_ok(
  $$ INSERT INTO eval_field_result (eval_document_result_id, field_path, outcome, expected_value, got_value)
     VALUES ('00000000-0000-0000-0000-0000000f2301', 'line_items[9].expires_on_raw', 'overconfident',
             'Jan 2?, 2027', 'Jan 29, 2027') $$,
  'A digit supplied where the key reads ? is stored as overconfident');

SELECT throws_ok(
  $$ INSERT INTO eval_field_result (eval_document_result_id, field_path, outcome, expected_value, got_value)
     VALUES ('00000000-0000-0000-0000-0000000f2301', 'line_items[10].expires_on_raw', 'overconfident',
             'Jan 20, 2027', 'Jan 29, 2027') $$,
  '23514', NULL, 'Overconfident against a fully read value is refused — that is wrong, not overconfident');

SELECT lives_ok(
  $$ INSERT INTO eval_field_result (eval_document_result_id, field_path, outcome, expected_value, got_value)
     VALUES ('00000000-0000-0000-0000-0000000f2301', 'line_items[6].expires_on_raw', 'missed',
             'Oct 2?, 2026', 'Oct ??, 2026') $$,
  'A ? where the page shows a character is a miss, not a wrong value');

SELECT * FROM finish();
ROLLBACK;
