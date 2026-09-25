-- =============================================================================
-- 16. Extraction line items
--
-- Closes the decision that section 15 left open. extraction_field was a flat
-- (extraction_id, field_name, extracted_value) store, and the canonical shape in
-- answer_key_contract.md carries an ARRAY of line items — up to thirteen rows
-- with fourteen fields each. Two options were on the table:
--
--   A. Keep the flat store and encode the row index in the name
--      ('line_items[3].expires_on'). No schema change; string-typed structure;
--      every consumer parses the index back out of the name.
--   B. Give a line item a row of its own.
--
-- This is B, with one refinement over the sketch in section 15. The line item
-- is a real row with an FK to its extraction, but its FIELDS stay in
-- extraction_field, keyed by line_item_id. Two reasons:
--
--   1. Layer 1 is transcription, and a transcription is text. The invoice's
--      reminder column reads '03-28'. The model must emit that verbatim into
--      expires_on_raw and leave expires_on null, and a `date` column cannot hold
--      '03-28'. Typed columns belong to Layer 3 (vaccination_record), where a
--      human has confirmed the value and the date is real.
--
--   2. correction_action is per FIELD, and that granularity is the whole point
--      of it. The hallucination case on this corpus is a single invented
--      expires_on on one row — not a bad row. Putting correction_action on the
--      line item would score that row as one error and lose which field it was;
--      duplicating the review columns onto both tables would mean two review
--      models to keep coherent. One review model, in one place, is worth more
--      than a wide table.
--
-- The review UI still gets its columns: v_extraction_line_item pivots the
-- fields back into one row per line item, applies the human's corrections, and
-- joins the resolution from section 15. That view is what the front end reads.
--
-- Field naming, now fixed:
--   document-level   'clinic.name', 'patient.sex_raw', 'document.as_of_date'
--                    (line_item_id IS NULL; the dotted path of the canonical shape)
--   line-item        'term', 'expires_on_raw', 'expires_on', ...
--                    (line_item_id IS NOT NULL; the bare field name, from a
--                    closed list that matches the contract exactly)
-- =============================================================================

SET search_path = groom, public;

-- -----------------------------------------------------------------------------
-- The line item
--
-- Deliberately thin: position and provenance only. Everything the model read
-- off the row is an extraction_field pointing here.
-- -----------------------------------------------------------------------------

CREATE TABLE extraction_line_item (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    extraction_id  uuid NOT NULL REFERENCES extraction(id) ON DELETE CASCADE,

    -- 1-based position on the page, as the answer keys number them.
    n              integer NOT NULL CHECK (n >= 1),

    page_number    integer CHECK (page_number >= 1),

    -- Where on the page the row came from, when the format has more than one
    -- region carrying vaccination facts. The Doc Side invoice prints billed
    -- services and reminders as two lists with different provenance: a billed
    -- line has a definitive administration date, a reminder line has a due
    -- month. Free text, because every format names its regions differently.
    source_region  text,

    UNIQUE (extraction_id, n),

    -- Lets extraction_field prove that a line item belongs to the extraction it
    -- claims to. See the composite FK below.
    UNIQUE (id, extraction_id)
);
CREATE INDEX extraction_line_item_extraction_idx ON extraction_line_item (extraction_id, n);

COMMENT ON TABLE extraction_line_item IS
  'One row per printed line the model transcribed, vaccine or not. Seven of the '
  'eleven rows on the Petly page produce nothing, and they are all here, because '
  'the ratio is the most useful thing that document measures.';

-- -----------------------------------------------------------------------------
-- extraction_field learns which line item it belongs to
-- -----------------------------------------------------------------------------

ALTER TABLE extraction_field
    ADD COLUMN line_item_id uuid;

-- The composite FK: (line_item_id, extraction_id) must exist as a pair on
-- extraction_line_item, so a field cannot point at a line item from a different
-- extraction. MATCH SIMPLE means a NULL line_item_id (a document-level field)
-- is not checked, which is the intended behaviour.
ALTER TABLE extraction_field
    ADD CONSTRAINT extraction_field_line_item_same_extraction
    FOREIGN KEY (line_item_id, extraction_id)
    REFERENCES extraction_line_item (id, extraction_id)
    ON DELETE CASCADE;

CREATE INDEX extraction_field_line_item_idx
    ON extraction_field (line_item_id) WHERE line_item_id IS NOT NULL;

-- One value per field per line item, and one per document-level field.
-- NULLS NOT DISTINCT so that two document-level rows named 'clinic.name' on the
-- same extraction collide, which the old constraint enforced and the new shape
-- must keep enforcing.
ALTER TABLE extraction_field
    DROP CONSTRAINT extraction_field_extraction_id_field_name_key;
ALTER TABLE extraction_field
    ADD CONSTRAINT extraction_field_one_value_per_slot
    UNIQUE NULLS NOT DISTINCT (extraction_id, line_item_id, field_name);

-- The closed list of line-item fields. It is the canonical shape from
-- answer_key_contract.md v4, nothing more: a model emitting a field that is not
-- on the page's contract is refused at insert, not discovered at review.
ALTER TABLE extraction_field
    ADD CONSTRAINT extraction_field_line_item_name_known CHECK (
        line_item_id IS NULL
        OR field_name IN (
            'term', 'source_region',
            'administered_on_raw', 'administered_on',
            'expires_on_raw',      'expires_on',
            'status_raw',
            'lot_serial_number', 'vaccine_manufacturer',
            'veterinarian_name', 'veterinarian_license_no', 'veterinarian_phone',
            'tag_number'
        )
    );

COMMENT ON COLUMN extraction_field.line_item_id IS
  'NULL for a document-level field (clinic.*, owner.*, patient.*, document.*). '
  'Set for a field read off one printed line. The composite FK guarantees the '
  'line item and the field agree about which extraction they belong to.';

-- -----------------------------------------------------------------------------
-- The effective value of a field, after review
--
-- unreviewed / confirmed -> what the model said
-- edited                 -> what the human typed
-- removed                -> nothing. The model invented it.
--
-- One function, so every reader agrees on what "the value" means.
-- -----------------------------------------------------------------------------

CREATE FUNCTION effective_value(f extraction_field) RETURNS text
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT CASE f.correction_action
             WHEN 'removed' THEN NULL
             WHEN 'edited'  THEN f.corrected_value
             ELSE                f.extracted_value
           END
$$;

-- -----------------------------------------------------------------------------
-- The fields that will be copied into a vaccination_record
--
-- A row becomes a record only after a human has looked at every one of these.
-- The held-out photo is why: every smudged expiry on it ('Jan 2?, 2027') came
-- back from the model as a clean, confident date ('Jan 29, 2027'), and a
-- confident date is still a date. Presence cannot tell a printed date from an
-- invented one; only review can.
--
-- One list, so the record rule here and the review work order in section 17
-- cannot disagree about what "feeds a record" means.
-- -----------------------------------------------------------------------------

CREATE FUNCTION is_record_field(field_name text) RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT field_name IN ('term', 'administered_on', 'expires_on',
                          'vaccine_manufacturer', 'lot_serial_number',
                          'veterinarian_name', 'veterinarian_license_no',
                          'veterinarian_phone')
$$;

-- -----------------------------------------------------------------------------
-- The review queue (moved here from section 15, where it was a placeholder)
--
-- A view, not a table. Rule on a term and it leaves the queue on the next read.
-- Reads the effective term, so a term the reviewer has corrected is looked up
-- by its corrected spelling and a term the reviewer removed does not appear.
--
-- One row per NORMALISED key, because one ruling clears every spelling that
-- normalises to it. The raw spellings are carried along so the reviewer sees
-- what the pages actually said, and rules on one of them verbatim.
-- -----------------------------------------------------------------------------

CREATE VIEW v_unmapped_terms AS
SELECT normalize_term(effective_value(ef))              AS normalized,
       array_agg(DISTINCT effective_value(ef))          AS raw_terms,
       count(*)                                         AS times_seen,
       min(e.extracted_at)                              AS first_seen_at,
       max(e.extracted_at)                              AS last_seen_at,
       array_agg(DISTINCT d.id)                         AS document_ids
FROM extraction_field ef
JOIN extraction e ON e.id = ef.extraction_id
JOIN document   d ON d.id = e.document_id
WHERE ef.line_item_id IS NOT NULL
  AND ef.field_name = 'term'
  AND effective_value(ef) IS NOT NULL
  AND NOT EXISTS (
        SELECT 1 FROM document_term t
        WHERE t.normalized = normalize_term(effective_value(ef)))
GROUP BY 1
ORDER BY count(*) DESC, min(e.extracted_at);

COMMENT ON VIEW v_unmapped_terms IS
  'The human''s work list. One row per normalised key, ordered by frequency, so '
  'the term blocking the most documents is ruled on first.';

-- -----------------------------------------------------------------------------
-- The line item, as the review screen sees it
--
-- One row per line item, fields pivoted to columns, corrections applied, and
-- the section-15 resolution joined in. Layer 1 and Layer 2 side by side, with
-- the layer boundary visible: everything left of `disposition` is what the
-- page said; everything from it rightwards is what the database made of it.
--
-- Values stay text. Casting expires_on to a date is Layer 3's job, at the
-- moment a vaccination_record is written from a confirmed extraction.
-- -----------------------------------------------------------------------------

CREATE VIEW v_extraction_line_item AS
WITH f AS (
    SELECT ef.line_item_id,
           ef.field_name,
           effective_value(ef) AS value,
           ef.correction_action
    FROM extraction_field ef
    WHERE ef.line_item_id IS NOT NULL
),
pivot AS (
    SELECT line_item_id,
           max(value) FILTER (WHERE field_name = 'term')                    AS term,
           max(value) FILTER (WHERE field_name = 'administered_on_raw')     AS administered_on_raw,
           max(value) FILTER (WHERE field_name = 'administered_on')         AS administered_on,
           max(value) FILTER (WHERE field_name = 'expires_on_raw')          AS expires_on_raw,
           max(value) FILTER (WHERE field_name = 'expires_on')              AS expires_on,
           max(value) FILTER (WHERE field_name = 'status_raw')              AS status_raw,
           max(value) FILTER (WHERE field_name = 'lot_serial_number')       AS lot_serial_number,
           max(value) FILTER (WHERE field_name = 'vaccine_manufacturer')    AS vaccine_manufacturer,
           max(value) FILTER (WHERE field_name = 'veterinarian_name')       AS veterinarian_name,
           max(value) FILTER (WHERE field_name = 'veterinarian_license_no') AS veterinarian_license_no,
           max(value) FILTER (WHERE field_name = 'veterinarian_phone')      AS veterinarian_phone,
           max(value) FILTER (WHERE field_name = 'tag_number')              AS tag_number,
           count(*)                                                         AS field_count,
           count(*) FILTER (WHERE correction_action = 'unreviewed')         AS unreviewed_count,
           count(*) FILTER (WHERE correction_action = 'removed')            AS removed_count,
           count(*) FILTER (WHERE correction_action = 'unreviewed'
                              AND is_record_field(field_name))              AS unreviewed_record_fields
    FROM f
    GROUP BY line_item_id
)
SELECT li.id                    AS line_item_id,
       li.extraction_id,
       e.document_id,
       li.n,
       li.page_number,
       li.source_region,
       p.term,
       p.administered_on_raw, p.administered_on,
       p.expires_on_raw,      p.expires_on,
       p.status_raw,
       p.lot_serial_number,   p.vaccine_manufacturer,
       p.veterinarian_name,   p.veterinarian_license_no, p.veterinarian_phone,
       p.tag_number,
       p.field_count,
       p.unreviewed_count,
       p.removed_count,
       p.unreviewed_record_fields,
       -- Layer 2 begins here.
       r.disposition,
       r.vaccine_code,
       r.confidence             AS ruling_confidence,
       -- Layer 3's precondition, stated as a fact rather than inferred later.
       -- record_candidate: a tracked vaccine with both dates present. Everything
       -- else is evidence only.
       -- can_create_record: a candidate on which a human has also looked at
       -- every field the record will carry. A model-supplied date is present
       -- whether or not it was printed, so presence alone is not enough.
       (r.disposition = 'tracked'
        AND p.administered_on IS NOT NULL
        AND p.expires_on      IS NOT NULL)  AS record_candidate,
       (r.disposition = 'tracked'
        AND p.administered_on IS NOT NULL
        AND p.expires_on      IS NOT NULL
        AND p.unreviewed_record_fields = 0) AS can_create_record
FROM extraction_line_item li
JOIN extraction e ON e.id = li.extraction_id
LEFT JOIN pivot p ON p.line_item_id = li.id
LEFT JOIN LATERAL resolve_term(p.term) r ON p.term IS NOT NULL
ORDER BY li.extraction_id, li.n;

COMMENT ON VIEW v_extraction_line_item IS
  'What the review screen shows. Text in, text out; the date cast happens at '
  'Layer 3. can_create_record is the Jaddi rule made visible per row: a '
  'tracked vaccine still creates nothing without both dates on the page, and '
  'nothing until a human has reviewed every field the record will carry.';

ALTER FUNCTION effective_value(extraction_field) SET search_path = groom, public;
ALTER FUNCTION is_record_field(text)             SET search_path = groom, public;
