-- Snapshot immutability — the claim the schema header makes most loudly:
--
--   "Configuration is live; history is a snapshot."
--
-- Correcting blade.length_in next year must not silently rewrite what happened
-- in March. But a genuine correction to the haircut row itself SHOULD recompute
-- — the row is frozen against reference-data drift, not against being fixed.

BEGIN;
SET search_path = groom, public;
SELECT plan(6);

INSERT INTO style_template_zone_spec
    (style_template_id, length_tier_id, body_zone_id, tool, blade_id)
VALUES
    ((SELECT id FROM style_template WHERE code = 'teddy_bear'),
     (SELECT id FROM length_tier    WHERE code = 'medium'),
     (SELECT id FROM body_zone      WHERE code = 'body'),
     'clipper', (SELECT id FROM blade WHERE number = 4 AND is_finish));

INSERT INTO visit (id, dog_id, performed_by, visit_date) VALUES
    ('00000000-0000-0000-0000-0000000e0007',
     '00000000-0000-0000-0000-00000000d002',
     '00000000-0000-0000-0000-00000000b001', CURRENT_DATE);

INSERT INTO visit_service (visit_id, service_type_id) VALUES
    ('00000000-0000-0000-0000-0000000e0007',
     (SELECT id FROM service_type WHERE code = 'full_groom'));

INSERT INTO cut_specification
    (id, visit_id, style_template_id, length_tier_id)
VALUES
    ('00000000-0000-0000-0000-0000000c0007',
     '00000000-0000-0000-0000-0000000e0007',
     (SELECT id FROM style_template WHERE code = 'teddy_bear'),
     (SELECT id FROM length_tier    WHERE code = 'medium'));

SELECT resolve_cut_spec_zones('00000000-0000-0000-0000-0000000c0007');

SELECT is(
  (SELECT z.effective_length_in FROM cut_spec_zone z
     JOIN body_zone b ON b.id = z.body_zone_id
    WHERE z.cut_specification_id = '00000000-0000-0000-0000-0000000c0007'
      AND b.code = 'body'),
  0.375::numeric,
  'The haircut is recorded at 3/8 inch'
);

SELECT is(
  (SELECT z.resolved_label FROM cut_spec_zone z
     JOIN body_zone b ON b.id = z.body_zone_id
    WHERE z.cut_specification_id = '00000000-0000-0000-0000-0000000c0007'
      AND b.code = 'body'),
  '#4F',
  'with a human-readable label alongside it'
);

-- Someone corrects the blade reference table a year later.
UPDATE blade SET length_in = 0.999 WHERE number = 4 AND is_finish;

SELECT is(
  (SELECT z.effective_length_in FROM cut_spec_zone z
     JOIN body_zone b ON b.id = z.body_zone_id
    WHERE z.cut_specification_id = '00000000-0000-0000-0000-0000000c0007'
      AND b.code = 'body'),
  0.375::numeric,
  'History does not move: the recorded haircut is still 3/8 inch'
);

-- ...but the configuration view, which derives live, does move.
SELECT is(
  (SELECT v.effective_length_in FROM v_style_template_zone_spec v
    WHERE v.template_code = 'teddy_bear'
      AND v.tier_code     = 'medium'
      AND v.zone_code     = 'body'),
  0.999::numeric,
  'Configuration does move: the template now reads the corrected length'
);

-- A genuine correction to the haircut row itself is a different thing, and it
-- SHOULD recompute. She used a #7F, not a #4F.
UPDATE cut_spec_zone z
   SET blade_id = (SELECT id FROM blade WHERE number = 7 AND is_finish)
  FROM body_zone b
 WHERE b.id = z.body_zone_id
   AND z.cut_specification_id = '00000000-0000-0000-0000-0000000c0007'
   AND b.code = 'body';

SELECT is(
  (SELECT z.effective_length_in FROM cut_spec_zone z
     JOIN body_zone b ON b.id = z.body_zone_id
    WHERE z.cut_specification_id = '00000000-0000-0000-0000-0000000c0007'
      AND b.code = 'body'),
  0.125::numeric,
  'Correcting the row itself recomputes the length'
);

SELECT is(
  (SELECT z.resolved_label FROM cut_spec_zone z
     JOIN body_zone b ON b.id = z.body_zone_id
    WHERE z.cut_specification_id = '00000000-0000-0000-0000-0000000c0007'
      AND b.code = 'body'),
  '#7F',
  'and the label with it'
);

SELECT * FROM finish();
ROLLBACK;
