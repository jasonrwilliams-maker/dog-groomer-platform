-- The vocabulary is data, and the lookup fails closed.
--
-- Five things are proven here:
--   1. The seed is what section 15 says it is: 29 rulings, all traceable to
--      the answer keys, and a tracked term resolves to its vaccine.
--   2. Normalisation absorbs typography and NOTHING else. Case, whitespace,
--      spacing around a hyphen and a trailing full stop collapse; a cadence
--      word does not. An unseen spelling is 'unmapped', never a near-match.
--   3. NULL is a ruling. 'Canine Lyme Test' resolves to not_a_vaccine, which
--      is a different answer from 'nobody has looked'.
--   4. Tracking is configuration, not vocabulary. Flip leptospirosis to
--      required_by_policy and its existing rows start resolving to 'tracked'
--      with no change to document_term.
--   5. The table refuses what it should: an uncertain ruling without a
--      rationale, two rows that normalise to the same key, and a hand-set
--      normalised key.

BEGIN;
SET search_path = groom, public;
SELECT plan(14);

-- --- 1. The seed --------------------------------------------------------------
SELECT is((SELECT count(*) FROM document_term), 29::bigint,
  'Seed carries the 29 rulings the four answer keys established');

SELECT is((SELECT count(*) FROM document_term WHERE vaccine_type_id IS NULL), 17::bigint,
  'Seventeen of them are positive not-a-vaccine rulings');

SELECT results_eq(
  $$ SELECT disposition::text, vaccine_code FROM resolve_term('Rabies Vaccine 3 Year') $$,
  $$ VALUES ('tracked', 'rabies') $$,
  'A seeded rabies spelling resolves to tracked / rabies');

-- --- 2. Normalisation: typography only ---------------------------------------
SELECT is(normalize_term('  Rabies  Vaccine  -  1 Year. '), 'rabies vaccine-1 year',
  'Case, runs of whitespace, spacing around a hyphen and a trailing stop collapse');

SELECT is((SELECT disposition::text FROM resolve_term('RABIES VACCINE - 1 YEAR.')), 'tracked',
  'A typographic variant of a seeded term still resolves');

SELECT is((SELECT disposition::text FROM resolve_term('Rabies Vaccine 3 Yr')), 'unmapped',
  'Dropping the word Year to Yr is a new spelling: unmapped, not a near-match');

SELECT is((SELECT disposition::text FROM resolve_term('Rabies')), 'unmapped',
  'The bare word rabies has no ruling and fails closed');

-- --- 3. NULL is a ruling -----------------------------------------------------
SELECT is((SELECT disposition::text FROM resolve_term('Canine Lyme Test')), 'not_a_vaccine',
  'A diagnostic test with a row resolves to not_a_vaccine, which is not unmapped');

SELECT is((SELECT disposition::text FROM resolve_term('ProHeart-6 Heartworm Prevent Inj')), 'not_a_vaccine',
  'The injectable parasiticide is positively ruled out, not left to the queue');

-- --- 4. Tracking is configuration --------------------------------------------
SELECT is((SELECT disposition::text FROM resolve_term('Leptospira 4x Annual')), 'recognized_untracked',
  'Leptospirosis is recognised and untracked as seeded');

UPDATE vaccine_type SET required_by_policy = true WHERE code = 'leptospirosis';

SELECT is((SELECT disposition::text FROM resolve_term('Leptospira 4x Annual')), 'tracked',
  'One UPDATE on vaccine_type and the same term resolves to tracked; document_term untouched');

-- --- 5. Refusals -------------------------------------------------------------
SELECT throws_ok(
  $$ INSERT INTO document_term (raw_term, vaccine_type_id, confidence)
     VALUES ('Some Mystery Injection', NULL, 'low') $$,
  '23514',
  NULL,
  'A ruling below high confidence must carry a rationale');

SELECT throws_ok(
  $$ INSERT INTO document_term (raw_term, vaccine_type_id)
     VALUES ('rabies vaccine 3 year', (SELECT id FROM vaccine_type WHERE code = 'rabies')) $$,
  '23505',
  NULL,
  'Two spellings that normalise to one key are one row, not two');

SELECT throws_ok(
  $$ INSERT INTO document_term (raw_term, normalized, vaccine_type_id)
     VALUES ('Bordetella Oral', 'bordetella oral', (SELECT id FROM vaccine_type WHERE code = 'bordetella')) $$,
  '428C9',
  NULL,
  'The normalised key is generated; it cannot be written by hand');

SELECT * FROM finish();
ROLLBACK;
