-- =============================================================================
-- 17. Extraction evaluation, and the review report
--
-- Two questions, with different sources of truth:
--
--   HOW DID THE MODEL DO?
--     In development there is an answer key, and the harness scores a run
--     against it field by field. Those scores are stored here — eval_run and
--     its children — so a prompt change can be compared with the last one in
--     SQL, not by re-reading terminal output.
--     In production there is no answer key. There is something better: a
--     human who looked at the page and confirmed, edited or removed each
--     field. extraction_field.correction_action has recorded that since
--     section 7. v_model_review_outcomes reads it.
--
--   WHAT SHOULD A HUMAN LOOK AT MORE CLOSELY?
--     v_field_review_priority. Every unreviewed field on an extraction awaiting
--     review, with the reasons it deserves attention and a priority derived
--     from them. Every reason is a rule a groomer could read, and each one is
--     a row in review_reason — no score, no black box.
--
-- The two halves meet on field_key: 'clinic.phone', 'line_items[].expires_on'.
-- A field the model got wrong in evaluation is flagged when the same model and
-- prompt produce it in production; a field reviewers keep correcting is
-- flagged the same way. Evaluation informs review, and review becomes the next
-- evaluation.
-- =============================================================================

SET search_path = groom, public;

-- -----------------------------------------------------------------------------
-- The shared key
--
-- One derivation, generated, so the production side and the evaluation side
-- cannot drift into two spellings of the same field.
-- -----------------------------------------------------------------------------

ALTER TABLE extraction_field
    ADD COLUMN field_key text GENERATED ALWAYS AS (
        CASE WHEN line_item_id IS NULL THEN field_name
             ELSE 'line_items[].' || field_name END
    ) STORED;
CREATE INDEX extraction_field_key_idx ON extraction_field (field_key);

COMMENT ON COLUMN extraction_field.field_key IS
  'The field without its row: ''line_items[].expires_on'' for every row''s expiry. '
  'The join key between what reviewers correct and what evaluation measured.';

-- -----------------------------------------------------------------------------
-- Review thresholds are shop policy
--
-- How cautious to be is the shop's call, not the schema's, so the two numbers
-- that decide whether history makes a field suspicious are rows in
-- shop_policy — PREFERENCE tier, audited on change, loud on a missing key.
-- -----------------------------------------------------------------------------

INSERT INTO shop_policy (key, value_type, int_value, description) VALUES
  ('review_error_rate_pct', 'integer', 20,
   'A field whose error rate — in evaluation, or in reviewers'' corrections — is at or above this percentage is flagged for closer review.'),
  ('review_min_observations', 'integer', 3,
   'How many observations a field needs before its error rate is trusted. Below this, one bad read is noise, not a pattern.');

CREATE FUNCTION review_error_rate_pct() RETURNS integer
  LANGUAGE sql STABLE AS $$ SELECT shop_policy_int('review_error_rate_pct') $$;
CREATE FUNCTION review_min_observations() RETURNS integer
  LANGUAGE sql STABLE AS $$ SELECT shop_policy_int('review_min_observations') $$;

-- -----------------------------------------------------------------------------
-- Evaluation results
-- -----------------------------------------------------------------------------

-- 'overconfident': the key reads part of a value — 'Jan 2?, 2027', where ? is
-- a character printed but not readable — and the model supplied a character
-- the page does not show. A guessed digit that happens to be right looks
-- exactly like one that is wrong, so it is its own outcome, not 'correct'.
CREATE TYPE eval_field_outcome AS ENUM ('correct', 'wrong', 'missed', 'spurious', 'overconfident', 'unscored');

-- 'other_layer': a must_not_produce entry about Layer 2 or 3 — two DHPP
-- records from one injection — which is the database's score, not the
-- model's. Recorded so it is not lost; never counted against the model.
CREATE TYPE eval_trap_outcome AS ENUM ('avoided', 'hit', 'not_scorable', 'other_layer');

-- One scoring of one run under one ruler. The same run scored again after a
-- key is corrected is a NEW evaluation, and the pair is the record of what the
-- correction changed. The same run scored again under the same ruler is a
-- duplicate, and the UNIQUE refuses it.
CREATE TABLE eval_run (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_label        text NOT NULL,          -- the runs/ directory: '2026-09-22T193210Z'
    model_name       text NOT NULL,          -- requested
    model_version    text NOT NULL,          -- what answered
    prompt_version   text NOT NULL,
    -- Hash of every key's compared blocks plus the PII map. Anything that can
    -- change a score for the same model output changes this.
    ruler_version    text NOT NULL,
    contract_version text NOT NULL,
    pii_map_entries  integer NOT NULL DEFAULT 0 CHECK (pii_map_entries >= 0),
    scored_at        timestamptz NOT NULL DEFAULT now(),
    notes            text,
    UNIQUE (run_label, ruler_version)
);
CREATE INDEX eval_run_prompt_idx ON eval_run (model_name, prompt_version, scored_at DESC);

CREATE TABLE eval_document_result (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    eval_run_id        uuid NOT NULL REFERENCES eval_run(id) ON DELETE CASCADE,
    -- An evaluation of an extraction that no longer exists measures nothing.
    extraction_id      uuid NOT NULL REFERENCES extraction(id) ON DELETE CASCADE,
    corpus_document_id text NOT NULL,        -- the key's id: 'docside_invoice_2025-04-04'
    expected_items     integer NOT NULL CHECK (expected_items >= 0),
    got_items          integer NOT NULL CHECK (got_items >= 0),
    parse_error        text,
    UNIQUE (eval_run_id, corpus_document_id)
);

-- Values are stored AFTER the PII map: what was compared, which is what the
-- key holds. The real values are already in extraction_field, where they
-- belong; copying them here would put names in a second table for no reason.
CREATE TABLE eval_field_result (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    eval_document_result_id uuid NOT NULL REFERENCES eval_document_result(id) ON DELETE CASCADE,
    field_path              text NOT NULL,   -- 'line_items[8].expires_on'
    field_key               text GENERATED ALWAYS AS (
                                regexp_replace(field_path, '^line_items\[\d+\]', 'line_items[]')
                            ) STORED,
    line_item_n             integer GENERATED ALWAYS AS (
                                (substring(field_path FROM '^line_items\[(\d+)\]'))::integer
                            ) STORED,
    outcome                 eval_field_outcome NOT NULL,
    expected_value          text,
    got_value               text,
    pii_mapped              boolean NOT NULL DEFAULT false,
    accepted_alternate      boolean NOT NULL DEFAULT false,
    UNIQUE (eval_document_result_id, field_path),

    -- The scorer's vocabulary, restated as a constraint, so a result that
    -- contradicts its own definition cannot be stored — however it was made.
    CONSTRAINT outcome_coherent CHECK (
        (outcome = 'spurious' AND expected_value IS NULL     AND got_value IS NOT NULL)
     -- missed also covers a model more cautious than the page: '?' where the
     -- key reads a character ('Jan ??, 2027' against 'Jan 2?, 2027').
     OR (outcome = 'missed'   AND expected_value IS NOT NULL
                              AND (got_value IS NULL
                                   OR (position('?' IN got_value) > 0 AND got_value <> expected_value)))
     OR (outcome = 'wrong'    AND expected_value IS NOT NULL AND got_value IS NOT NULL
                              AND expected_value <> got_value AND NOT accepted_alternate)
     OR (outcome = 'correct'  AND NOT accepted_alternate
                              AND expected_value IS NOT DISTINCT FROM got_value)
     OR (outcome = 'correct'  AND accepted_alternate
                              AND expected_value IS NOT NULL AND got_value IS NOT NULL
                              AND expected_value <> got_value)
     OR (outcome = 'overconfident' AND got_value IS NOT NULL AND NOT accepted_alternate
                              AND (expected_value IS NULL      -- an ISO date beside a partly-read print
                                   OR (position('?' IN expected_value) > 0 AND expected_value <> got_value)))
     OR (outcome = 'unscored' AND NOT accepted_alternate)
    )
);
CREATE INDEX eval_field_result_key_idx ON eval_field_result (field_key, outcome);

CREATE TABLE eval_trap_result (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    eval_document_result_id uuid NOT NULL REFERENCES eval_document_result(id) ON DELETE CASCADE,
    trap_id                 integer NOT NULL,
    field_path              text NOT NULL,
    wrong_value             text,
    outcome                 eval_trap_outcome NOT NULL,
    got                     text,
    note                    text,
    UNIQUE (eval_document_result_id, trap_id),
    CONSTRAINT hit_records_what_was_produced CHECK ((outcome = 'hit') = (got IS NOT NULL))
);

COMMENT ON TABLE eval_trap_result IS
  'One row per must_not_produce entry per document per evaluation. The hit rate '
  'is the number that matters most in this project: each trap is a specific '
  'confident inference a careful reader could make, and a hit is the model '
  'making it.';

-- An evaluation cannot claim to score an extraction some other model or prompt
-- produced. Structural, not a shop rule, so it raises check_violation rather
-- than taking a GR code and a row in policy_enforcement: there is no version
-- of this a shop would want to relax.
CREATE FUNCTION enforce_eval_matches_extraction() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    r eval_run;
    x extraction;
BEGIN
    SELECT * INTO r FROM eval_run   WHERE id = NEW.eval_run_id;
    IF NOT FOUND THEN RETURN NEW; END IF;   -- the FK reports it
    SELECT * INTO x FROM extraction WHERE id = NEW.extraction_id;
    IF NOT FOUND THEN RETURN NEW; END IF;
    IF x.model_name IS DISTINCT FROM r.model_name
       OR x.prompt_version IS DISTINCT FROM r.prompt_version THEN
        RAISE EXCEPTION
            'evaluation scores % / %, but that extraction was produced by % / %',
            r.model_name, r.prompt_version, x.model_name, x.prompt_version
            USING ERRCODE = 'check_violation',
                  HINT = 'Score each run against the extractions it produced.';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER eval_document_result_matches_extraction
    BEFORE INSERT OR UPDATE ON eval_document_result
    FOR EACH ROW EXECUTE FUNCTION enforce_eval_matches_extraction();

-- -----------------------------------------------------------------------------
-- Why a field deserves a closer look
--
-- A lookup table, not an enum, for the same reason compliance_state_meta is
-- one: the dashboard reads attributes of each value (its label, its priority,
-- its order). A shop that wants every field feeding a record reviewed at
-- medium rather than high changes a row.
-- -----------------------------------------------------------------------------

CREATE TABLE review_reason (
    code                 text PRIMARY KEY,
    priority             text NOT NULL CHECK (priority IN ('high', 'medium')),
    plain_language_label text NOT NULL,
    sort_order           integer NOT NULL UNIQUE
);

INSERT INTO review_reason (code, priority, plain_language_label, sort_order) VALUES
  ('date_more_precise_than_page', 'high',
   'This date has more in it than the page prints — a day or a year that may have been filled in.', 1),
  ('date_without_printed_form',   'high',
   'This date has no printed form beside it. Check it against the page.', 2),
  ('feeds_a_record',              'high',
   'This will become part of a vaccination record once confirmed.', 3),
  ('unmapped_term',               'high',
   'Nobody has ruled on this term yet.', 4),
  ('weak_in_evaluation',          'medium',
   'In testing, this model often gets this field wrong.', 5),
  ('often_corrected',             'medium',
   'Reviewers often correct this field.', 6);

-- How many date parts a printed date actually carries: digit groups plus month
-- names. '03-28' carries two; '04-04-25' and 'Oct 15, 2025' carry three. An ISO
-- date built from a two-part print has a part the page never stated.
--
-- This is the Jaddi invoice's trap turned into a detector. The model that
-- supplies the 28th to '03-28' emits expires_on_raw = '03-28' honestly and
-- expires_on = '2028-03-28' dishonestly, and nothing else in the schema can
-- tell the two apart.
CREATE FUNCTION printed_date_parts(p_raw text) RETURNS integer
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT (SELECT count(*) FROM regexp_matches(p_raw, '\d+', 'g'))::integer
         + (SELECT count(*) FROM regexp_matches(lower(p_raw),
                '\m(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\M', 'g'))::integer
$$;

-- -----------------------------------------------------------------------------
-- The report
-- -----------------------------------------------------------------------------

-- HOW DID THE MODEL DO, IN EVALUATION. One row per scoring.
--
-- Two accuracies, because one of them flatters. `field_accuracy` counts every
-- slot, and most slots are null on both sides — a model that emits nothing at
-- all scores well on a sparse page. `informative_accuracy` counts only the
-- slots where the page or the model had something to say.
CREATE VIEW v_eval_run_summary AS
WITH d AS (
    SELECT eval_run_id,
           count(*)                                        AS documents,
           sum(expected_items)                             AS expected_items,
           sum(got_items)                                  AS got_items,
           count(*) FILTER (WHERE parse_error IS NOT NULL) AS parse_errors
    FROM eval_document_result
    GROUP BY eval_run_id
),
f AS (
    SELECT d.eval_run_id,
           count(*) FILTER (WHERE f.outcome <> 'unscored')  AS scored,
           count(*) FILTER (WHERE f.outcome =  'correct')   AS correct,
           count(*) FILTER (WHERE f.outcome =  'wrong')     AS wrong,
           count(*) FILTER (WHERE f.outcome =  'missed')    AS missed,
           count(*) FILTER (WHERE f.outcome =  'spurious')  AS spurious,
           count(*) FILTER (WHERE f.outcome =  'overconfident') AS overconfident,
           count(*) FILTER (WHERE f.outcome <> 'unscored'
                              AND (f.expected_value IS NOT NULL OR f.got_value IS NOT NULL)) AS informative,
           count(*) FILTER (WHERE f.outcome = 'correct'
                              AND (f.expected_value IS NOT NULL OR f.got_value IS NOT NULL)) AS informative_correct,
           count(*) FILTER (WHERE f.pii_mapped)             AS pii_mapped,
           count(*) FILTER (WHERE f.accepted_alternate)     AS accepted_alternates
    FROM eval_field_result f
    JOIN eval_document_result d ON d.id = f.eval_document_result_id
    GROUP BY d.eval_run_id
),
t AS (
    SELECT d.eval_run_id,
           count(*) FILTER (WHERE t.outcome = 'hit')                 AS traps_hit,
           count(*) FILTER (WHERE t.outcome IN ('hit', 'avoided'))   AS traps_scorable,
           count(*) FILTER (WHERE t.outcome = 'other_layer')         AS traps_other_layer
    FROM eval_trap_result t
    JOIN eval_document_result d ON d.id = t.eval_document_result_id
    GROUP BY d.eval_run_id
)
SELECT r.id AS eval_run_id,
       r.run_label, r.model_name, r.model_version, r.prompt_version,
       r.ruler_version, r.contract_version, r.scored_at,
       d.documents, d.expected_items, d.got_items, d.parse_errors,
       f.scored, f.correct, f.wrong, f.missed, f.spurious,
       round(f.correct::numeric / NULLIF(f.scored, 0), 4)                        AS field_accuracy,
       f.informative,
       round(f.informative_correct::numeric / NULLIF(f.informative, 0), 4)       AS informative_accuracy,
       coalesce(t.traps_hit, 0)         AS traps_hit,
       coalesce(t.traps_scorable, 0)    AS traps_scorable,
       coalesce(t.traps_other_layer, 0) AS traps_other_layer,
       f.pii_mapped, f.accepted_alternates,
       f.overconfident
FROM eval_run r
LEFT JOIN d ON d.eval_run_id = r.id
LEFT JOIN f ON f.eval_run_id = r.id
LEFT JOIN t ON t.eval_run_id = r.id;

COMMENT ON VIEW v_eval_run_summary IS
  'One row per scoring. Compare two prompt_versions here, not in a terminal.';

-- WHERE IS THE MODEL WEAK, IN EVALUATION. One row per model × prompt × field.
--
-- Only the most recent scoring of each run counts. A run scored twice — once
-- under a key with a labelling error, once after the fix — is one set of
-- observations, and the corrected ruler is the one that describes the model.
CREATE VIEW v_eval_field_reliability AS
WITH latest AS (
    SELECT DISTINCT ON (run_label) id, model_name, prompt_version
    FROM eval_run
    ORDER BY run_label, scored_at DESC, id
)
SELECT l.model_name,
       l.prompt_version,
       f.field_key,
       count(*) FILTER (WHERE f.expected_value IS NOT NULL OR f.got_value IS NOT NULL) AS observations,
       count(*) FILTER (WHERE f.outcome IN ('wrong', 'missed', 'spurious', 'overconfident')) AS errors,
       count(*) FILTER (WHERE f.outcome = 'spurious')                                  AS spurious,
       round(count(*) FILTER (WHERE f.outcome IN ('wrong', 'missed', 'spurious', 'overconfident'))::numeric
             / NULLIF(count(*) FILTER (WHERE f.expected_value IS NOT NULL OR f.got_value IS NOT NULL), 0),
             3) AS error_rate,
       count(*) FILTER (WHERE f.outcome = 'overconfident')                             AS overconfident
FROM latest l
JOIN eval_document_result d ON d.eval_run_id = l.id
JOIN eval_field_result    f ON f.eval_document_result_id = d.id
WHERE f.outcome <> 'unscored'
GROUP BY l.model_name, l.prompt_version, f.field_key;

COMMENT ON VIEW v_eval_field_reliability IS
  'error_rate is over observations where the page or the model had a value. '
  'Two nulls agreeing is not evidence the model can read that field.';

-- WHERE IS THE MODEL WEAK, IN PRODUCTION. The same shape, from reviewers.
CREATE VIEW v_field_correction_rate AS
SELECT e.model_name,
       e.prompt_version,
       ef.field_key,
       count(*) FILTER (WHERE ef.correction_action <> 'unreviewed'
                          AND (ef.extracted_value IS NOT NULL OR ef.corrected_value IS NOT NULL)) AS reviewed,
       count(*) FILTER (WHERE ef.correction_action IN ('edited', 'removed'))                      AS corrected,
       round(count(*) FILTER (WHERE ef.correction_action IN ('edited', 'removed'))::numeric
             / NULLIF(count(*) FILTER (WHERE ef.correction_action <> 'unreviewed'
                          AND (ef.extracted_value IS NOT NULL OR ef.corrected_value IS NOT NULL)), 0),
             3) AS correction_rate
FROM extraction_field ef
JOIN extraction e ON e.id = ef.extraction_id
GROUP BY e.model_name, e.prompt_version, ef.field_key;

-- HOW DID THE MODEL DO, IN PRODUCTION. No answer key; the reviewer is the key.
--
-- removal_rate is the production hallucination rate: of the values the model
-- produced that a human checked, the share that were not on the page. It is
-- the number section 7's 'removed' state exists to keep honest.
CREATE VIEW v_model_review_outcomes AS
SELECT e.model_name,
       e.model_version,
       e.prompt_version,
       count(DISTINCT e.id)                                                      AS extractions,
       count(*) FILTER (WHERE ef.correction_action <> 'unreviewed')              AS fields_reviewed,
       count(*) FILTER (WHERE ef.correction_action = 'confirmed')                AS confirmed,
       count(*) FILTER (WHERE ef.correction_action = 'edited')                   AS edited,
       count(*) FILTER (WHERE ef.correction_action = 'removed')                  AS removed,
       round(count(*) FILTER (WHERE ef.correction_action = 'edited')::numeric
             / NULLIF(count(*) FILTER (WHERE ef.correction_action <> 'unreviewed'), 0), 4) AS edit_rate,
       round(count(*) FILTER (WHERE ef.correction_action = 'removed')::numeric
             / NULLIF(count(*) FILTER (WHERE ef.correction_action <> 'unreviewed'
                                        AND ef.extracted_value IS NOT NULL), 0), 4)          AS removal_rate
FROM extraction e
JOIN extraction_field ef ON ef.extraction_id = e.id
GROUP BY e.model_name, e.model_version, e.prompt_version;

-- WHAT SHOULD A HUMAN LOOK AT MORE CLOSELY. One row per unreviewed field on an
-- extraction awaiting review.
--
-- A field leaves this view the moment a reviewer rules on it. An unregistered
-- reason code — a review_reason row deleted — raises the field to high rather
-- than dropping the reason: fail closed, like enforcement_level().
CREATE VIEW v_field_review_priority AS
WITH f AS (
    SELECT ef.id               AS extraction_field_id,
           ef.extraction_id,
           e.document_id,
           ef.line_item_id,
           li.n,
           ef.field_key,
           ef.field_name,
           ef.extracted_value  AS value,
           e.model_name,
           e.prompt_version,
           li.disposition,
           li.record_candidate,
           CASE ef.field_name
             WHEN 'administered_on' THEN li.administered_on_raw
             WHEN 'expires_on'      THEN li.expires_on_raw
           END                 AS printed_date
    FROM extraction_field ef
    JOIN extraction e ON e.id = ef.extraction_id
    LEFT JOIN v_extraction_line_item li ON li.line_item_id = ef.line_item_id
    WHERE ef.correction_action = 'unreviewed'
      AND e.status = 'needs_review'
),
flagged AS (
    SELECT f.*,
           er.error_rate       AS eval_error_rate,
           er.observations     AS eval_observations,
           cr.correction_rate,
           cr.reviewed         AS correction_observations,
           array_remove(ARRAY[
             CASE WHEN f.field_name IN ('administered_on', 'expires_on')
                   AND f.value IS NOT NULL AND f.printed_date IS NOT NULL
                   AND printed_date_parts(f.printed_date) < 3
                  THEN 'date_more_precise_than_page' END,
             CASE WHEN f.field_name IN ('administered_on', 'expires_on')
                   AND f.value IS NOT NULL AND f.printed_date IS NULL
                  THEN 'date_without_printed_form' END,
             -- Only a value that will land in a vaccination_record column, on a
             -- row that will become one. A tracked row missing a date cannot
             -- become a record, so nothing on it feeds one; that row is counted
             -- in the summary as blocked, which is a document-level action
             -- (request a certificate), not a field to check.
             CASE WHEN f.record_candidate AND f.value IS NOT NULL
                   AND is_record_field(f.field_name)
                  THEN 'feeds_a_record' END,
             CASE WHEN f.field_name = 'term' AND f.disposition = 'unmapped'
                  THEN 'unmapped_term' END,
             CASE WHEN er.observations >= review_min_observations()
                   AND er.error_rate * 100 >= review_error_rate_pct()
                  THEN 'weak_in_evaluation' END,
             CASE WHEN cr.reviewed >= review_min_observations()
                   AND cr.correction_rate * 100 >= review_error_rate_pct()
                  THEN 'often_corrected' END
           ], NULL) AS reasons
    FROM f
    LEFT JOIN v_eval_field_reliability er
           ON er.model_name = f.model_name AND er.prompt_version = f.prompt_version
          AND er.field_key  = f.field_key
    LEFT JOIN v_field_correction_rate cr
           ON cr.model_name = f.model_name AND cr.prompt_version = f.prompt_version
          AND cr.field_key  = f.field_key
)
SELECT fl.extraction_field_id,
       fl.extraction_id,
       fl.document_id,
       fl.line_item_id,
       fl.n,
       fl.field_key,
       fl.value,
       fl.printed_date,
       fl.disposition,
       fl.record_candidate AS row_record_candidate,
       fl.reasons,
       p.priority,
       CASE p.priority WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END AS priority_rank,
       p.labels            AS reason_labels,
       fl.eval_error_rate, fl.eval_observations,
       fl.correction_rate, fl.correction_observations
FROM flagged fl
CROSS JOIN LATERAL (
    SELECT CASE
             WHEN count(rr.code) < cardinality(fl.reasons)  THEN 'high'   -- unregistered: fail closed
             WHEN bool_or(rr.priority = 'high')             THEN 'high'
             WHEN count(rr.code) > 0                        THEN 'medium'
             ELSE                                                'low'
           END AS priority,
           array_agg(rr.plain_language_label ORDER BY rr.sort_order)
             FILTER (WHERE rr.code IS NOT NULL) AS labels
    FROM review_reason rr
    WHERE rr.code = ANY (fl.reasons)
) p
ORDER BY fl.extraction_id, priority_rank, fl.n NULLS FIRST, fl.field_key;

COMMENT ON VIEW v_field_review_priority IS
  'The review screen''s work order. Every reason is a rule in review_reason; '
  'the thresholds for the two history-based reasons are shop_policy rows.';

-- The header of the review report: one row per extraction awaiting review.
--
-- tracked_rows_blocked is the Jaddi case counted: a tracked vaccine named on
-- the page that cannot become a record, because a date the page does not state
-- is missing. That number is the prompt to request a proper certificate.
--
-- records_ready counts rows a human has finished: both dates present and every
-- field the record carries reviewed. records_awaiting_review counts the rest of
-- the candidates — both dates present, not yet looked at. An invented day is
-- present, so a candidate is not a record until someone confirms it.
--
-- records_on_suspect_dates is the subset of those candidates whose dates the
-- priority view distrusts, so the reviewer knows which to open first. A
-- reviewer confirming the date clears it.
CREATE VIEW v_extraction_review_summary AS
SELECT e.id                                                          AS extraction_id,
       e.document_id,
       d.object_key,
       d.doc_class,
       e.model_name,
       e.prompt_version,
       e.extracted_at,
       (SELECT count(*) FROM v_field_review_priority p
         WHERE p.extraction_id = e.id)                               AS fields_to_review,
       (SELECT count(*) FROM v_field_review_priority p
         WHERE p.extraction_id = e.id AND p.priority = 'high')       AS high,
       (SELECT count(*) FROM v_field_review_priority p
         WHERE p.extraction_id = e.id AND p.priority = 'medium')     AS medium,
       li.line_items,
       li.tracked_rows,
       li.records_ready,
       (SELECT count(DISTINCT p.line_item_id) FROM v_field_review_priority p
         WHERE p.extraction_id = e.id AND p.row_record_candidate
           AND p.reasons && ARRAY['date_more_precise_than_page',
                                  'date_without_printed_form'])      AS records_on_suspect_dates,
       li.candidates - li.records_ready                              AS records_awaiting_review,
       li.tracked_rows - li.candidates                               AS tracked_rows_blocked,
       li.unmapped_terms
FROM extraction e
JOIN document d ON d.id = e.document_id
CROSS JOIN LATERAL (
    SELECT count(*)                                              AS line_items,
           count(*) FILTER (WHERE v.disposition = 'tracked')     AS tracked_rows,
           count(*) FILTER (WHERE v.record_candidate)            AS candidates,
           count(*) FILTER (WHERE v.can_create_record)           AS records_ready,
           count(*) FILTER (WHERE v.disposition = 'unmapped')    AS unmapped_terms
    FROM v_extraction_line_item v
    WHERE v.extraction_id = e.id
) li
WHERE e.status = 'needs_review';

ALTER FUNCTION review_error_rate_pct()               SET search_path = groom, public;
ALTER FUNCTION review_min_observations()             SET search_path = groom, public;
ALTER FUNCTION enforce_eval_matches_extraction()     SET search_path = groom, public;
ALTER FUNCTION printed_date_parts(text)              SET search_path = groom, public;
