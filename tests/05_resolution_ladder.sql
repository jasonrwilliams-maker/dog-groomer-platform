-- Resolution precedence — resolution_precedence.md §1 turned into assertions.
--
-- Every zone resolves independently and the first rule that matches wins:
--   1. profile_zone_override   2. style_template_zone_spec
--   3. zone_default            4. unresolved (zone simply omitted)
-- An ad hoc visit-time edit sits above all four and survives re-expansion.
--
-- The template rows are created inside this transaction rather than read from a
-- seed migration, so this file proves the ladder regardless of what the seed
-- data eventually says.

BEGIN;
SET search_path = groom, public;
SELECT plan(12);

-- --- Template configuration: Teddy Bear / Medium, three zones ----------------
INSERT INTO style_template_zone_spec
    (style_template_id, length_tier_id, body_zone_id, tool, blade_id)
VALUES
    ((SELECT id FROM style_template WHERE code = 'teddy_bear'),
     (SELECT id FROM length_tier    WHERE code = 'medium'),
     (SELECT id FROM body_zone      WHERE code = 'body'),
     'clipper', (SELECT id FROM blade WHERE number = 4 AND is_finish)),
    ((SELECT id FROM style_template WHERE code = 'teddy_bear'),
     (SELECT id FROM length_tier    WHERE code = 'medium'),
     (SELECT id FROM body_zone      WHERE code = 'ears'),
     'clipper', (SELECT id FROM blade WHERE number = 4 AND is_finish));

-- Head goes under a comb: a #30 blade with a 1" comb cuts at 1".
INSERT INTO style_template_zone_spec
    (style_template_id, length_tier_id, body_zone_id, tool, blade_id, comb_id)
VALUES
    ((SELECT id FROM style_template WHERE code = 'teddy_bear'),
     (SELECT id FROM length_tier    WHERE code = 'medium'),
     (SELECT id FROM body_zone      WHERE code = 'head_skull'),
     'clipper',
     (SELECT id FROM blade WHERE number = 30),
     (SELECT id FROM comb  WHERE length_in = 1.0));

-- --- Luna's saved profile, with one deviation -------------------------------
INSERT INTO dog_style_profile
    (id, dog_id, profile_name, style_template_id, length_tier_id, is_default)
VALUES
    ('00000000-0000-0000-0000-0000000abc05',
     '00000000-0000-0000-0000-00000000d002', 'Luna standard',
     (SELECT id FROM style_template WHERE code = 'teddy_bear'),
     (SELECT id FROM length_tier    WHERE code = 'medium'), true);

INSERT INTO profile_zone_override
    (dog_style_profile_id, body_zone_id, tool, reason)
VALUES
    ('00000000-0000-0000-0000-0000000abc05',
     (SELECT id FROM body_zone WHERE code = 'ears'),
     'scissors', 'Luna''s ears are always scissored');

-- --- A groom visit, and the expansion ---------------------------------------
INSERT INTO visit (id, dog_id, performed_by, visit_date) VALUES
    ('00000000-0000-0000-0000-0000000e0005',
     '00000000-0000-0000-0000-00000000d002',
     '00000000-0000-0000-0000-00000000b001', CURRENT_DATE);

INSERT INTO visit_service (visit_id, service_type_id) VALUES
    ('00000000-0000-0000-0000-0000000e0005',
     (SELECT id FROM service_type WHERE code = 'full_groom'));

INSERT INTO cut_specification
    (id, visit_id, dog_style_profile_id, style_template_id, length_tier_id)
VALUES
    ('00000000-0000-0000-0000-0000000c0005',
     '00000000-0000-0000-0000-0000000e0005',
     '00000000-0000-0000-0000-0000000abc05',
     (SELECT id FROM style_template WHERE code = 'teddy_bear'),
     (SELECT id FROM length_tier    WHERE code = 'medium'));

SELECT resolve_cut_spec_zones('00000000-0000-0000-0000-0000000c0005');

-- Three template zones plus three hygiene defaults. Ears appears in both the
-- template and the override, so it is one zone, not two.
SELECT is(
  (SELECT count(*) FROM cut_spec_zone
    WHERE cut_specification_id = '00000000-0000-0000-0000-0000000c0005'),
  6::bigint,
  'Six zones resolve: three from the template, three hygiene defaults'
);

-- --- Level 1 beats level 2 --------------------------------------------------
SELECT is(
  (SELECT z.resolved_from FROM cut_spec_zone z
     JOIN body_zone b ON b.id = z.body_zone_id
    WHERE z.cut_specification_id = '00000000-0000-0000-0000-0000000c0005'
      AND b.code = 'ears'),
  'profile_override',
  'Ears come from the profile override, not the template'
);

SELECT is(
  (SELECT z.tool::text FROM cut_spec_zone z
     JOIN body_zone b ON b.id = z.body_zone_id
    WHERE z.cut_specification_id = '00000000-0000-0000-0000-0000000c0005'
      AND b.code = 'ears'),
  'scissors',
  'and the override tool wins over the template blade'
);

SELECT is(
  (SELECT z.effective_length_in FROM cut_spec_zone z
     JOIN body_zone b ON b.id = z.body_zone_id
    WHERE z.cut_specification_id = '00000000-0000-0000-0000-0000000c0005'
      AND b.code = 'ears'),
  NULL::numeric,
  'Scissors specify no length'
);

SELECT is(
  (SELECT z.was_override FROM cut_spec_zone z
     JOIN body_zone b ON b.id = z.body_zone_id
    WHERE z.cut_specification_id = '00000000-0000-0000-0000-0000000c0005'
      AND b.code = 'ears'),
  true,
  'and the row is marked as an override'
);

-- --- Level 2 beats level 3 --------------------------------------------------
SELECT is(
  (SELECT z.resolved_from FROM cut_spec_zone z
     JOIN body_zone b ON b.id = z.body_zone_id
    WHERE z.cut_specification_id = '00000000-0000-0000-0000-0000000c0005'
      AND b.code = 'body'),
  'template',
  'Body comes from the template'
);

SELECT is(
  (SELECT z.effective_length_in FROM cut_spec_zone z
     JOIN body_zone b ON b.id = z.body_zone_id
    WHERE z.cut_specification_id = '00000000-0000-0000-0000-0000000c0005'
      AND b.code = 'body'),
  0.375::numeric,
  'A #4F resolves to 3/8 inch'
);

-- --- Level 3: the hygiene invariant, untouched by style ---------------------
SELECT is(
  (SELECT z.resolved_from FROM cut_spec_zone z
     JOIN body_zone b ON b.id = z.body_zone_id
    WHERE z.cut_specification_id = '00000000-0000-0000-0000-0000000c0005'
      AND b.code = 'sanitary'),
  'zone_default',
  'Sanitary comes from the zone default even though the template never mentions it'
);

SELECT is(
  (SELECT z.effective_length_in FROM cut_spec_zone z
     JOIN body_zone b ON b.id = z.body_zone_id
    WHERE z.cut_specification_id = '00000000-0000-0000-0000-0000000c0005'
      AND b.code = 'sanitary'),
  0.0625::numeric,
  'and it is always a #10'
);

-- --- The comb always wins ---------------------------------------------------
SELECT is(
  (SELECT z.effective_length_in FROM cut_spec_zone z
     JOIN body_zone b ON b.id = z.body_zone_id
    WHERE z.cut_specification_id = '00000000-0000-0000-0000-0000000c0005'
      AND b.code = 'head_skull'),
  1.0::numeric,
  'A #30 under a 1 inch comb cuts at 1 inch, not 1/50'
);

SELECT is(
  (SELECT z.resolved_label FROM cut_spec_zone z
     JOIN body_zone b ON b.id = z.body_zone_id
    WHERE z.cut_specification_id = '00000000-0000-0000-0000-0000000c0005'
      AND b.code = 'head_skull'),
  '#30 + 1 inch comb',
  'and the label records both'
);

-- --- Ad hoc edits sit above all four and survive re-expansion ---------------
INSERT INTO cut_spec_zone
    (cut_specification_id, body_zone_id, tool, resolved_label, resolved_from, note)
VALUES
    ('00000000-0000-0000-0000-0000000c0005',
     (SELECT id FROM body_zone WHERE code = 'tail'),
     'scissors', '', 'ad_hoc', 'Owner asked for the tail left long today only');

SELECT resolve_cut_spec_zones('00000000-0000-0000-0000-0000000c0005');

SELECT is(
  (SELECT count(*) FROM cut_spec_zone
    WHERE cut_specification_id = '00000000-0000-0000-0000-0000000c0005'
      AND resolved_from = 'ad_hoc'),
  1::bigint,
  'A visit-time ad hoc edit survives re-running the expansion'
);

SELECT * FROM finish();
ROLLBACK;
