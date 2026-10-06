-- =============================================================================
-- 24. Allergies and handling notes, kept by the groomers
--
-- Both have been in the schema since section 3; nothing could add to them but
-- a seed. This section gives the counter the doors, the same way section 22 did
-- for owners and dogs: a list to pick from with "did you mean", and an audit
-- record of every change.
--
-- Allergies are grouped by what they change for the groomer:
--
--   contact        don't put it on the dog (shampoos, oils, sprays, gloves)
--   flea           check for fleas; go gently on irritated skin
--   environmental  expect itchy paws, ears and belly
--   food           mind the treats at the counter
--
-- The list lives in sql/25_allergen_seed.sql.
--
-- Anyone on duty can change a dog's allergies: a small shop does not always
-- have a manager in. A change that leaves the dog less protected — an allergy
-- taken off, or made less severe — needs a reason and is flagged for a manager
-- to look at (change_review). Adding one, making one more severe, or fixing a
-- note needs neither: it can only make the groom safer. An allergy taken off is
-- kept, marked removed, with who, when and why.
--
-- Handling notes are a history: what a groomer saw, on a day. A note is not
-- deleted when it stops being true; a newer note says what is true now. A typo
-- in a note can be corrected, and the correction is audited. A note can say
-- which side: front or back feet and paw pads, left or right ear. The side
-- lives on the note, not in the body-zone list, because that list is shared
-- with the style templates, where a cut is the same on both sides.
--
--   GR024  an allergen that is not on the list, without saying it is a new one
--   GR025  an allergy taken off, or made less severe, without a reason
--   GR026  a change marked reviewed by someone who is not a manager
-- =============================================================================

SET search_path = groom, public;

INSERT INTO policy_enforcement (error_code, level, relaxable, description) VALUES
  ('GR024', 'block', false, 'An allergen not on the list, saved without saying it is a new one'),
  ('GR025', 'block', false, 'An allergy removed or made less severe without a reason'),
  ('GR026', 'block', false, 'A flagged change marked reviewed by someone who is not a manager');

-- -----------------------------------------------------------------------------
-- The allergen list: grouped
-- -----------------------------------------------------------------------------

ALTER TABLE allergen
    ADD COLUMN allergy_type text NOT NULL DEFAULT 'contact'
        CHECK (allergy_type IN ('contact', 'flea', 'environmental', 'food'));
COMMENT ON COLUMN allergen.allergy_type IS
  'What the allergy changes for the groomer. category says what kind of product a contact allergen is.';

CREATE FUNCTION allergy_type_order(p_type text) RETURNS integer
  LANGUAGE sql IMMUTABLE AS $$
    SELECT array_position(ARRAY['contact', 'flea', 'environmental', 'food'], p_type) $$;

CREATE FUNCTION suggest_allergens(p_text text, p_limit integer DEFAULT 4)
RETURNS TABLE (name text, allergy_type text) LANGUAGE sql STABLE AS $$
    SELECT a.name, a.allergy_type
      FROM allergen a
      CROSS JOIN LATERAL (
          SELECT greatest(
                   similarity(lower(regexp_replace(p_text, '[^[:alnum:]]', '', 'g')),
                              lower(regexp_replace(a.name, '[^[:alnum:]]', '', 'g'))),
                   word_similarity(lower(p_text), lower(a.name))) AS score) m
     WHERE nullif_blank(p_text) IS NOT NULL AND m.score >= 0.3
     ORDER BY m.score DESC, a.name
     LIMIT p_limit
$$;

-- The allergen a typed name means, or — only when the groomer says it is new
-- — a new one of the type they chose. Anything else is GR024.
CREATE FUNCTION resolve_allergen(p_text text, p_is_new boolean, p_type text)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_name text := nullif_blank(p_text);
    v_id   uuid;
    v_near text;
BEGIN
    IF v_name IS NULL THEN
        RAISE EXCEPTION 'Name the allergy' USING ERRCODE = 'check_violation';
    END IF;
    SELECT a.id INTO v_id FROM allergen a WHERE lower(a.name) = lower(v_name);
    IF FOUND THEN
        RETURN v_id;
    END IF;
    IF NOT COALESCE(p_is_new, false) THEN
        SELECT string_agg(s.name, ', ') INTO v_near FROM suggest_allergens(v_name) s;
        RAISE EXCEPTION '"%" is not on the allergy list', v_name
            USING ERRCODE = 'GR024',
                  HINT = CASE WHEN v_near IS NOT NULL THEN 'Did you mean ' || v_near || '? ' ELSE '' END
                         || 'If it really is one the list lacks, add it as a new allergy.';
    END IF;
    IF p_type IS NULL OR p_type NOT IN ('contact', 'flea', 'environmental', 'food') THEN
        RAISE EXCEPTION 'Say what kind of allergy "%" is', v_name
            USING ERRCODE = 'check_violation',
                  HINT = 'Contact, flea, environmental or food.';
    END IF;
    INSERT INTO allergen (name, category, allergy_type) VALUES (v_name, 'other', p_type)
    RETURNING id INTO v_id;
    RETURN v_id;
END $$;

-- -----------------------------------------------------------------------------
-- Flagged for a manager
--
-- One row per change a manager should look at. It says what changed in words,
-- why, and who did it; a manager marks it reviewed. A manager's own change is
-- reviewed as it is made.
-- -----------------------------------------------------------------------------

CREATE TABLE change_review (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    dog_id       uuid NOT NULL REFERENCES dog(id) ON DELETE RESTRICT,
    entity_type  text NOT NULL,
    entity_id    uuid NOT NULL,
    summary      text NOT NULL,
    reason       text NOT NULL CHECK (btrim(reason) <> ''),
    changed_by   uuid NOT NULL REFERENCES groomer(id) ON DELETE RESTRICT,
    changed_at   timestamptz NOT NULL DEFAULT now(),
    reviewed_by  uuid REFERENCES groomer(id) ON DELETE RESTRICT,
    reviewed_at  timestamptz,
    CONSTRAINT review_coherent CHECK ((reviewed_by IS NULL) = (reviewed_at IS NULL))
);
CREATE INDEX change_review_open_idx ON change_review (changed_at) WHERE reviewed_at IS NULL;

CREATE FUNCTION flag_for_review(p_dog_id uuid, p_entity_type text, p_entity_id uuid, p_summary text,
                                p_reason text, p_changed_by uuid)
RETURNS uuid LANGUAGE sql AS $$
    INSERT INTO change_review (dog_id, entity_type, entity_id, summary, reason, changed_by, reviewed_by, reviewed_at)
    SELECT p_dog_id, p_entity_type, p_entity_id, p_summary, btrim(p_reason), p_changed_by,
           CASE WHEN g.role = 'manager' THEN g.id END,
           CASE WHEN g.role = 'manager' THEN now() END
      FROM groomer g WHERE g.id = p_changed_by
    RETURNING id
$$;

CREATE FUNCTION mark_reviewed(p_review_id uuid, p_manager_id uuid)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_actor text;
BEGIN
    SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_manager_id AND g.role = 'manager';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Only a manager can mark a change reviewed'
            USING ERRCODE = 'GR026',
                  HINT = 'The change stays on the manager''s list until a manager looks at it.';
    END IF;
    UPDATE change_review SET reviewed_by = p_manager_id, reviewed_at = now()
     WHERE id = p_review_id AND reviewed_at IS NULL;
    IF FOUND THEN
        INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
        VALUES (p_manager_id, v_actor, 'update', 'change_review', p_review_id,
                jsonb_build_object('reviewed', true));
    END IF;
END $$;

CREATE VIEW v_change_review_open AS
SELECT r.id, r.dog_id, d.name AS dog, o.first_name || ' ' || o.last_name AS owner,
       r.summary, r.reason, g.display_name AS changed_by, r.changed_at
  FROM change_review r
  JOIN dog d     ON d.id = r.dog_id
  JOIN owner o   ON o.id = d.owner_id
  JOIN groomer g ON g.id = r.changed_by
 WHERE r.reviewed_at IS NULL
 ORDER BY r.changed_at;

-- -----------------------------------------------------------------------------
-- A dog's allergies
-- -----------------------------------------------------------------------------

ALTER TABLE allergy
    ADD COLUMN removed_at     timestamptz,
    ADD COLUMN removed_by     uuid REFERENCES groomer(id) ON DELETE RESTRICT,
    ADD COLUMN removed_reason text,
    ADD CONSTRAINT removal_coherent CHECK (
        (removed_at IS NULL AND removed_by IS NULL AND removed_reason IS NULL)
     OR (removed_at IS NOT NULL AND removed_by IS NOT NULL AND btrim(removed_reason) <> ''));
-- One current allergy per allergen; a removed one can be added again.
ALTER TABLE allergy DROP CONSTRAINT allergy_dog_id_allergen_id_key;
CREATE UNIQUE INDEX allergy_one_current ON allergy (dog_id, allergen_id) WHERE removed_at IS NULL;

CREATE FUNCTION severity_label(p_severity integer) RETURNS text
  LANGUAGE sql IMMUTABLE AS $$
    SELECT (ARRAY['Mild', 'Moderate', 'Severe', 'Dangerous — never use'])[p_severity] $$;

CREATE FUNCTION allergy_details(p_allergy_id uuid) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('severity', severity_label(a.severity_ordinal), 'source', a.source,
                              'note', a.note)
      FROM allergy a WHERE a.id = p_allergy_id
$$;

CREATE FUNCTION add_allergy(p_dog_id uuid, p_allergen text, p_severity integer, p_source allergy_source,
                            p_note text, p_added_by uuid, p_new_allergen boolean DEFAULT false,
                            p_allergy_type text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_actor       text;
    v_allergen_id uuid;
    v_id          uuid;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dog d WHERE d.id = p_dog_id AND d.is_active) THEN
        RAISE EXCEPTION 'Dog % is not an active client', p_dog_id;
    END IF;
    SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_added_by;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No such groomer: %', p_added_by USING ERRCODE = 'foreign_key_violation';
    END IF;
    v_allergen_id := resolve_allergen(p_allergen, p_new_allergen, p_allergy_type);
    IF EXISTS (SELECT 1 FROM allergy a WHERE a.dog_id = p_dog_id AND a.allergen_id = v_allergen_id
                                       AND a.removed_at IS NULL) THEN
        RAISE EXCEPTION '% is already on this dog''s allergies', (SELECT name FROM allergen WHERE id = v_allergen_id)
            USING ERRCODE = 'unique_violation',
                  HINT = 'Edit the one already there instead.';
    END IF;

    INSERT INTO allergy (dog_id, allergen_id, severity_ordinal, source, note, recorded_by)
    VALUES (p_dog_id, v_allergen_id, p_severity, COALESCE(p_source, 'owner_reported'), nullif_blank(p_note), p_added_by)
    RETURNING id INTO v_id;

    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    VALUES (p_added_by, v_actor, 'create', 'allergy', v_id,
            jsonb_build_object('dog_id', p_dog_id, 'allergen', (SELECT name FROM allergen WHERE id = v_allergen_id))
            || allergy_details(v_id));
    RETURN v_id;
END $$;

-- A change to how severe it is, where the information came from, or the note.
-- Less severe needs a reason, and is flagged.
CREATE FUNCTION update_allergy(p_allergy_id uuid, p_severity integer, p_source allergy_source,
                               p_note text, p_edited_by uuid, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_row    allergy;
    v_actor  text;
    v_before jsonb;
    v_diff   jsonb;
    v_name   text;
BEGIN
    SELECT * INTO v_row FROM allergy WHERE id = p_allergy_id AND removed_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No current allergy with id %', p_allergy_id USING ERRCODE = 'foreign_key_violation';
    END IF;
    SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_edited_by;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No such groomer: %', p_edited_by USING ERRCODE = 'foreign_key_violation';
    END IF;
    SELECT name INTO v_name FROM allergen WHERE id = v_row.allergen_id;
    IF p_severity < v_row.severity_ordinal AND nullif_blank(p_reason) IS NULL THEN
        RAISE EXCEPTION '%: making it less severe needs a reason', v_name
            USING ERRCODE = 'GR025',
                  HINT = 'Say why, for example "vet says it was a one-off". A manager will see it.';
    END IF;

    v_before := allergy_details(p_allergy_id);
    UPDATE allergy SET severity_ordinal = p_severity, source = COALESCE(p_source, v_row.source),
                       note = nullif_blank(p_note)
     WHERE id = p_allergy_id;
    v_diff := jsonb_diff(v_before, allergy_details(p_allergy_id));
    IF v_diff = '{}' THEN
        RETURN v_diff;
    END IF;

    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    VALUES (p_edited_by, v_actor, 'update', 'allergy', p_allergy_id,
            v_diff || jsonb_build_object('allergen', v_name, 'reason', nullif_blank(p_reason)));
    IF p_severity < v_row.severity_ordinal THEN
        PERFORM flag_for_review(v_row.dog_id, 'allergy', p_allergy_id,
                                format('%s: %s → %s', v_name, severity_label(v_row.severity_ordinal),
                                       severity_label(p_severity)),
                                p_reason, p_edited_by);
    END IF;
    RETURN v_diff;
END $$;

CREATE FUNCTION remove_allergy(p_allergy_id uuid, p_reason text, p_removed_by uuid)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_row   allergy;
    v_actor text;
    v_name  text;
BEGIN
    SELECT * INTO v_row FROM allergy WHERE id = p_allergy_id AND removed_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No current allergy with id %', p_allergy_id USING ERRCODE = 'foreign_key_violation';
    END IF;
    SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_removed_by;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No such groomer: %', p_removed_by USING ERRCODE = 'foreign_key_violation';
    END IF;
    SELECT name INTO v_name FROM allergen WHERE id = v_row.allergen_id;
    IF nullif_blank(p_reason) IS NULL THEN
        RAISE EXCEPTION '%: taking an allergy off needs a reason', v_name
            USING ERRCODE = 'GR025',
                  HINT = 'Say why, for example "entered on the wrong dog". A manager will see it.';
    END IF;

    UPDATE allergy SET removed_at = now(), removed_by = p_removed_by, removed_reason = btrim(p_reason)
     WHERE id = p_allergy_id;
    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    VALUES (p_removed_by, v_actor, 'delete', 'allergy', p_allergy_id,
            jsonb_build_object('allergen', v_name, 'reason', btrim(p_reason)) || allergy_details(p_allergy_id));
    PERFORM flag_for_review(v_row.dog_id, 'allergy', p_allergy_id,
                            format('%s (%s) taken off', v_name, severity_label(v_row.severity_ordinal)),
                            p_reason, p_removed_by);
END $$;

-- -----------------------------------------------------------------------------
-- Handling notes
-- -----------------------------------------------------------------------------

-- More of what sets a dog off on the table.
ALTER TABLE behavior_note DROP CONSTRAINT behavior_note_trigger_kind_check;
ALTER TABLE behavior_note ADD CONSTRAINT behavior_note_trigger_kind_check CHECK (trigger_kind IN
    ('dryer', 'clippers', 'scissors', 'nail_grinder', 'brushing', 'bath', 'water', 'restraint',
     'table', 'other_dogs', 'noise', 'other'));

-- Which side, where it matters for handling. NULL is all of them.
ALTER TABLE behavior_note
    ADD COLUMN side text CHECK (side IN ('front', 'back', 'left', 'right'));

-- The spots a groomer can pick for a handling note: a body zone, and for feet,
-- paw pads and ears, a side. code is what the screen sends ('feet:front').
CREATE VIEW v_handling_spot AS
WITH sided (zone, side, label, n) AS (VALUES
    ('feet',     NULL,    'All feet',        0), ('feet',     'front', 'Front feet',     1),
    ('feet',     'back',  'Back feet',       2),
    ('paw_pads', NULL,    'All paw pads',    0), ('paw_pads', 'front', 'Front paw pads', 1),
    ('paw_pads', 'back',  'Back paw pads',   2),
    ('ears',     NULL,    'Both ears',       0), ('ears',     'left',  'Left ear',       1),
    ('ears',     'right', 'Right ear',       2))
SELECT bz.code || COALESCE(':' || s.side, '') AS code,
       COALESCE(s.label, bz.plain_language_label) AS label,
       bz.id AS body_zone_id, bz.code AS zone_code, s.side,
       bz.display_order * 10 + COALESCE(s.n, 0) AS sort_order
  FROM body_zone bz
  LEFT JOIN sided s ON s.zone = bz.code
 -- The ones a groomer names for a reaction. The hair-only zones, and the
 -- parts of an ear the two ears already cover, are left out.
 WHERE bz.code NOT IN ('sanitary', 'tail_pom', 'top_knot', 'base_of_tail', 'ear_tips', 'inside_ears');

-- The spot a note names, read back the same way.
CREATE FUNCTION spot_label(p_body_zone_id uuid, p_side text) RETURNS text
  LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
      (SELECT label FROM v_handling_spot WHERE body_zone_id = p_body_zone_id AND side IS NOT DISTINCT FROM p_side),
      (SELECT initcap(p_side) || ' ' || lower(plain_language_label) FROM body_zone WHERE id = p_body_zone_id AND p_side IS NOT NULL),
      (SELECT plain_language_label FROM body_zone WHERE id = p_body_zone_id)) $$;

CREATE FUNCTION behavior_details(p_note_id uuid) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('difficulty', n.handling_difficulty_ordinal, 'trigger', n.trigger_kind,
                              'where', spot_label(n.body_zone_id, n.side), 'note', n.note)
      FROM behavior_note n WHERE n.id = p_note_id
$$;

-- A spot's code ('ears:left'), as the zone and side to store. A blank is none.
CREATE FUNCTION resolve_spot(p_code text, OUT body_zone_id uuid, OUT side text)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF nullif_blank(p_code) IS NULL THEN
        RETURN;
    END IF;
    SELECT v.body_zone_id, v.side INTO body_zone_id, side FROM v_handling_spot v WHERE v.code = p_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown body part: %', p_code USING ERRCODE = 'check_violation';
    END IF;
END $$;

CREATE FUNCTION add_behavior_note(p_dog_id uuid, p_difficulty integer, p_trigger text, p_zone text,
                                  p_note text, p_observed_by uuid)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_actor text;
    v_id    uuid;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dog d WHERE d.id = p_dog_id AND d.is_active) THEN
        RAISE EXCEPTION 'Dog % is not an active client', p_dog_id;
    END IF;
    SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_observed_by;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No such groomer: %', p_observed_by USING ERRCODE = 'foreign_key_violation';
    END IF;
    INSERT INTO behavior_note (dog_id, handling_difficulty_ordinal, body_zone_id, side, trigger_kind, note, observed_by)
    SELECT p_dog_id, p_difficulty, s.body_zone_id, s.side, nullif_blank(p_trigger), nullif_blank(p_note), p_observed_by
      FROM resolve_spot(p_zone) s
    RETURNING id INTO v_id;
    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    VALUES (p_observed_by, v_actor, 'create', 'behavior_note', v_id,
            jsonb_build_object('dog_id', p_dog_id) || behavior_details(v_id));
    RETURN v_id;
END $$;

-- A typo put right. The note keeps its date and who saw it; the correction is
-- audited before and after.
CREATE FUNCTION correct_behavior_note(p_note_id uuid, p_difficulty integer, p_trigger text, p_zone text,
                                      p_note text, p_edited_by uuid)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_actor  text;
    v_before jsonb := behavior_details(p_note_id);
    v_diff   jsonb;
BEGIN
    IF v_before IS NULL THEN
        RAISE EXCEPTION 'No handling note with id %', p_note_id USING ERRCODE = 'foreign_key_violation';
    END IF;
    SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_edited_by;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No such groomer: %', p_edited_by USING ERRCODE = 'foreign_key_violation';
    END IF;
    UPDATE behavior_note n
       SET handling_difficulty_ordinal = p_difficulty, trigger_kind = nullif_blank(p_trigger),
           body_zone_id = s.body_zone_id, side = s.side, note = nullif_blank(p_note)
      FROM resolve_spot(p_zone) s
     WHERE n.id = p_note_id;
    v_diff := jsonb_diff(v_before, behavior_details(p_note_id));
    IF v_diff <> '{}' THEN
        INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
        VALUES (p_edited_by, v_actor, 'update', 'behavior_note', p_note_id, v_diff);
    END IF;
    RETURN v_diff;
END $$;
