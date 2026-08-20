-- Invariant 3.7 — a tiered template saved without a tier expands against no
-- template rows, producing a haircut record of hygiene zones and nothing else.
-- This is the newest invariant, so it is the least proven.

BEGIN;
SET search_path = groom, public;
SELECT plan(3);

INSERT INTO visit (id, dog_id, performed_by, visit_date) VALUES
  ('00000000-0000-0000-0000-0000000e0002',
   '00000000-0000-0000-0000-00000000d002',
   '00000000-0000-0000-0000-00000000b001', CURRENT_DATE);

INSERT INTO visit_service (visit_id, service_type_id) VALUES
  ('00000000-0000-0000-0000-0000000e0002',
   (SELECT id FROM service_type WHERE code = 'full_groom'));

SELECT throws_ok(
  $$ INSERT INTO cut_specification (visit_id, style_template_id)
     VALUES ('00000000-0000-0000-0000-0000000e0002',
             (SELECT id FROM style_template WHERE code = 'teddy_bear')) $$,
  'GR009',
  NULL,
  'Teddy Bear without a length tier is refused'
);

SELECT lives_ok(
  $$ INSERT INTO cut_specification (visit_id, style_template_id, length_tier_id)
     VALUES ('00000000-0000-0000-0000-0000000e0002',
             (SELECT id FROM style_template WHERE code = 'teddy_bear'),
             (SELECT id FROM length_tier WHERE code = 'medium')) $$,
  'Teddy Bear Medium is accepted'
);

-- Shaved is a response to a coat, not a standing preference.
SELECT throws_ok(
  $$ INSERT INTO dog_style_profile (dog_id, profile_name, style_template_id)
     VALUES ('00000000-0000-0000-0000-00000000d002', 'Luna default',
             (SELECT id FROM style_template WHERE code = 'shaved')) $$,
  'GR008',
  NULL,
  'A remedial template cannot be saved as a style profile'
);

SELECT * FROM finish();
ROLLBACK;
