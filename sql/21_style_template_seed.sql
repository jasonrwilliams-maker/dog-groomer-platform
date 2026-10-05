-- =============================================================================
-- 21. Style templates — every style, its rules, and its cut per zone and tier
--
-- Source: reference/style_tier_mapping.md. Each block below names the spec
-- heading it was copied from, and each cut is written the way the spec prints
-- it ('#7F', '#30 + 3/4"', 'Scissors') so the two can be read side by side.
--
-- This is the one file to edit to change a style. It can be run again on a
-- database that already has it: the styles listed here are replaced as a whole,
-- inside one transaction, so a mistake leaves the old version in place. Past
-- haircuts are not touched; each one keeps its own copy of what was cut.
-- See "Changing a style" in the README.
--
-- What is NOT here, on purpose:
--   * The vocabulary (blades, combs, body zones, length tiers). That lives in
--     section 14 of the schema; add a comb there, then use it here.
--   * The hygiene zones (sanitary, feet & pads, inside ears). They are the
--     same for every template and tier, and live in zone_default
--     (spec: "Fixed zones — invariant across all templates and tiers").
--   * Zones a template's table does not list. Each template carries only the
--     zones that matter to that style; the groomer is not asked about the rest.
--
-- These rows are a guide for the groomer, not a constraint on the haircut.
-- What the groomer actually does is recorded as an override and flagged, never
-- refused. The only rule that checks these rows as they load is the template
-- clamp (GR006); tests/19_style_seed.sql resolves a haircut from every template
-- and tier so GR003, GR009 and GR010 see them too.
-- =============================================================================

SET search_path = groom, public;

BEGIN;

-- --- The styles ------------------------------------------------------------------
-- Re-running updates a style in place, keyed on its code. Removing a line here
-- does not delete a style from a live database: past haircuts point at it.
INSERT INTO style_template
  (code, name, plain_language_description, is_remedial, supports_tiers,
   requires_uniform_length, min_coat_ordinal_required)
VALUES
  ('teddy_bear',   'Teddy Bear',
   'Face left longer than the body; rounded, soft silhouette.',
   false, true, false, NULL),
  ('poodle_kennel','Poodle (Kennel Trim)',
   'Clean-shaved face, feet and tail base; short body; fuller neck and top knot.',
   false, true, false, NULL),
  ('lamb',         'Lamb',
   'Body shorter than legs. The contrast is vertical, not front-to-back.',
   false, true, false, NULL),
  -- requires_uniform_length: GR003 refuses a haircut that resolves to two lengths.
  ('kennel_puppy', 'Kennel / Puppy',
   'One length everywhere. The absence of a differential is the style.',
   false, true, true,  NULL),
  -- Remedial: keyed on coat level, not tier, and refused below level 4 (GR001).
  ('shaved',       'Shaved (remedial)',
   'Not a style. A response to coat condition.',
   true,  false, false, 4)
ON CONFLICT (code) DO UPDATE SET
  name                       = EXCLUDED.name,
  plain_language_description = EXCLUDED.plain_language_description,
  is_remedial                = EXCLUDED.is_remedial,
  supports_tiers             = EXCLUDED.supports_tiers,
  requires_uniform_length    = EXCLUDED.requires_uniform_length,
  min_coat_ordinal_required  = EXCLUDED.min_coat_ordinal_required;

-- One row per spec table cell. tier is NULL and coat_level set only for the
-- remedial template, which keys on coat condition instead of tier.
CREATE TEMP TABLE style_seed_row (
    template    text NOT NULL,
    tier        text,
    coat_level  smallint,
    zone        text NOT NULL,
    cut         text NOT NULL
) ON COMMIT DROP;

-- Clamps: the line a style may not be configured past, in inches, so it also
-- catches a comb. Checked as the cuts below load (GR006).
CREATE TEMP TABLE style_seed_clamp (
    template    text NOT NULL,
    zone        text NOT NULL,
    min_in      numeric,
    max_in      numeric,
    rationale   text NOT NULL
) ON COMMIT DROP;

-- --- Spec: "## 1. Teddy Bear" ------------------------------------------------
-- Head is always longer than the body; that differential is the style.
INSERT INTO style_seed_row (template, tier, zone, cut) VALUES
  ('teddy_bear', 'short',  'body',              '#7F'),
  ('teddy_bear', 'medium', 'body',              '#4F'),
  ('teddy_bear', 'long',   'body',              '#30 + 3/4"'),
  ('teddy_bear', 'short',  'neck',              '#7F'),
  ('teddy_bear', 'medium', 'neck',              '#4F'),
  ('teddy_bear', 'long',   'neck',              '#30 + 3/4"'),
  ('teddy_bear', 'short',  'legs',              '#5F'),
  ('teddy_bear', 'medium', 'legs',              '#4'),
  ('teddy_bear', 'long',   'legs',              '#30 + 1"'),
  ('teddy_bear', 'short',  'head_skull',        '#30 + 3/4"'),
  ('teddy_bear', 'medium', 'head_skull',        '#30 + 1"'),
  ('teddy_bear', 'long',   'head_skull',        '#30 + 1 1/4"'),
  ('teddy_bear', 'short',  'muzzle_beard',      'Scissors'),
  ('teddy_bear', 'medium', 'muzzle_beard',      'Scissors'),
  ('teddy_bear', 'long',   'muzzle_beard',      'Scissors'),
  ('teddy_bear', 'short',  'ears',              '#7F'),
  ('teddy_bear', 'medium', 'ears',              '#4F'),
  ('teddy_bear', 'long',   'ears',              'Scissors'),
  ('teddy_bear', 'short',  'ear_tips',          '#10'),
  ('teddy_bear', 'medium', 'ear_tips',          '#10'),
  ('teddy_bear', 'long',   'ear_tips',          'Scissors'),
  ('teddy_bear', 'short',  'tail',              'Scissors'),
  ('teddy_bear', 'medium', 'tail',              'Scissors'),
  ('teddy_bear', 'long',   'tail',              'Scissors'),
  ('teddy_bear', 'short',  'stomach_underbody', '#10'),
  ('teddy_bear', 'medium', 'stomach_underbody', '#7F'),
  ('teddy_bear', 'long',   'stomach_underbody', '#4F');

-- --- Spec: "## 2. Poodle (Kennel Trim)" -------------------------------------
-- Face and muzzle never pass #10: a shaved face is what makes it a Poodle trim.
INSERT INTO style_seed_clamp (template, zone, max_in, rationale) VALUES
  ('poodle_kennel', 'face',         0.0625,
   'A fluffy-faced Poodle trim is not a Poodle trim; face may not exceed #10.'),
  ('poodle_kennel', 'muzzle_beard', 0.0625,
   'A fluffy-faced Poodle trim is not a Poodle trim; face may not exceed #10.');

INSERT INTO style_seed_row (template, tier, zone, cut) VALUES
  ('poodle_kennel', 'short',  'body',              '#7F'),
  ('poodle_kennel', 'medium', 'body',              '#5'),
  ('poodle_kennel', 'long',   'body',              '#3'),
  ('poodle_kennel', 'short',  'neck',              '#5'),          -- "Neck / mane"
  ('poodle_kennel', 'medium', 'neck',              '#4'),
  ('poodle_kennel', 'long',   'neck',              '#30 + 3/4"'),
  ('poodle_kennel', 'short',  'legs',              '#7F'),
  ('poodle_kennel', 'medium', 'legs',              '#4'),
  ('poodle_kennel', 'long',   'legs',              '#30 + 3/4"'),
  ('poodle_kennel', 'short',  'face',              '#15'),
  ('poodle_kennel', 'medium', 'face',              '#10'),
  ('poodle_kennel', 'long',   'face',              '#10'),
  ('poodle_kennel', 'short',  'muzzle_beard',      '#15'),         -- "Muzzle"
  ('poodle_kennel', 'medium', 'muzzle_beard',      '#10'),
  ('poodle_kennel', 'long',   'muzzle_beard',      '#10'),
  ('poodle_kennel', 'short',  'ears',              'Scissors'),
  ('poodle_kennel', 'medium', 'ears',              'Scissors'),
  ('poodle_kennel', 'long',   'ears',              'Scissors'),
  ('poodle_kennel', 'short',  'top_knot',          'Scissors'),
  ('poodle_kennel', 'medium', 'top_knot',          'Scissors'),
  ('poodle_kennel', 'long',   'top_knot',          'Scissors'),
  ('poodle_kennel', 'short',  'base_of_tail',      '#15'),
  ('poodle_kennel', 'medium', 'base_of_tail',      '#10'),
  ('poodle_kennel', 'long',   'base_of_tail',      '#10'),
  ('poodle_kennel', 'short',  'tail_pom',          'Scissors'),
  ('poodle_kennel', 'medium', 'tail_pom',          'Scissors'),
  ('poodle_kennel', 'long',   'tail_pom',          'Scissors'),
  ('poodle_kennel', 'short',  'stomach_underbody', '#10'),
  ('poodle_kennel', 'medium', 'stomach_underbody', '#10'),
  ('poodle_kennel', 'long',   'stomach_underbody', '#7F');

-- --- Spec: "## 3. Lamb" -------------------------------------------------------
-- Legs always longer than the body. Head stays at 1" for Medium and Long, as
-- the spec prints it.
INSERT INTO style_seed_row (template, tier, zone, cut) VALUES
  ('lamb', 'short',  'body',              '#7F'),
  ('lamb', 'medium', 'body',              '#5'),
  ('lamb', 'long',   'body',              '#4'),
  ('lamb', 'short',  'neck',              '#7F'),
  ('lamb', 'medium', 'neck',              '#5'),
  ('lamb', 'long',   'neck',              '#4'),
  ('lamb', 'short',  'legs',              '#30 + 3/4"'),
  ('lamb', 'medium', 'legs',              '#30 + 1"'),
  ('lamb', 'long',   'legs',              '#30 + 1 1/4"'),
  ('lamb', 'short',  'head_skull',        '#30 + 3/4"'),
  ('lamb', 'medium', 'head_skull',        '#30 + 1"'),
  ('lamb', 'long',   'head_skull',        '#30 + 1"'),
  ('lamb', 'short',  'face',              '#15'),
  ('lamb', 'medium', 'face',              '#10'),
  ('lamb', 'long',   'face',              '#10'),
  ('lamb', 'short',  'ears',              'Scissors'),
  ('lamb', 'medium', 'ears',              'Scissors'),
  ('lamb', 'long',   'ears',              'Scissors'),
  ('lamb', 'short',  'top_knot',          'Scissors'),
  ('lamb', 'medium', 'top_knot',          'Scissors'),
  ('lamb', 'long',   'top_knot',          'Scissors'),
  ('lamb', 'short',  'tail',              'Scissors'),
  ('lamb', 'medium', 'tail',              'Scissors'),
  ('lamb', 'long',   'tail',              'Scissors'),
  ('lamb', 'short',  'stomach_underbody', '#10'),
  ('lamb', 'medium', 'stomach_underbody', '#10'),
  ('lamb', 'long',   'stomach_underbody', '#7F');

-- --- Spec: "## 4. Kennel / Puppy" ---------------------------------------------
-- One length everywhere. The template is marked requires_uniform_length, so
-- GR003 refuses a haircut that resolves to two lengths.
INSERT INTO style_seed_row (template, tier, zone, cut)
SELECT 'kennel_puppy', tier, zone, cut
FROM (VALUES ('short', '#7F'), ('medium', '#4F'), ('long', '#30 + 1"')) AS t(tier, cut)
CROSS JOIN (VALUES ('body'), ('neck'), ('legs'), ('head_skull'), ('muzzle_beard'),
                   ('ears'), ('tail'), ('stomach_underbody')) AS z(zone);

-- --- Spec: "## 5. Shaved — remedial, no tiers" --------------------------------
-- The spec gives one blade per coat level and no zone list, so the blade goes
-- on every style zone; hygiene zones keep their fixed cuts. Nothing here
-- loosens the gate on a shave-down: that is checked on the haircut itself
-- (GR001/GR002), against the coat assessment, not on these rows.
INSERT INTO style_seed_row (template, coat_level, zone, cut)
SELECT 'shaved', lvl.coat_level, z.code, lvl.cut
FROM (VALUES (4::smallint, '#7F'),     -- Level 4: widespread matting
             (5::smallint, '#10'))     -- Level 5: pelted
     AS lvl(coat_level, cut)
CROSS JOIN body_zone z
WHERE NOT EXISTS (SELECT 1 FROM zone_default d WHERE d.body_zone_id = z.id);

-- --- Load ------------------------------------------------------------------------
-- Look every name up first, so a typo stops the load with a message that says
-- which line and what to fix, rather than a bare constraint error.
-- A comb is found by the length it leaves, not by its label.
CREATE TEMP TABLE style_seed_resolved ON COMMIT DROP AS
SELECT r.*,
       (SELECT id FROM style_template WHERE code = r.template) AS template_id,
       (SELECT id FROM length_tier    WHERE code = r.tier)     AS tier_id,
       (SELECT id FROM body_zone      WHERE code = r.zone)     AS zone_id,
       CASE WHEN r.cut = 'Scissors' THEN 'scissors' ELSE 'clipper' END::cutting_tool AS tool,
       (SELECT id FROM blade
         WHERE number    = substring(r.cut FROM '^#(\d+)')::integer
           AND is_finish = (r.cut ~ '^#\d+F'))                AS blade_id,
       c.comb_text,
       (SELECT id FROM comb
         WHERE length_in =
               COALESCE(substring(c.comb_text FROM '^(\d+)(?: |$)')::numeric, 0)
             + COALESCE(substring(c.comb_text FROM '(\d+)/\d+$')::numeric
                        / substring(c.comb_text FROM '/(\d+)$')::numeric, 0)) AS comb_id
FROM style_seed_row r
CROSS JOIN LATERAL (SELECT substring(r.cut FROM '\+ (.+)"$') AS comb_text) c;

DO $$
DECLARE
    bad record;
BEGIN
    FOR bad IN
        SELECT * FROM style_seed_resolved
         WHERE template_id IS NULL OR zone_id IS NULL
            OR (tier IS NOT NULL AND tier_id IS NULL)
            OR (tool = 'clipper' AND blade_id IS NULL)
            OR (comb_text IS NOT NULL AND comb_id IS NULL)
         LIMIT 1
    LOOP
        RAISE EXCEPTION 'Style seed: cannot read % / % / % : "%"',
            bad.template, COALESCE(bad.tier, 'coat level ' || bad.coat_level), bad.zone, bad.cut
            USING HINT = CASE
                WHEN bad.template_id IS NULL THEN 'Unknown style; add it to the style list at the top of this file.'
                WHEN bad.zone_id     IS NULL THEN 'Unknown zone; zones live in body_zone (schema section 14).'
                WHEN bad.tier_id     IS NULL AND bad.tier IS NOT NULL
                                             THEN 'Unknown length tier; tiers live in length_tier (schema section 14).'
                WHEN bad.blade_id    IS NULL THEN 'Unknown blade; write it as #7, #7F, ... and check blade (schema section 14).'
                ELSE 'No comb leaves that length; add one to comb (schema section 14).' END;
    END LOOP;
END $$;

-- Replace the listed styles' cuts and clamps as a whole. Clamps go in first,
-- because the clamp check (GR006) reads them as each cut loads.
DELETE FROM style_template_zone_spec
 WHERE style_template_id IN (SELECT DISTINCT template_id FROM style_seed_resolved);
DELETE FROM style_template_zone_clamp
 WHERE style_template_id IN (SELECT DISTINCT template_id FROM style_seed_resolved);

INSERT INTO style_template_zone_clamp
    (style_template_id, body_zone_id, min_effective_length_in, max_effective_length_in, rationale)
SELECT (SELECT id FROM style_template WHERE code = k.template),
       (SELECT id FROM body_zone      WHERE code = k.zone),
       k.min_in, k.max_in, k.rationale
FROM style_seed_clamp k;

INSERT INTO style_template_zone_spec
    (style_template_id, length_tier_id, min_coat_ordinal, body_zone_id, tool, blade_id, comb_id)
SELECT template_id, tier_id, coat_level, zone_id, tool,
       CASE WHEN tool = 'clipper' THEN blade_id END, comb_id
FROM style_seed_resolved;

COMMIT;
