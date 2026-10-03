-- =============================================================================
-- 21. Style template seed — the template × tier × zone mapping
--
-- Source: reference/style_tier_mapping.md. Each block below names the spec
-- heading it was copied from, and each row is written the way the spec prints
-- it ('#7F', '#30 + 3/4"', 'Scissors') so the two can be read side by side.
--
-- What is NOT here, on purpose:
--   * The hygiene zones (sanitary, feet & pads, inside ears). They are the
--     same for every template and tier, and already live in zone_default
--     (spec: "Fixed zones — invariant across all templates and tiers").
--   * Zones a template's table does not list. Each template carries only the
--     zones that matter to that style; the groomer is not asked about the rest.
--
-- These rows are a guide for the groomer, not a constraint on the haircut.
-- What the groomer actually does is recorded as an override and flagged, never refused.
-- The only rule that checks these rows as they load is the template clamp
-- (GR006); tests/19_style_seed.sql resolves a haircut from every template and
-- tier so GR003, GR009 and GR010 see them too.
-- =============================================================================

SET search_path = groom, public;

-- One row per spec table cell. tier is NULL and coat_level set only for the
-- remedial template, which keys on coat condition instead of tier.
CREATE TEMP TABLE style_seed_row (
    template    text NOT NULL,
    tier        text,
    coat_level  smallint,
    zone        text NOT NULL,
    cut         text NOT NULL
) ON COMMIT PRESERVE ROWS;

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
-- Face and muzzle never pass #10; the schema's clamp on poodle_kennel holds
-- that line, and these rows load through it.
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
-- Lookups are scalar subqueries, not joins, so a misspelt zone, tier or blade
-- fails loudly (NOT NULL or tool CHECK) instead of quietly dropping a row.
-- A misspelt comb would leave a bare #30; tests/19 refuses that shape.
INSERT INTO style_template_zone_spec
    (style_template_id, length_tier_id, min_coat_ordinal, body_zone_id, tool, blade_id, comb_id)
SELECT
    (SELECT id FROM style_template WHERE code = r.template),
    (SELECT id FROM length_tier    WHERE code = r.tier),
    r.coat_level,
    (SELECT id FROM body_zone      WHERE code = r.zone),
    CASE WHEN r.cut = 'Scissors' THEN 'scissors' ELSE 'clipper' END::cutting_tool,
    CASE WHEN r.cut <> 'Scissors' THEN
        (SELECT id FROM blade
          WHERE number    = substring(r.cut FROM '^#(\d+)')::integer
            AND is_finish = (r.cut ~ '^#\d+F'))
    END,
    (SELECT id FROM comb WHERE label = substring(r.cut FROM '\+ (.+)"$') || ' inch comb')
FROM style_seed_row r;

DROP TABLE style_seed_row;
