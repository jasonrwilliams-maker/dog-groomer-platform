-- Recording the haircut at the end of a groom.
--
-- Seven things are proven:
--   1. The plan the screen shows is exactly what gets recorded.
--   2. Today's changes are the visit's own; one that breaks the style's
--      identity is flagged, never refused.
--   3. Keeping today's cut as the usual style: the next plan starts from it,
--      and the change is in the audit log, before and after, with the reason.
--   4. A cut different from the usual says why (GR034).
--   5. A pelted coat is shaved only once the owner has been told (GR033).
--   6. A haircut the rules would stop goes ahead with a manager's OK, and
--      only a manager's (GR035): a shave-down the coat doesn't justify, a puppy.
--   7. Finishing the groom sends the dog home, once.

BEGIN;
SET search_path = groom, public;
SELECT plan(25);

-- Tanya grooms, Nadia manages (fixture). Luna and Biscuit are the fixture's.
CREATE FUNCTION pg_temp.visit(p_dog uuid, p_days_ago int) RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO visit (dog_id, performed_by, visit_date, check_in)
  VALUES (p_dog, '00000000-0000-0000-0000-00000000b002', CURRENT_DATE - p_days_ago, '09:00')
  RETURNING id $$;
CREATE FUNCTION pg_temp.groom(p_visit uuid) RETURNS void LANGUAGE sql AS $$
  SELECT record_visit_services(p_visit, ARRAY['full_groom', 'bath']) $$;
CREATE FUNCTION pg_temp.cut(p_spec uuid, p_zone text) RETURNS text LANGUAGE sql AS $$
  SELECT z.resolved_label FROM cut_spec_zone z JOIN body_zone bz ON bz.id = z.body_zone_id
   WHERE z.cut_specification_id = p_spec AND bz.code = p_zone $$;
CREATE FUNCTION pg_temp.tool(p_label text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT CASE WHEN p_label = 'Scissors' THEN jsonb_build_object('tool', 'scissors')
              ELSE jsonb_build_object('tool', 'clipper',
                     'blade_id', (SELECT id FROM blade WHERE '#' || number || CASE WHEN is_finish THEN 'F' ELSE '' END = p_label))
         END $$;

CREATE TEMP TABLE t AS SELECT
  pg_temp.visit('00000000-0000-0000-0000-00000000d002', 60) AS luna1,
  pg_temp.visit('00000000-0000-0000-0000-00000000d002', 30) AS luna2,
  pg_temp.visit('00000000-0000-0000-0000-00000000d002', 1)  AS luna3,
  pg_temp.visit('00000000-0000-0000-0000-00000000d003', 20) AS biscuit1,
  pg_temp.visit('00000000-0000-0000-0000-00000000d003', 10) AS biscuit2,
  pg_temp.visit('00000000-0000-0000-0000-00000000d003', 5)  AS biscuit3;
SELECT pg_temp.groom(v) FROM t, unnest(ARRAY[luna1, luna2, luna3, biscuit1, biscuit2, biscuit3]) v;

-- --- 1. The plan is what gets recorded -------------------------------------------------------------
SELECT results_eq(
  $$ SELECT zone_code, cut, source FROM haircut_plan('00000000-0000-0000-0000-00000000d002', 'teddy_bear', 'medium', NULL)
      WHERE zone_code IN ('body', 'ears', 'sanitary') ORDER BY display_order $$,
  $$ VALUES ('body'::text, '#4F'::text, 'style'::text), ('ears', '#4F', 'style'), ('sanitary', '#10', 'hygiene') $$,
  'The plan for a Teddy Bear, medium: the style''s cuts, and the hygiene zones');

CREATE TEMP TABLE spec AS SELECT record_haircut((SELECT luna1 FROM t), '00000000-0000-0000-0000-00000000b002',
  'teddy_bear', 'medium', '[]', NULL, NULL, NULL, false) AS luna1;

SELECT set_eq(
  $$ SELECT bz.code, z.resolved_label FROM cut_spec_zone z JOIN body_zone bz ON bz.id = z.body_zone_id
      WHERE z.cut_specification_id = (SELECT luna1 FROM spec) $$,
  $$ SELECT zone_code, cut FROM haircut_plan('00000000-0000-0000-0000-00000000d002', 'teddy_bear', 'medium', NULL) $$,
  'A haircut with no changes is recorded exactly as planned');
SELECT is((SELECT deviated_from_profile FROM cut_specification WHERE id = (SELECT luna1 FROM spec)), false,
  'With no usual style yet, nothing is "different from the usual"');

-- --- 2. Today's changes ------------------------------------------------------------------------------
ALTER TABLE spec ADD COLUMN biscuit1 uuid;
UPDATE spec SET biscuit1 = record_haircut((SELECT biscuit1 FROM t), '00000000-0000-0000-0000-00000000b002',
  'poodle_kennel', 'short',
  jsonb_build_array(pg_temp.tool('#4F') || '{"zone": "face"}', pg_temp.tool('#5') || '{"zone": "body"}'),
  NULL, NULL, NULL, false);
SELECT is(pg_temp.cut((SELECT biscuit1 FROM spec), 'face'), '#4F', 'A change made today is what was cut');
SELECT results_eq(
  $$ SELECT bz.code, z.resolved_from, z.clamp_violated FROM cut_spec_zone z JOIN body_zone bz ON bz.id = z.body_zone_id
      WHERE z.cut_specification_id = (SELECT biscuit1 FROM spec) AND bz.code IN ('body', 'face') ORDER BY bz.code $$,
  $$ VALUES ('body'::text, 'ad_hoc'::text, false), ('face', 'ad_hoc', true) $$,
  'Both are the visit''s own; a fluffy Poodle face is flagged, not refused');
SELECT is(pg_temp.cut((SELECT biscuit1 FROM spec), 'muzzle_beard'), '#15', 'The rest still comes from the style');

-- --- 3. Keeping it as the usual style ----------------------------------------------------------------
ALTER TABLE spec ADD COLUMN luna2 uuid;
UPDATE spec SET luna2 = record_haircut((SELECT luna2 FROM t), '00000000-0000-0000-0000-00000000b002',
  'teddy_bear', 'medium', jsonb_build_array(pg_temp.tool('Scissors') || '{"zone": "ears"}'), NULL, NULL, NULL, false);
SELECT save_usual_style((SELECT luna2 FROM spec), '00000000-0000-0000-0000-00000000b002', 'Owner likes fluffy ears');

SELECT results_eq(
  $$ SELECT zone_code, cut, source FROM haircut_plan('00000000-0000-0000-0000-00000000d002', 'teddy_bear', 'medium', NULL)
      WHERE zone_code IN ('body', 'ears') ORDER BY display_order $$,
  $$ VALUES ('body'::text, '#4F'::text, 'style'::text), ('ears', 'Scissors', 'usual') $$,
  'The next plan starts from the usual style, its change included');
SELECT is((SELECT cut FROM haircut_plan('00000000-0000-0000-0000-00000000d002', 'lamb', 'medium', NULL) WHERE zone_code = 'ears'),
  'Scissors', 'A different style starts clean (the Lamb''s own ears)');
SELECT is(
  (SELECT changed_fields - 'before' FROM audit_log WHERE entity_type = 'dog_style_profile' ORDER BY occurred_at DESC LIMIT 1),
  jsonb_build_object('after', jsonb_build_object('style', 'Teddy Bear', 'length', 'medium',
                       'changes', jsonb_build_array(jsonb_build_object('zone', 'Ears', 'cut', 'Scissors'))),
                     'reason', 'Owner likes fluffy ears'),
  'Keeping it as the usual is in the audit log, with the reason');
SELECT save_usual_style((SELECT luna2 FROM spec), '00000000-0000-0000-0000-00000000b002', NULL);
SELECT is((SELECT count(*)::int FROM audit_log WHERE entity_type = 'dog_style_profile'), 1,
  'Keeping the same cut again records nothing new');

-- --- 4. Different from the usual: say why ------------------------------------------------------------
SELECT throws_ok(
  $$ SELECT record_haircut((SELECT luna3 FROM t), '00000000-0000-0000-0000-00000000b002',
       'teddy_bear', 'short', '[]', '  ', NULL, NULL, false) $$,
  'GR034', NULL, 'A shorter length than the usual, with no reason, is refused');
SELECT lives_ok(
  $$ CREATE TEMP TABLE luna3 AS SELECT record_haircut((SELECT luna3 FROM t), '00000000-0000-0000-0000-00000000b002',
       'teddy_bear', 'short', '[]', 'Owner asked for shorter for summer', NULL, NULL, false) AS id $$,
  'With a reason it is recorded');
SELECT results_eq(
  $$ SELECT deviated_from_profile, deviation_reason FROM cut_specification WHERE id = (SELECT id FROM luna3) $$,
  $$ VALUES (true, 'Owner asked for shorter for summer'::text) $$,
  'And the haircut says it was different, and why');
SELECT is(pg_temp.cut((SELECT id FROM luna3), 'ears'), 'Scissors', 'The usual change still applies at a new length');

-- --- 5. A pelted coat -----------------------------------------------------------------------------------
SELECT record_coat((SELECT biscuit2 FROM t), '00000000-0000-0000-0000-00000000b002', 5::smallint, 4::smallint, 'Pelted to the skin');
SELECT throws_ok(
  $$ SELECT record_haircut((SELECT biscuit2 FROM t), '00000000-0000-0000-0000-00000000b002',
       'shaved', NULL, '[]', NULL, NULL, NULL, false) $$,
  'GR033', NULL, 'Shaving a pelted coat before the owner is told is refused');
SELECT lives_ok(
  $$ CREATE TEMP TABLE shave AS SELECT record_haircut((SELECT biscuit2 FROM t), '00000000-0000-0000-0000-00000000b002',
       'shaved', NULL, '[]', NULL, NULL, NULL, true) AS id $$,
  'Once she says the owner was told, it is recorded');
SELECT results_eq(
  $$ SELECT pg_temp.cut(id, 'body'), pg_temp.cut(id, 'sanitary'),
            (SELECT shave_acknowledged_by FROM cut_specification c WHERE c.id = shave.id) FROM shave $$,
  $$ VALUES ('#10'::text, '#10'::text, '00000000-0000-0000-0000-00000000b002'::uuid) $$,
  'A level-5 shave is #10 all over, and it says who told the owner');
SELECT throws_ok(
  $$ SELECT save_usual_style((SELECT id FROM shave), '00000000-0000-0000-0000-00000000b002', NULL) $$,
  'GR008', NULL, 'A shave-down is never kept as the usual style');

-- --- 6. A manager's OK ----------------------------------------------------------------------------------
SELECT record_coat((SELECT biscuit3 FROM t), '00000000-0000-0000-0000-00000000b002', 2::smallint, 3::smallint, NULL);
SELECT throws_ok(
  $$ SELECT record_haircut((SELECT biscuit3 FROM t), '00000000-0000-0000-0000-00000000b002',
       'shaved', NULL, '[]', NULL, NULL, NULL, false) $$,
  'GR001', NULL, 'A shave-down a level-2 coat doesn''t justify is refused');
SELECT throws_ok(
  $$ SELECT record_haircut((SELECT biscuit3 FROM t), '00000000-0000-0000-0000-00000000b002',
       'shaved', NULL, '[]', NULL, 'Owner wants it all off for the summer', '00000000-0000-0000-0000-00000000b002', false) $$,
  'GR035', NULL, 'A groomer cannot OK it');
SELECT is(
  pg_temp.cut(record_haircut((SELECT biscuit3 FROM t), '00000000-0000-0000-0000-00000000b002',
       'shaved', NULL, '[]', NULL, 'Owner wants it all off for the summer', '00000000-0000-0000-0000-00000000b001', false), 'body'),
  '#7F', 'A manager can, and the shave is the gentler #7F');

UPDATE dog SET date_of_birth = CURRENT_DATE - 70 WHERE id = '00000000-0000-0000-0000-00000000d001';
CREATE TEMP TABLE pup AS SELECT pg_temp.visit('00000000-0000-0000-0000-00000000d001', 0) AS id;
SELECT pg_temp.groom(id) FROM pup;
SELECT throws_ok(
  $$ SELECT record_haircut((SELECT id FROM pup), '00000000-0000-0000-0000-00000000b002',
       'kennel_puppy', 'short', '[]', NULL, NULL, NULL, false) $$,
  'GR011', NULL, 'A ten-week-old puppy''s haircut with no reason is refused');
CREATE TEMP TABLE pup_cut AS SELECT record_haircut((SELECT id FROM pup),
  '00000000-0000-0000-0000-00000000b002', 'kennel_puppy', 'short', '[]', NULL,
  'Face and feet tidy only, owner asked', '00000000-0000-0000-0000-00000000b001', false) AS id;
SELECT is(
  (SELECT under_age_override_reason FROM cut_specification WHERE id = (SELECT id FROM pup_cut)),
  'Face and feet tidy only, owner asked', 'With a reason and a manager''s OK it is recorded, reason on the haircut');

-- --- 7. Going home ----------------------------------------------------------------------------------------
SELECT finish_visit((SELECT luna3 FROM t), '00000000-0000-0000-0000-00000000b002', 'Good girl. Shorter for summer.');
SELECT results_eq(
  $$ SELECT check_out IS NOT NULL, overall_note FROM visit WHERE id = (SELECT luna3 FROM t) $$,
  $$ VALUES (true, 'Good girl. Shorter for summer.'::text) $$,
  'Finishing sends the dog home, with the note for next time');
SELECT throws_ok(
  $$ SELECT finish_visit((SELECT luna3 FROM t), '00000000-0000-0000-0000-00000000b002', NULL) $$,
  NULL, 'This groom is already finished, or there is no such visit', 'A groom is finished once');

SELECT * FROM finish();
ROLLBACK;
