-- Invariant 3.1 — a shave-down requires a coat assessment at level 4 or higher.
-- This is the record that protects the groomer in the "you shaved my dog"
-- conversation, so the refusal is the feature.

BEGIN;
SET search_path = groom, public;
SELECT plan(3);

-- A full-groom visit for Luna with a level-2 coat: mildly tangled, not matted.
INSERT INTO visit (id, dog_id, performed_by, visit_date) VALUES
  ('00000000-0000-0000-0000-0000000e0001',
   '00000000-0000-0000-0000-00000000d002',
   '00000000-0000-0000-0000-00000000b001', CURRENT_DATE);

INSERT INTO visit_service (visit_id, service_type_id) VALUES
  ('00000000-0000-0000-0000-0000000e0001',
   (SELECT id FROM service_type WHERE code = 'full_groom'));

INSERT INTO coat_assessment (dog_id, visit_id, condition_ordinal, density_ordinal) VALUES
  ('00000000-0000-0000-0000-00000000d002',
   '00000000-0000-0000-0000-0000000e0001', 2, 3);

SELECT throws_ok(
  $$ INSERT INTO cut_specification (visit_id, style_template_id, coat_ordinal_applied)
     VALUES ('00000000-0000-0000-0000-0000000e0001',
             (SELECT id FROM style_template WHERE code = 'shaved'), 2) $$,
  'GR001',
  NULL,
  'A level-2 coat does not justify a shave-down'
);

SELECT is(
  (SELECT count(*) FROM cut_specification
    WHERE visit_id = '00000000-0000-0000-0000-0000000e0001'),
  0::bigint,
  'and nothing was written'
);

-- The same shave-down at level 5 is exactly what the template is for.
UPDATE coat_assessment SET condition_ordinal = 5
 WHERE visit_id = '00000000-0000-0000-0000-0000000e0001';

SELECT lives_ok(
  $$ INSERT INTO cut_specification (visit_id, style_template_id, coat_ordinal_applied)
     VALUES ('00000000-0000-0000-0000-0000000e0001',
             (SELECT id FROM style_template WHERE code = 'shaved'), 5) $$,
  'A pelted coat at level 5 is accepted'
);

SELECT * FROM finish();
ROLLBACK;
