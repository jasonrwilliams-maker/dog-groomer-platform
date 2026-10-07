-- AI suggestions at the counter: a reading of a counter copy is stored like a
-- corpus run, turned into one suggestion per tracked vaccine, and graded by
-- what the person at the counter saves.
--
-- Seven things are proven:
--   1. A reading is stored as an extraction marked read_at_counter, with its
--      line items and fields, and only for a copy taken at the counter.
--   2. The suggestion for a vaccine is the line with the latest expiry, as
--      real dates; a date with less than a full date printed is doubtful.
--   3. An unfamiliar name is listed, and once someone rules on it, the line
--      becomes a suggestion.
--   4. Saving the dates the model read confirms them; saving different dates
--      marks them edited, with what was saved.
--   5. "Not on their paperwork" marks what the model read as made up.
--   6. A shot the model missed is added as a miss, counted with the rest.
--   7. The scoreboard counts each outcome, by kind of copy; a counter reading
--      is not offered for confirming in the records tool.

BEGIN;
SET search_path = groom, public;
SELECT plan(16);

CREATE TEMP TABLE t_dog AS
SELECT add_dog('00000000-0000-0000-0000-00000000a002', 'Mochi', NULL, 'curly', 'female', NULL,
               '00000000-0000-0000-0000-00000000b002') AS id;
CREATE TEMP TABLE t_doc AS
SELECT receive_paperwork((SELECT id FROM t_dog), 'private/counter/mochi.pdf', 'application/pdf', 50000,
                         repeat('f', 64), ARRAY['private/counter/mochi-p1.jpg'], false,
                         '00000000-0000-0000-0000-00000000b002') AS id;

-- --- 1. Storing a reading -------------------------------------------------------------------------
CREATE TEMP TABLE t_read AS
SELECT record_counter_reading((SELECT id FROM t_doc), '00000000-0000-0000-0000-00000000b002',
  'claude-test', 'claude-test-1', 'p2-test', '{"text": "{}"}',
  '{"clinic.name": "Harbor Vet"}',
  $j$[
    {"n": 1, "source_region": null, "fields": {"term": "Rabies Vaccine 3 Year", "administered_on_raw": "09/30/2023",
      "administered_on": "2023-09-30", "expires_on_raw": "09/30/2026", "expires_on": "2026-09-30"}},
    {"n": 2, "source_region": null, "fields": {"term": "Rabies Vaccine 3 Year", "administered_on_raw": "09/30/2026",
      "administered_on": "2026-09-30", "expires_on_raw": "Sep 2029", "expires_on": "2029-09-30"}},
    {"n": 3, "source_region": null, "fields": {"term": "DHPP 3YR", "administered_on_raw": "01/05/2026",
      "administered_on": "2026-01-05", "expires_on_raw": "01/05/2029", "expires_on": "2029-01-05"}},
    {"n": 4, "source_region": null, "fields": {"term": "Kennel Cough (Intranasal)", "administered_on_raw": "02/01/2026",
      "administered_on": "2026-02-01", "expires_on_raw": "02/01/2027", "expires_on": "2027-02-01"}}
  ]$j$) AS id;

SELECT results_eq(
  $$ SELECT read_at_counter, status::text, requested_by FROM extraction WHERE id = (SELECT id FROM t_read) $$,
  $$ VALUES (true, 'needs_review'::text, '00000000-0000-0000-0000-00000000b002'::uuid) $$,
  'A reading at the counter is an extraction marked as read there, by whom');

SELECT is((SELECT count(*) FROM extraction_line_item WHERE extraction_id = (SELECT id FROM t_read)), 4::bigint,
  'Every line the model read is kept');

SELECT throws_ok(
  $$ SELECT record_counter_reading(gen_random_uuid(), '00000000-0000-0000-0000-00000000b002',
       'm', 'm', 'p', '{}', '{}', '[]') $$,
  '23503', NULL, 'Only a copy taken at the counter is read this way');

-- --- 2. The suggestion ------------------------------------------------------------------------------
SELECT results_eq(
  $$ SELECT vaccine_code, administered_on, expires_on, given_doubtful, expires_doubtful
       FROM v_counter_ai_suggestion WHERE extraction_id = (SELECT id FROM t_read) ORDER BY 1 $$,
  $$ VALUES ('dhpp'::text, '2026-01-05'::date, '2029-01-05'::date, false, false),
            ('rabies'::text, '2026-09-30'::date, '2029-09-30'::date, false, true) $$,
  'One suggestion per tracked vaccine, from its latest expiry; a full date the page only prints as a month is doubtful');

-- --- 3. An unfamiliar name ---------------------------------------------------------------------------
SELECT is(
  (SELECT term FROM v_counter_ai_unfamiliar WHERE extraction_id = (SELECT id FROM t_read)),
  'Kennel Cough (Intranasal)', 'A name nobody has ruled on is listed for the person to say what it is');

SELECT rule_on_term('Kennel Cough (Intranasal)', 'bordetella', '00000000-0000-0000-0000-00000000b002');

SELECT is(
  (SELECT expires_on FROM v_counter_ai_suggestion WHERE extraction_id = (SELECT id FROM t_read) AND vaccine_code = 'bordetella'),
  '2027-02-01'::date, 'Once ruled on, its line becomes a suggestion');

SELECT is(
  (SELECT actor_label FROM audit_log WHERE entity_type = 'document_term' AND changed_fields ->> 'term' = 'Kennel Cough (Intranasal)'),
  'Tanya', 'The ruling joins the vocabulary, audited with who made it');

-- --- 4. Saved as read, and saved changed ----------------------------------------------------------------
SELECT grade_counter_suggestion((SELECT id FROM t_read),
  (SELECT line_item_id FROM v_counter_ai_suggestion WHERE extraction_id = (SELECT id FROM t_read) AND vaccine_code = 'dhpp'),
  'dhpp', '2026-01-05', '2029-01-05', 'saved');

SELECT results_eq(
  $$ SELECT field_name, correction_action::text FROM extraction_field ef JOIN extraction_line_item li ON li.id = ef.line_item_id
      WHERE li.extraction_id = (SELECT id FROM t_read) AND li.n = 3
        AND field_name IN ('term', 'administered_on', 'expires_on') ORDER BY 1 $$,
  $$ VALUES ('administered_on'::text, 'confirmed'::text), ('expires_on', 'confirmed'), ('term', 'confirmed') $$,
  'Saving the dates the model read confirms them');

CREATE TEMP TABLE t_rabies_line AS
SELECT line_item_id AS id FROM v_counter_ai_suggestion WHERE extraction_id = (SELECT id FROM t_read) AND vaccine_code = 'rabies';
SELECT grade_counter_suggestion((SELECT id FROM t_read), (SELECT id FROM t_rabies_line), 'rabies',
  '2026-09-30', '2029-09-29', 'saved');

SELECT results_eq(
  $$ SELECT correction_action::text, corrected_value FROM extraction_field
      WHERE line_item_id = (SELECT id FROM t_rabies_line) AND field_name = 'expires_on' $$,
  $$ VALUES ('edited'::text, '2029-09-29'::text) $$,
  'Saving a different date marks the model''s reading edited, with what was saved');

SELECT grade_counter_suggestion((SELECT id FROM t_read), (SELECT id FROM t_rabies_line), 'rabies',
  '2020-01-01', '2021-01-01', 'saved');
SELECT is(
  (SELECT corrected_value FROM extraction_field WHERE line_item_id = (SELECT id FROM t_rabies_line) AND field_name = 'expires_on'),
  '2029-09-29', 'The first verdict stands');

-- --- 5. Not on their paperwork ---------------------------------------------------------------------------
SELECT grade_counter_suggestion((SELECT id FROM t_read),
  (SELECT line_item_id FROM v_counter_ai_suggestion WHERE extraction_id = (SELECT id FROM t_read) AND vaccine_code = 'bordetella'),
  'bordetella', NULL, NULL, 'not_on_paper');

SELECT is(
  (SELECT count(*) FROM extraction_field ef JOIN extraction_line_item li ON li.id = ef.line_item_id
    WHERE li.extraction_id = (SELECT id FROM t_read) AND li.n = 4 AND ef.correction_action = 'removed'),
  3::bigint, '"Not on their paperwork" marks the name and both dates the model read as made up');

-- --- 6. A miss -------------------------------------------------------------------------------------------
CREATE TEMP TABLE t_read2 AS
SELECT record_counter_reading((SELECT id FROM t_doc), '00000000-0000-0000-0000-00000000b001',
  'claude-test', 'claude-test-1', 'p2-test', '{"text": "{}"}', '{}', '[]') AS id;
SELECT grade_counter_suggestion((SELECT id FROM t_read2), NULL, 'rabies', '2026-09-30', '2029-09-30', 'saved');

SELECT results_eq(
  $$ SELECT ef.field_name, ef.extracted_value, ef.corrected_value, ef.correction_action::text
       FROM extraction_field ef WHERE ef.extraction_id = (SELECT id FROM t_read2) ORDER BY 1 $$,
  $$ VALUES ('administered_on'::text, NULL::text, '2026-09-30'::text, 'edited'::text),
            ('expires_on', NULL, '2029-09-30', 'edited'),
            ('term', NULL, 'Rabies', 'edited') $$,
  'A shot the model missed is added, as fields it left empty');

SELECT grade_counter_suggestion((SELECT id FROM t_read2), NULL, 'dhpp', NULL, NULL, 'not_on_paper');
SELECT is((SELECT count(*) FROM extraction_line_item WHERE extraction_id = (SELECT id FROM t_read2)), 1::bigint,
  'Saying nothing about a shot that is not there is not a miss');

SELECT throws_ok(
  $$ SELECT grade_counter_suggestion((SELECT id FROM t_read2), (SELECT id FROM t_rabies_line), 'rabies',
                                     '2026-09-30', '2029-09-30', 'saved') $$,
  '23503', NULL, 'A line is graded only against the reading it came from');

-- --- 7. The scoreboard ------------------------------------------------------------------------------------
SELECT results_eq(
  $$ SELECT copy_kind, readings, right_first_time, read_wrong, missed, made_up FROM v_counter_ai_accuracy $$,
  $$ VALUES ('pdf'::text, 2::bigint, 3::bigint, 1::bigint, 2::bigint, 2::bigint) $$,
  'The scoreboard counts dates right, read wrong, missed and made up, for PDFs');

SELECT ok(
  (SELECT ai_read FROM v_paperwork_waiting WHERE document_id = (SELECT id FROM t_doc)),
  'The manager''s waiting list shows the AI has read the copy');

SELECT * FROM finish();
ROLLBACK;
