-- =============================================================================
-- 15. Document vocabulary
--
-- WHERE THIS SITS IN THE PIPELINE
--
--   1. A document is uploaded              -> document
--   2. The model reads it                  -> extraction, extraction_field
--        The model transcribes terms VERBATIM and stops. It never classifies,
--        and it never sees this table.
--   3. RESOLUTION — this file               -> resolve_term(term)
--        A deterministic SQL lookup turns 'DHPP 3YR W/ LEPTO' into a
--        vaccine_type, or into a positive "not a vaccine", or into nothing.
--   4. A human reviews                     -> extraction_field.correction_action,
--                                             and rules on any unmapped terms
--   5. Confirmed                           -> vaccination_record
--
-- The model is never given the vocabulary. If it were, the prompt would have
-- become the parser — and a prompt that enumerates synonyms has to be re-edited
-- for every practice, which is the maintenance treadmill this design exists to
-- avoid. The vocabulary is data a human maintains, one row at a time, forever.
--
-- FAIL CLOSED. A term with no row resolves to 'unmapped', which routes the
-- extraction to needs_review. Deleting a row cannot silently turn a mapping off;
-- it can only send the term back to a human. Same reasoning as
-- enforcement_level() defaulting to 'block'.
--
-- WHY A ROW'S EXISTENCE IS THE RULING
-- 'Comprehensive Physical Exam' must be POSITIVELY KNOWN not to be a vaccine, or
-- it returns to the review queue on every future document from that practice. A
-- row with vaccine_type_id IS NULL is that ruling. No row at all is "nobody has
-- looked yet". This is the same distinction extraction_field.correction_action
-- draws between 'unreviewed' and 'removed', one layer up.
-- =============================================================================

SET search_path = groom, public;

-- -----------------------------------------------------------------------------
-- Normalisation
--
-- DELIBERATELY CONSERVATIVE. It absorbs typography and nothing else: case,
-- whitespace, spacing around hyphens and slashes, a trailing full stop.
--
-- It does NOT strip cadence words ('Annual', '3 Yr'), the vaccine/vaccination
-- alternation, or species qualifiers. An earlier draft of this design proposed
-- that, and it was wrong: a normaliser clever enough to collapse
-- 'Rabies Vaccine 3 Year' and 'Rabies Vaccination 3 Yr.' is also clever enough
-- to collapse two things that differ, and it would do so silently, with no human
-- in the loop. That is the prompt-as-parser problem moved into SQL.
--
-- The cost of being conservative is more rows — four spellings of rabies in this
-- corpus means four rows. Four rows is a human ruling four times, once each,
-- forever. That is the cheap failure.
-- -----------------------------------------------------------------------------

CREATE FUNCTION normalize_term(p_term text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT rtrim(
             trim(
               regexp_replace(
                 regexp_replace(lower(p_term), '\s*([-/])\s*', '\1', 'g'),
                 '\s+', ' ', 'g')),
             '.')
$$;

-- -----------------------------------------------------------------------------
-- The vocabulary
-- -----------------------------------------------------------------------------

CREATE TABLE document_term (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    -- One spelling as it appeared on a page. Kept verbatim so a reviewer can see
    -- what they actually ruled on.
    raw_term        text NOT NULL,

    -- The lookup key. GENERATED so there is exactly one normalisation code path
    -- and no way to insert an unnormalised key by hand.
    normalized      text GENERATED ALWAYS AS (normalize_term(raw_term)) STORED,

    -- NULL is a ruling, not an absence: "a human looked, and this is not a
    -- vaccine". No row at all is the absence.
    vaccine_type_id uuid REFERENCES vaccine_type(id) ON DELETE RESTRICT,

    confidence      text NOT NULL DEFAULT 'high'
                    CHECK (confidence IN ('high', 'medium', 'low')),

    -- Required below 'high'. A ruling a future reader might question has to
    -- carry its reasoning, or the audit is a shrug.
    rationale       text,

    ruled_at        timestamptz NOT NULL DEFAULT now(),
    -- No FK, matching shop_policy.updated_by: a ruling should outlive the
    -- account that made it, and seed rows predate every groomer.
    ruled_by        uuid,

    CONSTRAINT uncertain_ruling_needs_rationale
      CHECK (confidence = 'high' OR rationale IS NOT NULL)
);

CREATE UNIQUE INDEX document_term_normalized_key ON document_term (normalized);
CREATE INDEX document_term_vaccine_idx
  ON document_term (vaccine_type_id) WHERE vaccine_type_id IS NOT NULL;

COMMENT ON COLUMN document_term.vaccine_type_id IS
  'NULL means a human ruled this is not a vaccine. Absence of a row means nobody '
  'has ruled yet. Collapsing the two would send every known non-vaccine back to '
  'the review queue on every document, forever.';

COMMENT ON TABLE document_term IS
  'Two spellings that normalise differently are two rows pointing at the same '
  'vaccine_type. That is the intended shape — adding a row is cheap and safe, '
  'and a cleverer normaliser is neither.';

-- -----------------------------------------------------------------------------
-- Resolution
--
-- Note what is NOT stored here: whether a vaccine is tracked. That follows from
-- vaccine_type.regulatory_required / required_by_policy, read live. Flipping
-- leptospirosis to required_by_policy = true makes every existing term row start
-- tracking it with no data migration — the PREFERENCE tier working as designed.
-- -----------------------------------------------------------------------------

CREATE TYPE term_disposition AS ENUM (
    'unmapped',              -- no row: nobody has ruled. Routes to needs_review.
    'not_a_vaccine',         -- ruled: a test, a treatment, a fee, a discount line
    'recognized_untracked',  -- a real vaccine this shop does not track
    'tracked'                -- one of the vaccines that gates a grooming appointment
);

CREATE FUNCTION resolve_term(p_term text)
RETURNS TABLE (disposition term_disposition,
               vaccine_type_id uuid,
               vaccine_code text,
               confidence text)
LANGUAGE sql STABLE AS $$
    SELECT CASE
             WHEN t.id IS NULL              THEN 'unmapped'
             WHEN t.vaccine_type_id IS NULL THEN 'not_a_vaccine'
             WHEN vt.regulatory_required
               OR vt.required_by_policy     THEN 'tracked'
             ELSE                                'recognized_untracked'
           END::term_disposition,
           t.vaccine_type_id,
           vt.code,
           t.confidence
    FROM (SELECT normalize_term(p_term) AS key) k
    LEFT JOIN document_term t  ON t.normalized = k.key
    LEFT JOIN vaccine_type  vt ON vt.id = t.vaccine_type_id
$$;

COMMENT ON FUNCTION resolve_term(text) IS
  'The only entry point. Callers pass the term exactly as the model transcribed '
  'it; normalisation happens here so there is one code path and callers cannot '
  'skip it.';

-- -----------------------------------------------------------------------------
-- The review queue lives in section 16
--
-- v_unmapped_terms — the human's work list of terms nobody has ruled on — is
-- defined in 16_extraction_line_item.sql, because it reads line items and the
-- line-item shape is that section's decision. Nothing here depends on it.
-- -----------------------------------------------------------------------------

-- =============================================================================
-- Seed: the vocabulary the labelled corpus already establishes
--
-- 29 distinct terms from 32 printed lines across four documents and three
-- practices. Every ruling here was made by hand against a real page and is
-- recorded in the answer keys; this is a transcription of those rulings, not a
-- guess.
--
-- Worth noticing before reading it: NOT ONE TERM APPEARS IN TWO DOCUMENTS.
-- Rabies is spelled four different ways by four different systems. The three
-- lines that collapsed did so within a single document, where the Doc Side
-- invoice prints the same vaccination twice in two regions.
-- =============================================================================

INSERT INTO document_term (raw_term, vaccine_type_id, confidence, rationale) VALUES

-- --- rabies: four practices, four spellings ---------------------------------
  ('Rabies Vaccine - 1 year',       (SELECT id FROM vaccine_type WHERE code='rabies'), 'high', NULL),
  ('Rabies Vaccine 3 Year',         (SELECT id FROM vaccine_type WHERE code='rabies'), 'high', NULL),
  ('Rabies Vaccination 3 Yr.',      (SELECT id FROM vaccine_type WHERE code='rabies'), 'high', NULL),
  ('Rabies Vaccine 3 Yr Canine',    (SELECT id FROM vaccine_type WHERE code='rabies'), 'high', NULL),

-- --- dhpp -------------------------------------------------------------------
  ('DHPP 3YR',                      (SELECT id FROM vaccine_type WHERE code='dhpp'), 'high', NULL),
  ('DHPP 3YR W/ LEPTO',             (SELECT id FROM vaccine_type WHERE code='dhpp'), 'medium',
   'Maps to DHPP alone, not to DHPP and leptospirosis. Its 2028 expiry is a three-year interval, which is the DHPP component''s duration; the lepto component is its own row with a one-year expiry. Confirmed by the Doc Side invoice billing the two as separate items on 2025-04-04.'),
  ('Distemper/Parvo Vaccine Adult (3 yr)', (SELECT id FROM vaccine_type WHERE code='dhpp'), 'medium',
   'Names two of DHPP''s four components. Standard practice treats Distemper/Parvo as the core combination shot and the three-year adult interval matches, but that is domain inference on an incomplete label. A separate dapp vaccine_type was considered and rejected: it would fragment one compliance obligation across two codes.'),

-- --- bordetella -------------------------------------------------------------
  ('Bi-annual bordetella Vaccine',  (SELECT id FROM vaccine_type WHERE code='bordetella'), 'high', NULL),
  ('Bordetella Annual Injectable',  (SELECT id FROM vaccine_type WHERE code='bordetella'), 'high', NULL),

-- --- leptospirosis: a real vaccine this shop does not track ------------------
-- Untracked by configuration, not by this table. Flip
-- vaccine_type.required_by_policy and these three rows start tracking with no
-- change here.
  ('Leptospira 4x Annual',          (SELECT id FROM vaccine_type WHERE code='leptospirosis'), 'high', NULL),
  ('Leptospirosis 4- Way Vaccine',  (SELECT id FROM vaccine_type WHERE code='leptospirosis'), 'high', NULL),
  ('Leptospira 4x Annual w/ DHPP',  (SELECT id FROM vaccine_type WHERE code='leptospirosis'), 'medium',
   'Maps to leptospirosis alone. Its 2027-04-02 expiry is a one-year interval, which is the lepto duration, not DHPP''s. The DHPP component is its own row.'),

-- --- not vaccines: diagnostic tests -----------------------------------------
-- Each needs a POSITIVE ruling. Left unmapped they return to the review queue on
-- every future document from the same practice.
  ('Canine Anaplasmosis Test',              NULL, 'high', NULL),
  ('Canine Ehrlichiosis Test',              NULL, 'high', NULL),
  ('Canine Heartworm Test',                 NULL, 'high', NULL),
  ('Canine Lyme Test',                      NULL, 'medium',
   'A canine Lyme VACCINE exists and is common, which is exactly why this needs a positive not-a-vaccine ruling rather than being left unmapped. Note that the vaccine would also be untracked here — tick-borne, not dog-to-dog — so the classification and the scope decision are independent.'),
  ('Heartworm, E.Canis & Lyme Test',        NULL, 'high', NULL),
  ('Heartworm HWT Accuplex ANTECH AC100',   NULL, 'high', NULL),
  ('Intestinal Parasite Screen',            NULL, 'high', NULL),
  ('Fecal/Intestinal Parasite Test',        NULL, 'high', NULL),
  ('Fecal Cent. & Giardia to Antech T808',  NULL, 'high', NULL),

-- --- not vaccines: preventatives and treatments -----------------------------
  ('ProHeart-6 Heartworm Prevent Inj',      NULL, 'medium',
   'The hardest row in the corpus. Injectable, six-month interval, carries a due date, and printed under a heading reading Vaccinations. Every structural signal says vaccine except the pharmacology — it is a slow-release parasiticide. Recording it as a vaccine would put a non-vaccine on a health department packet.'),
  ('Deworming- Rounds & Hooks',             NULL, 'high', NULL),

-- --- not vaccines: exams ----------------------------------------------------
  ('Bi-Annual Physical Exam',               NULL, 'high', NULL),
  ('Comprehensive Physical Exam w/Bi-Annual', NULL, 'high', NULL),

-- --- not vaccines: billing lines --------------------------------------------
-- An invoice is mostly money. These rule out once and stay ruled out.
  ('Technician Appointment',                NULL, 'high', NULL),
  ('Appointment kept',                      NULL, 'high', NULL),
  ('OSHA Compliance fee',                   NULL, 'high', NULL),
  ('Benchmark',                             NULL, 'medium',
   'A -122.00 discount line on the Doc Side invoice. Ruled explicitly because the word carries no clue to its meaning and a future reader would otherwise re-open the question.');

ALTER FUNCTION normalize_term(text) SET search_path = groom, public;
ALTER FUNCTION resolve_term(text)   SET search_path = groom, public;
