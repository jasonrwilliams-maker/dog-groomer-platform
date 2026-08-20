-- Template clamps — the split enforcement from resolution_precedence.md §1.
--
-- Seed time (template configuration): BLOCK. A template may not be configured
--   out of its own identity. A fluffy-faced Poodle trim is not a Poodle trim.
-- Haircut time (profile override): FLAG. She is the professional; the system
--   records what she did rather than refusing it.
--
-- The clamp is expressed in inches, not blade numbers, which is what lets it
-- see a comb at all. A blade-number clamp cannot constrain "#30 + 1 inch comb".

BEGIN;
SET search_path = groom, public;
SELECT plan(5);

-- Poodle's face is clamped to a maximum of 1/16 inch by the seed data.
SELECT is(
  (SELECT c.max_effective_length_in
     FROM style_template_zone_clamp c
     JOIN style_template t ON t.id = c.style_template_id
     JOIN body_zone     b ON b.id = c.body_zone_id
    WHERE t.code = 'poodle_kennel' AND b.code = 'face'),
  0.0625::numeric,
  'The Poodle face clamp is stored in inches'
);

-- --- Seed time: blocked ------------------------------------------------------
SELECT throws_ok(
  $$ INSERT INTO style_template_zone_spec
       (style_template_id, length_tier_id, body_zone_id, tool, blade_id, comb_id)
     VALUES
       ((SELECT id FROM style_template WHERE code = 'poodle_kennel'),
        (SELECT id FROM length_tier    WHERE code = 'long'),
        (SELECT id FROM body_zone      WHERE code = 'face'),
        'clipper',
        (SELECT id FROM blade WHERE number = 30),
        (SELECT id FROM comb  WHERE length_in = 1.0)) $$,
  'GR006',
  NULL,
  'A comb on the Poodle face is refused at configuration time'
);

-- The legal configuration goes in fine.
SELECT lives_ok(
  $$ INSERT INTO style_template_zone_spec
       (style_template_id, length_tier_id, body_zone_id, tool, blade_id)
     VALUES
       ((SELECT id FROM style_template WHERE code = 'poodle_kennel'),
        (SELECT id FROM length_tier    WHERE code = 'long'),
        (SELECT id FROM body_zone      WHERE code = 'face'),
        'clipper',
        (SELECT id FROM blade WHERE number = 10)) $$,
  'A #10 face at the Long tier is accepted'
);

-- --- Haircut time: flagged, not blocked -------------------------------------
INSERT INTO dog_style_profile
    (id, dog_id, profile_name, style_template_id, length_tier_id)
VALUES
    ('00000000-0000-0000-0000-0000000abc06',
     '00000000-0000-0000-0000-00000000d003', 'Biscuit poodle long',
     (SELECT id FROM style_template WHERE code = 'poodle_kennel'),
     (SELECT id FROM length_tier    WHERE code = 'long'));

-- The groomer decides this dog gets a longer face anyway.
INSERT INTO profile_zone_override
    (dog_style_profile_id, body_zone_id, tool, blade_id, comb_id, reason)
VALUES
    ('00000000-0000-0000-0000-0000000abc06',
     (SELECT id FROM body_zone WHERE code = 'face'),
     'clipper',
     (SELECT id FROM blade WHERE number = 30),
     (SELECT id FROM comb  WHERE length_in = 1.0),
     'Owner prefers a softer face on this dog');

INSERT INTO visit (id, dog_id, performed_by, visit_date) VALUES
    ('00000000-0000-0000-0000-0000000e0006',
     '00000000-0000-0000-0000-00000000d003',
     '00000000-0000-0000-0000-00000000b001', CURRENT_DATE);

INSERT INTO visit_service (visit_id, service_type_id) VALUES
    ('00000000-0000-0000-0000-0000000e0006',
     (SELECT id FROM service_type WHERE code = 'full_groom'));

INSERT INTO cut_specification
    (id, visit_id, dog_style_profile_id, style_template_id, length_tier_id)
VALUES
    ('00000000-0000-0000-0000-0000000c0006',
     '00000000-0000-0000-0000-0000000e0006',
     '00000000-0000-0000-0000-0000000abc06',
     (SELECT id FROM style_template WHERE code = 'poodle_kennel'),
     (SELECT id FROM length_tier    WHERE code = 'long'));

SELECT lives_ok(
  $$ SELECT resolve_cut_spec_zones('00000000-0000-0000-0000-0000000c0006') $$,
  'The expansion completes: an override violating a clamp is not blocked'
);

SELECT is(
  (SELECT z.clamp_violated FROM cut_spec_zone z
     JOIN body_zone b ON b.id = z.body_zone_id
    WHERE z.cut_specification_id = '00000000-0000-0000-0000-0000000c0006'
      AND b.code = 'face'),
  true,
  'but it is recorded as a clamp violation for the UI to surface'
);

SELECT * FROM finish();
ROLLBACK;
