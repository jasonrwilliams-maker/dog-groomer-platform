-- Allergies and handling notes, kept from the counter.
--
-- Eight things are proven:
--   1. An allergy is picked from the list, in any case, and audited.
--   2. A misspelt allergen is refused with the nearest names (GR024); a new
--      one is added only when the groomer says it is new, and which group.
--   3. The same allergy twice is refused.
--   4. More severe needs no reason and flags nothing. Less severe needs a
--      reason (GR025) and is flagged for a manager.
--   5. Taking an allergy off needs a reason (GR025), keeps it on file marked
--      removed, flags it — and the allergy can be added again.
--   6. A manager's own change is reviewed as it is made.
--   7. Only a manager can mark a change reviewed (GR026).
--   8. A handling note is added with the new triggers, and a typo in it is
--      corrected with only the change audited.

BEGIN;
SET search_path = groom, public;
SELECT plan(24);

-- Jaddi (d001) and Luna (d002); Nadia (b001) is the manager, Tanya (b002) is not.

-- --- 1. From the list ----------------------------------------------------------------------
CREATE TEMP TABLE t_chicken AS
SELECT add_allergy('00000000-0000-0000-0000-00000000d001', 'chicken', 2, 'owner_reported',
                   'Itchy ears after chicken treats', '00000000-0000-0000-0000-00000000b002') AS id;

SELECT results_eq(
  $$ SELECT al.name, al.allergy_type, a.severity_ordinal::int FROM allergy a JOIN allergen al ON al.id = a.allergen_id
      WHERE a.id = (SELECT id FROM t_chicken) $$,
  $$ VALUES ('Chicken'::text, 'food'::text, 2) $$,
  'An allergy is picked from the list, in any case, and keeps its group');

SELECT is(
  (SELECT actor_label FROM audit_log WHERE entity_type = 'allergy' AND action = 'create'
      AND entity_id = (SELECT id FROM t_chicken)),
  'Tanya', 'Adding it is audited with who did it');

-- --- 2. Not on the list --------------------------------------------------------------------
SELECT throws_ok(
  $$ SELECT add_allergy('00000000-0000-0000-0000-00000000d001', 'Chiken', 2, NULL, NULL,
                        '00000000-0000-0000-0000-00000000b002') $$,
  'GR024', '"Chiken" is not on the allergy list', 'A misspelt allergen is refused, not added to the list');

SELECT is((SELECT name FROM suggest_allergens('Chiken') LIMIT 1), 'Chicken',
  'And the nearest name is the one it meant');

SELECT ok('Flea bites (flea allergy dermatitis)' IN (SELECT name FROM suggest_allergens('flea')),
  'Part of a name finds the whole of it');

SELECT throws_ok(
  $$ SELECT add_allergy('00000000-0000-0000-0000-00000000d001', 'Bison', 2, NULL, NULL,
                        '00000000-0000-0000-0000-00000000b002', true, NULL) $$,
  '23514', NULL, 'A new allergen has to say which group it belongs to');

CREATE TEMP TABLE t_bison AS
SELECT add_allergy('00000000-0000-0000-0000-00000000d001', 'Bison', 1, NULL, NULL,
                   '00000000-0000-0000-0000-00000000b002', true, 'food') AS id;

SELECT is((SELECT allergy_type FROM allergen WHERE name = 'Bison'), 'food',
  'A new allergen is added to the list in the group the groomer chose');

-- --- 3. Twice --------------------------------------------------------------------------------
SELECT throws_ok(
  $$ SELECT add_allergy('00000000-0000-0000-0000-00000000d001', 'Chicken', 3, NULL, NULL,
                        '00000000-0000-0000-0000-00000000b002') $$,
  '23505', 'Chicken is already on this dog''s allergies', 'The same allergy twice is refused');

-- --- 4. More and less severe -----------------------------------------------------------------------
SELECT is(
  update_allergy((SELECT id FROM t_chicken), 3, 'vet_documented', 'Itchy ears after chicken treats',
                 '00000000-0000-0000-0000-00000000b002'),
  '{"severity": {"old": "Moderate", "new": "Severe"}, "source": {"old": "owner_reported", "new": "vet_documented"}}'::jsonb,
  'More severe, from the vet: recorded in words');

SELECT is((SELECT count(*) FROM change_review), 0::bigint, 'More severe needs no reason and flags nothing');

SELECT throws_ok(
  $$ SELECT update_allergy((SELECT id FROM t_chicken), 1, NULL, NULL, '00000000-0000-0000-0000-00000000b002') $$,
  'GR025', 'Chicken: making it less severe needs a reason', 'Less severe without a reason is refused');

SELECT lives_ok(
  $$ SELECT update_allergy((SELECT id FROM t_chicken), 1, NULL, 'Itchy ears after chicken treats',
                           '00000000-0000-0000-0000-00000000b002', 'Vet retested: only mild') $$,
  'With a reason it is saved');

SELECT results_eq(
  $$ SELECT summary, reason, changed_by FROM v_change_review_open $$,
  $$ VALUES ('Chicken: Severe → Mild'::text, 'Vet retested: only mild'::text, 'Tanya'::text) $$,
  'And it is waiting for a manager, in words, with the reason');

-- --- 5. Taken off ------------------------------------------------------------------------------------
SELECT throws_ok(
  $$ SELECT remove_allergy((SELECT id FROM t_bison), '  ', '00000000-0000-0000-0000-00000000b002') $$,
  'GR025', 'Bison: taking an allergy off needs a reason', 'Taking one off without a reason is refused');

SELECT lives_ok(
  $$ SELECT remove_allergy((SELECT id FROM t_bison), 'Entered on the wrong dog', '00000000-0000-0000-0000-00000000b002') $$,
  'With a reason it is taken off');

SELECT results_eq(
  $$ SELECT removed_reason, removed_by FROM allergy WHERE id = (SELECT id FROM t_bison) $$,
  $$ VALUES ('Entered on the wrong dog'::text, '00000000-0000-0000-0000-00000000b002'::uuid) $$,
  'And kept on file, marked removed, with who and why');

SELECT is((SELECT count(*) FROM v_change_review_open), 2::bigint, 'And flagged for a manager');

SELECT lives_ok(
  $$ SELECT add_allergy('00000000-0000-0000-0000-00000000d001', 'Bison', 1, NULL, NULL,
                        '00000000-0000-0000-0000-00000000b002') $$,
  'An allergy taken off can be added again');

-- --- 6. A manager's own change -------------------------------------------------------------------------
SELECT lives_ok(
  $$ SELECT update_allergy((SELECT id FROM t_chicken), 1, NULL, 'Only treats with chicken as the first ingredient',
                           '00000000-0000-0000-0000-00000000b001') $$,
  'A note change by anyone needs no reason');

CREATE TEMP TABLE t_luna AS
SELECT add_allergy('00000000-0000-0000-0000-00000000d002', 'Lavender oil', 2, NULL, NULL,
                   '00000000-0000-0000-0000-00000000b001') AS id;
SELECT remove_allergy((SELECT id FROM t_luna), 'Owner confused her with another dog', '00000000-0000-0000-0000-00000000b001');

SELECT is((SELECT count(*) FROM v_change_review_open), 2::bigint,
  'A manager''s own removal is on record but not waiting for review');

-- --- 7. Only a manager reviews ----------------------------------------------------------------------------
SELECT throws_ok(
  $$ SELECT mark_reviewed((SELECT id FROM v_change_review_open LIMIT 1), '00000000-0000-0000-0000-00000000b002') $$,
  'GR026', 'Only a manager can mark a change reviewed', 'A groomer cannot clear the manager''s list');

SELECT mark_reviewed(id, '00000000-0000-0000-0000-00000000b001') FROM v_change_review_open;

SELECT is((SELECT count(*) FROM v_change_review_open), 0::bigint, 'A manager can');

-- --- 8. Handling notes ------------------------------------------------------------------------------------
CREATE TEMP TABLE t_note AS
SELECT add_behavior_note('00000000-0000-0000-0000-00000000d001', 3, 'scissors', 'feet',
                         'Pulls his feet away from the scisors', '00000000-0000-0000-0000-00000000b002') AS id;

SELECT throws_ok(
  $$ SELECT add_behavior_note('00000000-0000-0000-0000-00000000d001', 2, 'dryer', 'wings', NULL,
                              '00000000-0000-0000-0000-00000000b002') $$,
  '23514', 'Unknown body part: wings', 'A body part not in the list is refused');

SELECT is(
  correct_behavior_note((SELECT id FROM t_note), 3, 'scissors', 'feet', 'Pulls his feet away from the scissors',
                        '00000000-0000-0000-0000-00000000b002'),
  '{"note": {"old": "Pulls his feet away from the scisors", "new": "Pulls his feet away from the scissors"}}'::jsonb,
  'A typo in a note is corrected, and only the change is recorded');

SELECT * FROM finish();
ROLLBACK;
