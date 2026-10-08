-- =============================================================================
-- 32. Record the haircut
--
-- Until now a groom was started at the counter and never finished: the screen
-- said "Being groomed" and that was the end of it. The styling half of the
-- schema (sections 4–6 and 12) has been able to hold a haircut since the
-- beginning, but nothing on the screen wrote one.
--
-- Finishing a groom is one step at the end of the visit, all or nothing:
--
--   * what was done (services: full groom, bath, nails…);
--   * how the coat was (condition and thickness), which is what makes a
--     shave-down defensible;
--   * the haircut: a style and a length, the dog's usual changes to it, and
--     anything done differently today, zone by zone;
--   * a note for next time, and the time the dog went home.
--
-- The style is a guide, not law (README, "Changing a style"). Nothing here
-- stops a groomer cutting what she judged right; a change from the template
-- is recorded and, if it breaks the template's own identity, flagged. What is
-- asked for:
--
--   * Why, when today's cut differs from the dog's usual style (the schema's
--     own rule, cut_specification.deviation_needs_reason, now with a groomer's
--     wording: GR034). One line: "owner asked for shorter".
--   * A pelted coat (level 5) is shaved close, and the groomer says she has
--     told the owner what that can do to the skin (GR033). Level 4 is a
--     warning on the screen only.
--   * A haircut the rules would stop — a shave-down the coat does not justify
--     (GR001), a puppy under the shop's grooming age (GR011) — goes ahead
--     with a reason and a manager's OK, and only a manager's (GR035).
--
-- The dog's usual style is one row per dog (dog_style_profile, "Usual"): a
-- style, a length, and the zones this dog always gets differently. The next
-- groom starts from it. Saving today's cut as the usual is a tick-box, and the
-- change, before and after, goes in the audit log with the reason given.
--
--   GR033  a pelted coat shaved without the groomer saying she told the owner
--   GR034  a haircut that differs from the dog's usual style, with no reason
--   GR035  a haircut override OK'd by someone who is not a manager
-- =============================================================================

SET search_path = groom, public;

INSERT INTO policy_enforcement (error_code, level, relaxable, description) VALUES
  ('GR033', 'block', false, 'A pelted coat shaved without the owner being told what it means'),
  ('GR034', 'block', false, 'A haircut different from the dog''s usual style, with no reason'),
  ('GR035', 'block', false, 'A haircut override approved by someone who is not a manager');

-- Who said the owner had been told, and when. Kept on the haircut itself,
-- like the override reasons: it is the row read back in "you shaved my dog".
ALTER TABLE cut_specification
  ADD COLUMN shave_acknowledged_by uuid REFERENCES groomer(id) ON DELETE RESTRICT,
  ADD COLUMN shave_acknowledged_at timestamptz,
  ADD CONSTRAINT shave_acknowledged_whole
    CHECK ((shave_acknowledged_by IS NULL) = (shave_acknowledged_at IS NULL));

-- The coat level that means pelted: shaved close, owner told first.
INSERT INTO shop_policy (key, value_type, int_value, description) VALUES
  ('pelted_coat_level', 'integer', 5,
   'Coat condition at which a shave-down needs the groomer to say the owner was told (GR033).');

-- -----------------------------------------------------------------------------
-- Small readings the screen needs
-- -----------------------------------------------------------------------------

-- Whether a haircut on this day needs the under-age reason (GR011's test,
-- asked before saving rather than discovered by a refusal).
CREATE FUNCTION under_groom_age(p_dog_id uuid, p_on date) RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT enforcement_level('GR011') <> 'off'
       AND COALESCE((SELECT (p_on - d.date_of_birth) / 7 < min_groom_age_weeks()
                       FROM dog d WHERE d.id = p_dog_id), false)
$$;

-- The dog's usual style: its one default profile, if it has one.
CREATE FUNCTION usual_style_id(p_dog_id uuid) RETURNS uuid
LANGUAGE sql STABLE AS $$
    SELECT p.id FROM dog_style_profile p
     WHERE p.dog_id = p_dog_id AND p.is_default AND p.is_active
$$;

-- A style as words: {style, length, changes: [{zone, cut}]}. For the audit
-- log's before and after, and for the card's "usual style" line.
CREATE FUNCTION usual_style_summary(p_profile_id uuid) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
             'style',  t.name,
             'length', lt.code,
             'changes', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                         'zone', bz.plain_language_label,
                         'cut',  describe_tooling(o.tool, o.blade_id, o.comb_id))
                         ORDER BY bz.display_order)
                  FROM profile_zone_override o JOIN body_zone bz ON bz.id = o.body_zone_id
                 WHERE o.dog_style_profile_id = p.id), '[]'::jsonb))
      FROM dog_style_profile p
      JOIN style_template t   ON t.id = p.style_template_id
      LEFT JOIN length_tier lt ON lt.id = p.length_tier_id
     WHERE p.id = p_profile_id
$$;

-- -----------------------------------------------------------------------------
-- The plan: what a style and length come to on this dog, zone by zone
--
-- The same ladder resolve_cut_spec_zones() climbs (section 12), read without
-- writing anything, so the screen can show the cut before it is saved. The
-- dog's usual changes apply when today's style is its usual style; a
-- different style starts clean. tests/28 records a haircut with no changes and
-- checks it comes out exactly as planned, so the two cannot drift apart.
--
-- A shave-down keys on the coat level. Below the style's threshold (a
-- manager's override) the plan is the threshold's cut: the shave the groomer
-- chose, not a haircut of hygiene zones only.
-- -----------------------------------------------------------------------------

CREATE FUNCTION haircut_level(p_template_id uuid, p_coat_level smallint) RETURNS smallint
LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN t.is_remedial
                THEN GREATEST(COALESCE(p_coat_level, 0), t.min_coat_ordinal_required)::smallint END
      FROM style_template t WHERE t.id = p_template_id
$$;

CREATE FUNCTION haircut_plan(p_dog_id uuid, p_template text, p_tier text, p_coat_level smallint)
RETURNS TABLE (zone_code text, zone text, display_order integer, is_hygiene boolean,
               tool cutting_tool, blade_id uuid, comb_id uuid, cut text, source text)
LANGUAGE sql STABLE AS $$
    WITH t AS (
        SELECT st.id, haircut_level(st.id, p_coat_level) AS level
          FROM style_template st WHERE st.code = p_template
    ),
    tier AS (SELECT lt.id FROM length_tier lt WHERE lt.code = p_tier),
    tmpl AS (
        SELECT DISTINCT ON (s.body_zone_id) s.body_zone_id, s.tool, s.blade_id, s.comb_id
          FROM style_template_zone_spec s, t
         WHERE s.style_template_id = t.id
           AND (s.length_tier_id = (SELECT id FROM tier)
                OR (s.min_coat_ordinal IS NOT NULL AND s.min_coat_ordinal <= t.level))
         ORDER BY s.body_zone_id, s.min_coat_ordinal DESC NULLS LAST
    ),
    ovr AS (
        SELECT o.body_zone_id, o.tool, o.blade_id, o.comb_id
          FROM profile_zone_override o
          JOIN dog_style_profile p ON p.id = o.dog_style_profile_id
         WHERE p.id = usual_style_id(p_dog_id)
           AND p.style_template_id = (SELECT id FROM t)
    ),
    dflt AS (
        SELECT d.body_zone_id, 'clipper'::cutting_tool AS tool, d.blade_id, NULL::uuid AS comb_id
          FROM zone_default d
    ),
    zones AS (
        SELECT body_zone_id FROM ovr
        UNION SELECT body_zone_id FROM tmpl
        UNION SELECT body_zone_id FROM dflt
    ),
    resolved AS (
        SELECT z.body_zone_id,
               COALESCE(o.tool, s.tool, d.tool) AS tool,
               CASE WHEN o.body_zone_id IS NOT NULL THEN o.blade_id
                    WHEN s.body_zone_id IS NOT NULL THEN s.blade_id ELSE d.blade_id END AS blade_id,
               CASE WHEN o.body_zone_id IS NOT NULL THEN o.comb_id
                    WHEN s.body_zone_id IS NOT NULL THEN s.comb_id ELSE d.comb_id END AS comb_id,
               CASE WHEN o.body_zone_id IS NOT NULL THEN 'usual'
                    WHEN s.body_zone_id IS NOT NULL THEN 'style' ELSE 'hygiene' END AS source
          FROM zones z
          LEFT JOIN ovr  o ON o.body_zone_id = z.body_zone_id
          LEFT JOIN tmpl s ON s.body_zone_id = z.body_zone_id
          LEFT JOIN dflt d ON d.body_zone_id = z.body_zone_id
    )
    SELECT bz.code, bz.plain_language_label, bz.display_order,
           EXISTS (SELECT 1 FROM zone_default zd WHERE zd.body_zone_id = bz.id),
           r.tool, r.blade_id, r.comb_id, describe_tooling(r.tool, r.blade_id, r.comb_id), r.source
      FROM resolved r JOIN body_zone bz ON bz.id = r.body_zone_id
     WHERE EXISTS (SELECT 1 FROM t)
     ORDER BY bz.display_order
$$;

COMMENT ON FUNCTION haircut_plan(uuid, text, text, smallint) IS
  'What a style and length come to on this dog, zone by zone, before anything is '
  'saved. source: usual (the dog''s standing change), style, or hygiene.';

-- -----------------------------------------------------------------------------
-- What was done, and how the coat was
-- -----------------------------------------------------------------------------

CREATE FUNCTION record_visit_services(p_visit_id uuid, p_services text[]) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM unnest(p_services) s
                WHERE NOT EXISTS (SELECT 1 FROM service_type st WHERE st.code = s)) THEN
        RAISE EXCEPTION 'Unknown service in %', p_services USING ERRCODE = 'foreign_key_violation';
    END IF;
    DELETE FROM visit_service vs USING service_type st
     WHERE vs.visit_id = p_visit_id AND st.id = vs.service_type_id AND st.code <> ALL (p_services);
    INSERT INTO visit_service (visit_id, service_type_id)
    SELECT p_visit_id, st.id FROM service_type st WHERE st.code = ANY (p_services)
    ON CONFLICT (visit_id, service_type_id) DO NOTHING;
END $$;

CREATE FUNCTION record_coat(p_visit_id uuid, p_by uuid, p_condition smallint, p_density smallint,
                            p_note text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v_id uuid;
BEGIN
    INSERT INTO coat_assessment (dog_id, visit_id, condition_ordinal, density_ordinal, note, assessed_by)
    SELECT v.dog_id, v.id, p_condition, p_density, nullif_blank(p_note), p_by
      FROM visit v WHERE v.id = p_visit_id
    ON CONFLICT (visit_id) DO UPDATE
       SET condition_ordinal = EXCLUDED.condition_ordinal,
           density_ordinal   = EXCLUDED.density_ordinal,
           note              = EXCLUDED.note,
           assessed_by       = EXCLUDED.assessed_by,
           assessed_at       = now()
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'No visit %', p_visit_id USING ERRCODE = 'foreign_key_violation';
    END IF;
    RETURN v_id;
END $$;

-- -----------------------------------------------------------------------------
-- The haircut
--
-- p_changes: what the groomer did differently today, as a JSON array of
-- {zone, tool, blade_id, comb_id}; only the zones that differ from the plan.
-- They are written as the visit's own ('ad_hoc') zone rows, which sit above
-- every level of the ladder, then the ladder fills in the rest.
--
-- One reason, p_override_reason, covers whichever override the haircut needs
-- (a shave-down the coat does not justify, a puppy under age); this function
-- works out which, so the screen only has to ask.
-- -----------------------------------------------------------------------------

CREATE FUNCTION record_haircut(p_visit_id uuid, p_by uuid, p_template text, p_tier text,
                               p_changes jsonb, p_why_different text,
                               p_override_reason text, p_approved_by uuid,
                               p_shave_acknowledged boolean)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_visit    visit;
    v_tmpl     style_template;
    v_tier_id  uuid;
    v_usual    dog_style_profile;
    v_coat     smallint;
    v_level    smallint;
    v_differs  boolean;
    v_reason   text := nullif_blank(p_override_reason);
    v_remedial text;
    v_age      text;
    v_spec_id  uuid;
    v_actor    text;
    c          jsonb;
BEGIN
    SELECT * INTO v_visit FROM visit WHERE id = p_visit_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No visit %', p_visit_id USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF EXISTS (SELECT 1 FROM cut_specification WHERE visit_id = p_visit_id) THEN
        RAISE EXCEPTION 'This groom''s haircut is already recorded' USING ERRCODE = 'unique_violation';
    END IF;

    SELECT * INTO v_tmpl FROM style_template WHERE code = p_template;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown style %', p_template USING ERRCODE = 'GR007';
    END IF;
    SELECT id INTO v_tier_id FROM length_tier WHERE code = p_tier;
    IF p_tier IS NOT NULL AND v_tier_id IS NULL THEN
        RAISE EXCEPTION 'Unknown length %', p_tier USING ERRCODE = 'GR009';
    END IF;

    SELECT * INTO v_usual FROM dog_style_profile WHERE id = usual_style_id(v_visit.dog_id);
    SELECT ca.condition_ordinal INTO v_coat FROM coat_assessment ca WHERE ca.visit_id = p_visit_id;
    v_level := haircut_level(v_tmpl.id, v_coat);
    p_changes := COALESCE(p_changes, '[]'::jsonb);

    -- GR033. A pelted coat is shaved close. Owner told first, and it says who.
    IF v_tmpl.is_remedial AND v_coat >= shop_policy_int('pelted_coat_level')
       AND NOT COALESCE(p_shave_acknowledged, false)
       AND enforcement_level('GR033') = 'block' THEN
        RAISE EXCEPTION 'The coat is pelted: tell the owner before it is shaved'
            USING ERRCODE = 'GR033',
                  HINT = 'Shaving close can leave the skin red, itchy or nicked, and the coat takes months to grow back. Tick that the owner has been told.';
    END IF;

    -- GR034. Different from the usual style: say why, in a line.
    v_differs := v_usual.id IS NOT NULL
             AND (v_usual.style_template_id <> v_tmpl.id
                  OR v_usual.length_tier_id IS DISTINCT FROM v_tier_id
                  OR jsonb_array_length(p_changes) > 0);
    IF v_differs AND nullif_blank(p_why_different) IS NULL THEN
        RAISE EXCEPTION 'Today''s cut is different from the dog''s usual style'
            USING ERRCODE = 'GR034',
                  HINT = 'Say why in a few words, such as "owner asked for shorter".';
    END IF;

    -- Which override, if any, the reason is for.
    IF v_tmpl.is_remedial AND COALESCE(v_coat, 0) < v_tmpl.min_coat_ordinal_required THEN
        v_remedial := v_reason;
    END IF;
    IF under_groom_age(v_visit.dog_id, v_visit.visit_date) THEN
        v_age := v_reason;
    END IF;
    -- GR035. Only a manager OKs a haircut the rules would stop.
    IF (v_remedial IS NOT NULL OR v_age IS NOT NULL)
       AND NOT EXISTS (SELECT 1 FROM groomer g
                        WHERE g.id = p_approved_by AND g.role = 'manager' AND g.is_active) THEN
        RAISE EXCEPTION 'Only a manager can OK this haircut'
            USING ERRCODE = 'GR035',
                  HINT = 'Pick the manager who agreed to it.';
    END IF;

    INSERT INTO cut_specification (
        visit_id, dog_style_profile_id, style_template_id, length_tier_id, coat_ordinal_applied,
        deviated_from_profile, deviation_reason,
        remedial_override_reason, under_age_override_reason, approved_by, approved_at,
        shave_acknowledged_by, shave_acknowledged_at, created_by)
    VALUES (
        p_visit_id,
        -- The usual changes apply only on the usual style (as in the plan).
        CASE WHEN v_usual.style_template_id = v_tmpl.id THEN v_usual.id END,
        v_tmpl.id, v_tier_id, v_level,
        v_differs, CASE WHEN v_differs THEN nullif_blank(p_why_different) END,
        v_remedial, v_age,
        CASE WHEN v_remedial IS NOT NULL OR v_age IS NOT NULL THEN p_approved_by END,
        CASE WHEN v_remedial IS NOT NULL OR v_age IS NOT NULL THEN now() END,
        CASE WHEN v_tmpl.is_remedial AND p_shave_acknowledged THEN p_by END,
        CASE WHEN v_tmpl.is_remedial AND p_shave_acknowledged THEN now() END,
        p_by)
    RETURNING id INTO v_spec_id;

    -- Today's own changes, flagged where they break the style's identity
    -- (a fluffy Poodle face): recorded, never refused.
    FOR c IN SELECT * FROM jsonb_array_elements(p_changes) LOOP
        INSERT INTO cut_spec_zone (cut_specification_id, body_zone_id, tool, blade_id, comb_id,
                                   resolved_label, resolved_from, was_override, clamp_violated)
        SELECT v_spec_id, bz.id, (c->>'tool')::cutting_tool,
               (c->>'blade_id')::uuid, (c->>'comb_id')::uuid, '', 'ad_hoc', true,
               COALESCE(derive_effective_length((c->>'tool')::cutting_tool, (c->>'blade_id')::uuid,
                                                (c->>'comb_id')::uuid) > cl.max_effective_length_in, false)
            OR COALESCE(derive_effective_length((c->>'tool')::cutting_tool, (c->>'blade_id')::uuid,
                                                (c->>'comb_id')::uuid) < cl.min_effective_length_in, false)
          FROM body_zone bz
          LEFT JOIN style_template_zone_clamp cl
                 ON cl.style_template_id = v_tmpl.id AND cl.body_zone_id = bz.id
         WHERE bz.code = c->>'zone';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown zone %', c->>'zone' USING ERRCODE = 'foreign_key_violation';
        END IF;
    END LOOP;

    PERFORM resolve_cut_spec_zones(v_spec_id);

    SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_by;
    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    VALUES (p_by, COALESCE(v_actor, current_user), 'create', 'cut_specification', v_spec_id,
            jsonb_build_object('visit_id', p_visit_id, 'style', v_tmpl.code, 'length', p_tier,
                               'changes', p_changes, 'reason', nullif_blank(p_why_different)));
    RETURN v_spec_id;
END $$;

COMMENT ON FUNCTION record_haircut(uuid, uuid, text, text, jsonb, text, text, uuid, boolean) IS
  'The screen''s way to record a haircut. Refuses a pelted shave without the owner '
  'told (GR033), a change from the usual with no reason (GR034), and an override '
  'not OK''d by a manager (GR035); the schema''s own guards (GR001–GR011) still apply.';

-- -----------------------------------------------------------------------------
-- Keeping today's cut as the dog's usual style
--
-- The usual style becomes today's style and length, and its standing changes
-- become every zone today that did not come from the style: the usual changes
-- kept, and today's own. A shave-down is never a usual style (GR008).
-- -----------------------------------------------------------------------------

CREATE FUNCTION save_usual_style(p_cut_specification_id uuid, p_by uuid, p_reason text)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_spec   cut_specification;
    v_dog_id uuid;
    v_id     uuid;
    v_before jsonb;
    v_after  jsonb;
    v_actor  text;
BEGIN
    SELECT * INTO STRICT v_spec FROM cut_specification WHERE id = p_cut_specification_id;
    SELECT v.dog_id INTO v_dog_id FROM visit v WHERE v.id = v_spec.visit_id;
    v_id := usual_style_id(v_dog_id);
    v_before := usual_style_summary(v_id);

    IF v_id IS NULL THEN
        INSERT INTO dog_style_profile (dog_id, profile_name, style_template_id, length_tier_id,
                                       is_default, created_by)
        VALUES (v_dog_id, 'Usual', v_spec.style_template_id, v_spec.length_tier_id, true, p_by)
        RETURNING id INTO v_id;
    ELSE
        UPDATE dog_style_profile
           SET style_template_id = v_spec.style_template_id, length_tier_id = v_spec.length_tier_id
         WHERE id = v_id;
        DELETE FROM profile_zone_override WHERE dog_style_profile_id = v_id;
    END IF;

    INSERT INTO profile_zone_override (dog_style_profile_id, body_zone_id, tool, blade_id, comb_id, reason)
    SELECT v_id, z.body_zone_id, z.tool, z.blade_id, z.comb_id,
           CASE WHEN z.resolved_from = 'ad_hoc' THEN nullif_blank(p_reason) END
      FROM cut_spec_zone z
     WHERE z.cut_specification_id = p_cut_specification_id
       AND z.resolved_from IN ('profile_override', 'ad_hoc');

    v_after := usual_style_summary(v_id);
    IF v_before IS DISTINCT FROM v_after THEN
        SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_by;
        INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
        VALUES (p_by, COALESCE(v_actor, current_user),
                CASE WHEN v_before IS NULL THEN 'create' ELSE 'update' END::audit_action,
                'dog_style_profile', v_id,
                jsonb_build_object('before', v_before, 'after', v_after,
                                   'reason', COALESCE(nullif_blank(p_reason),
                                                      NULLIF(current_setting('groom.change_reason', true), ''))));
    END IF;
    RETURN v_id;
END $$;

-- -----------------------------------------------------------------------------
-- Going home
-- -----------------------------------------------------------------------------

CREATE FUNCTION finish_visit(p_visit_id uuid, p_by uuid, p_note text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_now   time(0) := shop_now()::time(0);
    v_actor text;
BEGIN
    UPDATE visit
       SET check_out    = GREATEST(v_now, COALESCE(check_in, v_now)),
           overall_note = COALESCE(nullif_blank(p_note), overall_note)
     WHERE id = p_visit_id AND check_out IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'This groom is already finished, or there is no such visit'
            USING HINT = 'Reload the dog''s card.';
    END IF;
    SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_by;
    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    VALUES (p_by, COALESCE(v_actor, current_user), 'update', 'visit', p_visit_id,
            jsonb_build_object('check_out', v_now, 'note', nullif_blank(p_note), 'via', 'finish_visit'));
END $$;

-- -----------------------------------------------------------------------------
-- A recorded haircut, as the next groomer wants to read it
-- -----------------------------------------------------------------------------

CREATE VIEW v_haircut AS
SELECT cs.id, cs.visit_id, v.dog_id, v.visit_date, g.display_name AS groomer,
       t.code AS style_code, t.name AS style, lt.code AS length,
       cs.coat_ordinal_applied, ca.condition_ordinal AS coat_condition, ca.density_ordinal AS coat_density,
       cs.deviation_reason,
       COALESCE(cs.remedial_override_reason, cs.under_age_override_reason) AS override_reason,
       ap.display_name AS approved_by,
       COALESCE((SELECT jsonb_agg(jsonb_build_object(
                          'zone', bz.plain_language_label, 'cut', z.resolved_label,
                          'today', z.resolved_from = 'ad_hoc', 'flagged', z.clamp_violated)
                          ORDER BY bz.display_order)
                   FROM cut_spec_zone z JOIN body_zone bz ON bz.id = z.body_zone_id
                  WHERE z.cut_specification_id = cs.id
                    AND z.resolved_from IN ('profile_override', 'ad_hoc')), '[]'::jsonb) AS changes
  FROM cut_specification cs
  JOIN visit v             ON v.id = cs.visit_id
  JOIN groomer g           ON g.id = v.performed_by
  JOIN style_template t    ON t.id = cs.style_template_id
  LEFT JOIN length_tier lt ON lt.id = cs.length_tier_id
  LEFT JOIN coat_assessment ca ON ca.visit_id = cs.visit_id
  LEFT JOIN groomer ap     ON ap.id = cs.approved_by;

COMMENT ON VIEW v_haircut IS
  'Each recorded haircut: style, length, and the zones cut differently from the style '
  '(the dog''s usual changes and the day''s own, today = true).';

ALTER FUNCTION under_groom_age(uuid, date)                  SET search_path = groom, public;
ALTER FUNCTION usual_style_id(uuid)                         SET search_path = groom, public;
ALTER FUNCTION usual_style_summary(uuid)                    SET search_path = groom, public;
ALTER FUNCTION haircut_level(uuid, smallint)                SET search_path = groom, public;
ALTER FUNCTION haircut_plan(uuid, text, text, smallint)     SET search_path = groom, public;
ALTER FUNCTION record_visit_services(uuid, text[])          SET search_path = groom, public;
ALTER FUNCTION record_coat(uuid, uuid, smallint, smallint, text) SET search_path = groom, public;
ALTER FUNCTION record_haircut(uuid, uuid, text, text, jsonb, text, text, uuid, boolean)
                                                            SET search_path = groom, public;
ALTER FUNCTION save_usual_style(uuid, uuid, text)           SET search_path = groom, public;
ALTER FUNCTION finish_visit(uuid, uuid, text)               SET search_path = groom, public;
