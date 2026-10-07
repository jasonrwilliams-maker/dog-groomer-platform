-- =============================================================================
-- 27. AI suggestions at the counter, graded by the person who checks them
--
-- Until now the model only read the labelled corpus, through the harness, and
-- its readings were confirmed in the records tool. The counter's copies never
-- reached it. This section brings it to the copy being checked:
--
--   1. On the check screen, "Have the AI read it" sends the copy to the model.
--      record_counter_reading() stores what it read exactly as the harness
--      stores a corpus run (extraction, extraction_line_item, extraction_field),
--      marked read_at_counter.
--   2. v_counter_ai_suggestion picks, for each vaccine the shop tracks, the
--      line the form should be filled in from: the latest expiry the model read
--      for it. It says when a date deserves a closer look: the page prints less
--      than a full date, or the model gave a date with nothing printed behind it.
--      A vaccine name the shop has never seen (a new clinic's "Rabies (3 yr)")
--      resolves to nothing, so v_counter_ai_unfamiliar lists it with its dates,
--      and the person says which vaccine it is (rule_on_term()). That ruling
--      joins the vocabulary (section 15) for every page after it: the word list
--      grows from the counter too.
--   3. The person still types (or keeps) the dates and saves. That is still a
--      shot checked by hand (section 26), under their name. Nothing the model
--      says becomes a record by itself.
--   4. Saving grades the suggestion: grade_counter_suggestion() marks each
--      date the model read as confirmed, edited (it read it wrong) or removed
--      (the owner's paperwork has no such shot), and adds what it missed. This
--      is the same per-field review the records tool's Confirm screen writes,
--      so v_model_review_outcomes counts the counter with everything else.
--
-- Every checked copy is a graded example, so the measure of the model on real
-- paperwork grows from ordinary work instead of from labelling sessions.
-- v_counter_ai_accuracy is that measure, split between photos and PDFs,
-- because the corpus says those are two very different jobs.
--
-- A reading at the counter is not confirmed in the records tool: the person
-- at the counter already confirmed it, line by line, by saving.
-- =============================================================================

SET search_path = groom, public;

ALTER TABLE extraction
    ADD COLUMN read_at_counter boolean NOT NULL DEFAULT false,
    ADD COLUMN requested_by    uuid REFERENCES groomer(id) ON DELETE RESTRICT;
COMMENT ON COLUMN extraction.read_at_counter IS
  'Read from a copy taken at the counter, on request, and graded there by the '
  'person who checked it. Not offered on the records tool''s Confirm screen.';

-- -----------------------------------------------------------------------------
-- Storing a reading
--
-- The caller flattens the model's JSON with the harness's own field lists
-- (extraction/harness/harness/keys.py), so the counter and the corpus cannot
-- disagree about what a field is called. p_doc_fields is {"clinic.name": ...};
-- p_line_items is [{"n": 1, "source_region": ..., "fields": {"term": ...}}].
-- An answer that did not parse is kept, with no fields, as 'rejected'.
-- -----------------------------------------------------------------------------

CREATE FUNCTION record_counter_reading(p_document_id uuid, p_requested_by uuid,
                                       p_model_name text, p_model_version text, p_prompt_version text,
                                       p_raw_response jsonb, p_doc_fields jsonb, p_line_items jsonb)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_id   uuid;
    v_li   jsonb;
    v_liid uuid;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM counter_paperwork cp WHERE cp.document_id = p_document_id) THEN
        RAISE EXCEPTION 'No copy taken at the counter with id %', p_document_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    INSERT INTO extraction (document_id, model_name, model_version, prompt_version, raw_response,
                            status, read_at_counter, requested_by)
    VALUES (p_document_id, p_model_name, p_model_version, p_prompt_version, p_raw_response,
            CASE WHEN p_line_items IS NULL THEN 'rejected' ELSE 'needs_review' END::extraction_status,
            true, p_requested_by)
    RETURNING id INTO v_id;

    INSERT INTO extraction_field (extraction_id, field_name, extracted_value)
    SELECT v_id, f.key, f.value
      FROM jsonb_each_text(COALESCE(p_doc_fields, '{}')) f;

    FOR v_li IN SELECT * FROM jsonb_array_elements(COALESCE(p_line_items, '[]')) LOOP
        INSERT INTO extraction_line_item (extraction_id, n, source_region)
        VALUES (v_id, (v_li ->> 'n')::integer, v_li ->> 'source_region')
        RETURNING id INTO v_liid;
        INSERT INTO extraction_field (extraction_id, line_item_id, field_name, extracted_value)
        SELECT v_id, v_liid, f.key, f.value
          FROM jsonb_each_text(COALESCE(v_li -> 'fields', '{}')) f;
    END LOOP;

    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    SELECT p_requested_by, g.display_name, 'create', 'extraction', v_id,
           jsonb_build_object('source', 'counter', 'document_id', p_document_id, 'model', p_model_version,
                              'line_items', jsonb_array_length(COALESCE(p_line_items, '[]')))
      FROM groomer g WHERE g.id = p_requested_by;
    RETURN v_id;
END $$;

-- -----------------------------------------------------------------------------
-- What the form is filled in from
--
-- One row per reading per tracked vaccine the model found: the line with the
-- latest expiry (a certificate often lists last year's shot too). Dates come
-- through iso_date_or_null(), so a value that is not a real date is no
-- suggestion at all, and the printed form is passed along for the person to
-- compare.
-- -----------------------------------------------------------------------------

CREATE VIEW v_counter_ai_suggestion AS
SELECT DISTINCT ON (li.extraction_id, li.vaccine_code)
       li.extraction_id,
       e.document_id,
       li.line_item_id,
       li.vaccine_code,
       li.term,
       iso_date_or_null(li.administered_on) AS administered_on,
       li.administered_on_raw,
       iso_date_or_null(li.expires_on)      AS expires_on,
       li.expires_on_raw,
       -- A closer look: less than a full date printed, or a date with nothing printed.
       (li.administered_on IS NOT NULL
        AND (li.administered_on_raw IS NULL OR printed_date_parts(li.administered_on_raw) < 3)) AS given_doubtful,
       (li.expires_on IS NOT NULL
        AND (li.expires_on_raw IS NULL OR printed_date_parts(li.expires_on_raw) < 3))           AS expires_doubtful
  FROM v_extraction_line_item li
  JOIN extraction e ON e.id = li.extraction_id
 WHERE e.read_at_counter AND li.disposition = 'tracked'
 ORDER BY li.extraction_id, li.vaccine_code,
          iso_date_or_null(li.expires_on) DESC NULLS LAST,
          iso_date_or_null(li.administered_on) DESC NULLS LAST, li.n;

-- Names on the page the vocabulary has no ruling for, with what was printed
-- beside them, so the person can say what each one is.
CREATE VIEW v_counter_ai_unfamiliar AS
SELECT li.extraction_id, e.document_id, li.line_item_id, li.n, li.term,
       li.administered_on_raw, li.expires_on_raw
  FROM v_extraction_line_item li
  JOIN extraction e ON e.id = li.extraction_id
 WHERE e.read_at_counter AND li.disposition = 'unmapped'
 ORDER BY li.extraction_id, li.n;

-- A person's ruling on a name: which vaccine it is, or (NULL) that it is not a
-- vaccine the shop deals in. Read off the page by the person ruling, so it is
-- 'high' confidence. A name someone has already ruled on keeps its ruling.
CREATE FUNCTION rule_on_term(p_raw_term text, p_vaccine_code text, p_ruled_by uuid)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_actor   text;
    v_vaccine uuid;
    v_id      uuid;
BEGIN
    SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_ruled_by;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No such groomer: %', p_ruled_by USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF nullif_blank(p_raw_term) IS NULL THEN
        RAISE EXCEPTION 'No name to rule on' USING ERRCODE = 'check_violation';
    END IF;
    IF p_vaccine_code IS NOT NULL THEN
        SELECT vt.id INTO v_vaccine FROM vaccine_type vt WHERE vt.code = p_vaccine_code;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown vaccine: %', p_vaccine_code USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    INSERT INTO document_term (raw_term, vaccine_type_id, confidence, ruled_by)
    VALUES (btrim(p_raw_term), v_vaccine, 'high', p_ruled_by)
    ON CONFLICT (normalized) DO NOTHING
    RETURNING id INTO v_id;
    IF v_id IS NOT NULL THEN
        INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
        VALUES (p_ruled_by, v_actor, 'create', 'document_term', v_id,
                jsonb_build_object('source', 'counter', 'term', btrim(p_raw_term), 'vaccine', p_vaccine_code));
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- Grading a suggestion
--
-- p_outcome 'saved': the person saved this vaccine with these dates.
--   Each date the model read is confirmed when it matches and edited (with what
--   the person saved) when it does not; the vaccine name is confirmed. With no
--   line for it (p_line_item_id NULL), the model missed it: a line is added, its
--   fields edited from nothing, so the miss is counted like any other.
-- p_outcome 'not_on_paper': the person says the paperwork does not show it.
--   Anything the model read for it was not on the page: removed.
--
-- Only fields still unreviewed are graded: the first verdict stands.
-- -----------------------------------------------------------------------------

CREATE FUNCTION grade_counter_suggestion(p_extraction_id uuid, p_line_item_id uuid, p_vaccine_code text,
                                         p_administered_on date, p_expires_on date, p_outcome text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_li   uuid := p_line_item_id;
    v_name text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM extraction e WHERE e.id = p_extraction_id AND e.read_at_counter) THEN
        RAISE EXCEPTION 'No reading at the counter with id %', p_extraction_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF p_outcome NOT IN ('saved', 'not_on_paper') THEN
        RAISE EXCEPTION 'Unknown outcome %', p_outcome USING ERRCODE = 'check_violation';
    END IF;
    IF v_li IS NOT NULL AND NOT EXISTS (SELECT 1 FROM extraction_line_item li
                                         WHERE li.id = v_li AND li.extraction_id = p_extraction_id) THEN
        RAISE EXCEPTION 'Line % is not part of reading %', v_li, p_extraction_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF p_outcome = 'not_on_paper' THEN
        IF v_li IS NOT NULL THEN
            UPDATE extraction_field
               SET correction_action = CASE WHEN extracted_value IS NULL THEN 'confirmed' ELSE 'removed' END::correction_action
             WHERE line_item_id = v_li AND correction_action = 'unreviewed'
               AND field_name IN ('term', 'administered_on', 'expires_on');
        END IF;
        RETURN;   -- nothing read, nothing on the page: the model was right to say nothing
    END IF;

    IF v_li IS NULL THEN
        SELECT vt.name INTO v_name FROM vaccine_type vt WHERE vt.code = p_vaccine_code;
        INSERT INTO extraction_line_item (extraction_id, n, source_region)
        SELECT p_extraction_id, COALESCE(max(li.n), 0) + 1, 'added at the counter: the model missed it'
          FROM extraction_line_item li WHERE li.extraction_id = p_extraction_id
        RETURNING id INTO v_li;
        INSERT INTO extraction_field (extraction_id, line_item_id, field_name, extracted_value,
                                      corrected_value, correction_action)
        VALUES (p_extraction_id, v_li, 'term',            NULL, v_name,                   'edited'),
               (p_extraction_id, v_li, 'administered_on', NULL, p_administered_on::text, 'edited'),
               (p_extraction_id, v_li, 'expires_on',      NULL, p_expires_on::text,      'edited');
        RETURN;
    END IF;

    UPDATE extraction_field ef
       SET correction_action = CASE WHEN ef.extracted_value IS NOT DISTINCT FROM s.value
                                    THEN 'confirmed' ELSE 'edited' END::correction_action,
           corrected_value   = CASE WHEN ef.extracted_value IS NOT DISTINCT FROM s.value THEN NULL ELSE s.value END
      FROM (VALUES ('administered_on', p_administered_on::text), ('expires_on', p_expires_on::text)) s(field, value)
     WHERE ef.line_item_id = v_li AND ef.field_name = s.field AND ef.correction_action = 'unreviewed';
    UPDATE extraction_field SET correction_action = 'confirmed'
     WHERE line_item_id = v_li AND field_name = 'term' AND correction_action = 'unreviewed';
END $$;

COMMENT ON FUNCTION grade_counter_suggestion(uuid, uuid, text, date, date, text) IS
  'The counter''s verdict on what the model read for one vaccine: confirmed, '
  'edited, removed, or missed. Written as the same per-field review the records '
  'tool writes, so every evaluation view counts it.';

-- -----------------------------------------------------------------------------
-- How the model is doing on real paperwork
--
-- Dates only: they are what the counter checks, and what a record rests on.
-- A copy made from photos is a photo; one that came as a PDF is a PDF.
-- -----------------------------------------------------------------------------

CREATE VIEW v_counter_ai_accuracy AS
SELECT CASE WHEN d.exif_stripped THEN 'photo' ELSE 'pdf' END AS copy_kind,
       count(DISTINCT e.id)                                                                   AS readings,
       count(*) FILTER (WHERE ef.correction_action IN ('confirmed', 'edited', 'removed')
                          AND (ef.extracted_value IS NOT NULL OR ef.corrected_value IS NOT NULL)) AS dates_checked,
       count(*) FILTER (WHERE ef.correction_action = 'confirmed' AND ef.extracted_value IS NOT NULL) AS right_first_time,
       count(*) FILTER (WHERE ef.correction_action = 'edited'    AND ef.extracted_value IS NOT NULL) AS read_wrong,
       count(*) FILTER (WHERE ef.correction_action = 'edited'    AND ef.extracted_value IS NULL)     AS missed,
       count(*) FILTER (WHERE ef.correction_action = 'removed')                                   AS made_up
  FROM extraction e
  JOIN document d          ON d.id = e.document_id
  JOIN extraction_field ef ON ef.extraction_id = e.id
 WHERE e.read_at_counter AND ef.field_name IN ('administered_on', 'expires_on')
 GROUP BY 1;

-- -----------------------------------------------------------------------------
-- The manager's waiting list says which copies the AI has already read
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_paperwork_waiting AS
SELECT cp.document_id, cp.dog_id, d.name AS dog, o.first_name || ' ' || o.last_name AS owner,
       doc.mime_type, doc.page_count, g.display_name AS received_by, cp.received_at,
       EXISTS (SELECT 1 FROM extraction e WHERE e.document_id = cp.document_id
                 AND e.read_at_counter AND e.status = 'needs_review') AS ai_read
  FROM counter_paperwork cp
  JOIN document doc ON doc.id = cp.document_id
  JOIN dog d        ON d.id = cp.dog_id
  JOIN owner o      ON o.id = d.owner_id
  JOIN groomer g    ON g.id = cp.received_by
 WHERE cp.checked_at IS NULL AND d.is_active
 ORDER BY cp.received_at;
