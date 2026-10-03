-- Style template seed — the rules reference/style_tier_mapping.md states,
-- checked against what sql/21_style_template_seed.sql actually loaded.
--
-- This file checks the rules, not the rows. Nothing here re-types the spec's
-- tables: each assertion is a rule the spec states in words (the head is left
-- longer than the body, one length everywhere, the face stays shaved), and
-- the seed has to satisfy it whatever the exact blades turn out to be.
--
-- The rows are a guide, not law: a groomer roughs a Teddy Bear head in with a
-- comb and finishes it with scissors. So the identity rules are the shapes
-- that make a style that style, and no more precise than that.
--
-- Then every template and tier is turned into a real haircut, so the rules
-- that check haircuts rather than seed rows (GR003, GR009, GR010, and GR001
-- for the shave-down) see the seed too.

BEGIN;
SET search_path = groom, public;
-- GR003 is checked at commit, and this file never commits.
SET CONSTRAINTS ALL IMMEDIATE;
SELECT plan(15);

CREATE TEMP VIEW seeded AS
SELECT t.code                    AS template,
       t.supports_tiers,
       t.min_coat_ordinal_required,
       lt.code                   AS tier,
       s.min_coat_ordinal,
       z.code                    AS zone,
       s.body_zone_id,
       s.tool,
       b.number                  AS blade_number,
       s.comb_id,
       derive_effective_length(s.tool, s.blade_id, s.comb_id) AS len
FROM style_template_zone_spec s
JOIN style_template t  ON t.id = s.style_template_id
JOIN body_zone      z  ON z.id = s.body_zone_id
LEFT JOIN length_tier lt ON lt.id = s.length_tier_id
LEFT JOIN blade       b  ON b.id = s.blade_id;

-- --- Shape: every template × tier, every one of its zones ------------------------

SELECT is_empty(
  $$ SELECT t.code, lt.code
       FROM style_template t CROSS JOIN length_tier lt
      WHERE t.supports_tiers
     EXCEPT
     SELECT template, tier FROM seeded $$,
  'Every tiered template has rows at every tier'
);

-- Each template has its own zones, and the groomer is only asked about those.
-- The rule is that a template does not gain or lose a zone between tiers.
SELECT is_empty(
  $$ SELECT s.template, lt.code, s.zone
       FROM (SELECT DISTINCT template, zone FROM seeded WHERE supports_tiers) s
       CROSS JOIN length_tier lt
     EXCEPT
     SELECT template, tier, zone FROM seeded $$,
  'Within a template, every tier covers the same zones'
);

SELECT is_empty(
  $$ SELECT template, tier, zone FROM seeded
      WHERE body_zone_id IN (SELECT body_zone_id FROM zone_default) $$,
  'No template row touches a hygiene zone; those are fixed for everyone'
);

-- The same shape GR009 and GR010 hold a haircut to, held by the seed itself.
SELECT is_empty(
  $$ SELECT template, tier, min_coat_ordinal, zone FROM seeded
      WHERE (supports_tiers     AND (tier IS NULL OR min_coat_ordinal IS NOT NULL))
         OR (NOT supports_tiers AND (tier IS NOT NULL OR min_coat_ordinal IS NULL)) $$,
  'Tiered templates key on tier; the remedial template keys on coat level only'
);

-- --- Spec: "## 5. Shaved — remedial, no tiers" ---------------------------------

SELECT is_empty(
  $$ SELECT template, min_coat_ordinal, zone FROM seeded
      WHERE NOT supports_tiers AND min_coat_ordinal < min_coat_ordinal_required $$,
  'No shave-down row sits below the coat level that justifies a shave-down'
);

SELECT is_empty(
  $$ SELECT lvl.min_coat_ordinal, z.code
       FROM (SELECT DISTINCT min_coat_ordinal FROM seeded WHERE template = 'shaved') lvl
       CROSS JOIN body_zone z
      WHERE z.id NOT IN (SELECT body_zone_id FROM zone_default)
     EXCEPT
     SELECT min_coat_ordinal, zone FROM seeded WHERE template = 'shaved' $$,
  'Each shave-down coat level covers every style zone'
);

-- --- Spec: "## Blade reference" — combs override the blade ----------------------
-- The comb does the work, so it always sits on the shortest blade (#30). And a
-- bare #30 is never a style cut in the spec, which also catches a comb that
-- failed to load.
SELECT is_empty(
  $$ SELECT template, tier, zone, blade_number FROM seeded
      WHERE (comb_id IS NOT NULL AND blade_number <> 30)
         OR (comb_id IS NULL     AND blade_number =  30) $$,
  'Every comb sits on a #30, and no #30 is used without a comb'
);

-- --- Identity rules, one per template ------------------------------------------

-- Spec: "## 1. Teddy Bear" — the head is left longer than the body.
SELECT is_empty(
  $$ SELECT h.tier FROM seeded h
       JOIN seeded b ON b.template = h.template AND b.tier = h.tier AND b.zone = 'body'
      WHERE h.template = 'teddy_bear' AND h.zone = 'head_skull'
        AND NOT (h.len > b.len) $$,
  'Teddy Bear: the head is longer than the body at every tier'
);

-- Spec: "## 2. Poodle (Kennel Trim)" — the face is shaved at every tier.
SELECT is_empty(
  $$ SELECT tier, zone, len FROM seeded
      WHERE template = 'poodle_kennel' AND zone IN ('face', 'muzzle_beard')
        AND (len IS NULL
             OR len > (SELECT length_in FROM blade WHERE number = 10 AND NOT is_finish)) $$,
  'Poodle: face and muzzle are clipped no longer than #10 at every tier'
);

-- Spec: "## 3. Lamb" — the body is shorter than the legs.
SELECT is_empty(
  $$ SELECT l.tier FROM seeded l
       JOIN seeded b ON b.template = l.template AND b.tier = l.tier AND b.zone = 'body'
      WHERE l.template = 'lamb' AND l.zone = 'legs'
        AND NOT (l.len > b.len) $$,
  'Lamb: the legs are longer than the body at every tier'
);

-- Spec: "## 4. Kennel / Puppy" — one length everywhere. A scissored zone has no
-- length, so it would slip past "one length"; every zone must be clipped.
SELECT is_empty(
  $$ SELECT tier FROM seeded
      WHERE template = 'kennel_puppy'
      GROUP BY tier
     HAVING count(DISTINCT len) <> 1 OR bool_or(len IS NULL) $$,
  'Kennel / Puppy: every zone is one clipped length at each tier'
);

-- --- Every template and tier as a real haircut -----------------------------------
-- One visit per haircut (a visit carries at most one). The shave-downs get the
-- coat assessment that justifies them. The fixture dogs have no birth date,
-- so the puppy age rule stays out of it.
CREATE TEMP TABLE seed_haircut (
    cut_specification_id uuid,
    template             text,
    tier                 text,
    coat_level           smallint
);

SELECT lives_ok(
  $do$
  DO $$
  DECLARE
      r       record;
      v_visit uuid;
      v_spec  uuid;
      n       integer := 0;
  BEGIN
      FOR r IN
          SELECT t.code AS template, t.id AS template_id,
                 lt.code AS tier, lt.id AS tier_id, NULL::smallint AS coat_level
            FROM style_template t CROSS JOIN length_tier lt
           WHERE t.supports_tiers
          UNION ALL
          SELECT DISTINCT t.code, s.style_template_id, NULL::text, NULL::uuid, s.min_coat_ordinal
            FROM style_template_zone_spec s
            JOIN style_template t ON t.id = s.style_template_id
           WHERE NOT t.supports_tiers
      LOOP
          n := n + 1;
          INSERT INTO visit (dog_id, performed_by, visit_date)
          VALUES ('00000000-0000-0000-0000-00000000d002',
                  '00000000-0000-0000-0000-00000000b001', CURRENT_DATE - 100 - n)
          RETURNING id INTO v_visit;

          INSERT INTO visit_service (visit_id, service_type_id)
          VALUES (v_visit, (SELECT id FROM service_type WHERE code = 'full_groom'));

          IF r.coat_level IS NOT NULL THEN
              INSERT INTO coat_assessment (dog_id, visit_id, condition_ordinal, density_ordinal)
              VALUES ('00000000-0000-0000-0000-00000000d002', v_visit, r.coat_level, 3);
          END IF;

          INSERT INTO cut_specification
              (visit_id, style_template_id, length_tier_id, coat_ordinal_applied)
          VALUES (v_visit, r.template_id, r.tier_id, r.coat_level)
          RETURNING id INTO v_spec;

          PERFORM resolve_cut_spec_zones(v_spec);

          INSERT INTO seed_haircut VALUES (v_spec, r.template, r.tier, r.coat_level);
      END LOOP;
  END $$
  $do$,
  'Every template at every tier, and every shave-down level, records a haircut (GR001, GR003, GR009, GR010)'
);

-- Every zone the template defines comes through as a template line.
SELECT is_empty(
  $$ SELECT h.template, h.tier, h.coat_level, s.zone
       FROM seed_haircut h
       JOIN seeded s
         ON s.template = h.template
        AND (s.tier = h.tier OR s.min_coat_ordinal = h.coat_level)
     EXCEPT
     SELECT h.template, h.tier, h.coat_level, z.code
       FROM seed_haircut h
       JOIN cut_spec_zone c ON c.cut_specification_id = h.cut_specification_id
       JOIN body_zone     z ON z.id = c.body_zone_id
      WHERE c.resolved_from = 'template' $$,
  'Each haircut carries every zone its template defines'
);

-- Spec: "## Fixed zones — invariant across all templates and tiers".
SELECT is_empty(
  $$ SELECT h.template, h.tier, h.coat_level, d.body_zone_id, d.blade_id
       FROM seed_haircut h CROSS JOIN zone_default d
     EXCEPT
     SELECT h.template, h.tier, h.coat_level, c.body_zone_id, c.blade_id
       FROM seed_haircut h
       JOIN cut_spec_zone c ON c.cut_specification_id = h.cut_specification_id
      WHERE c.resolved_from = 'zone_default' AND c.tool = 'clipper' AND c.comb_id IS NULL $$,
  'The hygiene zones come out the same in every haircut'
);

-- The shave-down rows do not loosen the gate on a shave-down: a coat that is
-- not matted enough is still refused, with the seed in place.
INSERT INTO visit (id, dog_id, performed_by, visit_date) VALUES
  ('00000000-0000-0000-0000-0000000e1901', '00000000-0000-0000-0000-00000000d002',
   '00000000-0000-0000-0000-00000000b001', CURRENT_DATE);
INSERT INTO visit_service (visit_id, service_type_id) VALUES
  ('00000000-0000-0000-0000-0000000e1901', (SELECT id FROM service_type WHERE code = 'full_groom'));
INSERT INTO coat_assessment (dog_id, visit_id, condition_ordinal, density_ordinal) VALUES
  ('00000000-0000-0000-0000-00000000d002', '00000000-0000-0000-0000-0000000e1901', 3, 3);

SELECT throws_ok(
  $$ INSERT INTO cut_specification (visit_id, style_template_id, coat_ordinal_applied)
     VALUES ('00000000-0000-0000-0000-0000000e1901',
             (SELECT id FROM style_template WHERE code = 'shaved'), 3) $$,
  'GR001',
  NULL,
  'A level-3 coat still does not justify a shave-down, seed or no seed'
);

SELECT * FROM finish();
ROLLBACK;
