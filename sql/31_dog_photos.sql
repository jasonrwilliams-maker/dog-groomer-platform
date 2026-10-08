-- =============================================================================
-- 31. A photo of the dog
--
-- An owner the shop hasn't seen in three months calls to book. The name says
-- little; the dog's face says a lot. Each dog can have one profile photo,
-- shown on its card, in the booking form and in the dog lists.
--
-- One upload is kept in the three sizes the schema planned for (dog_photo,
-- section 3): the photo itself (upright, downsized, its camera details and
-- location stripped), a display size for the card, and a small square for
-- lists. A new photo replaces the old one: the old files are handed back to be
-- deleted. Removing a photo does the same. Who added or removed it, and when,
-- is in the audit log.
-- =============================================================================

SET search_path = groom, public;

-- The profile photo is the dog's latest upload; this keeps it that way.
CREATE UNIQUE INDEX dog_photo_one_per_rendition ON dog_photo (dog_id, rendition);

CREATE FUNCTION set_dog_photo(p_dog_id uuid, p_renditions jsonb, p_by uuid)
RETURNS text[] LANGUAGE plpgsql AS $$
DECLARE
    v_actor  text;
    v_group  uuid := gen_random_uuid();
    v_old    text[];
    r        jsonb;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dog d WHERE d.id = p_dog_id AND d.is_active) THEN
        RAISE EXCEPTION 'Dog % is not an active client', p_dog_id;
    END IF;
    SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_by;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No such groomer: %', p_by USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF jsonb_typeof(p_renditions) <> 'array'
       OR (SELECT count(DISTINCT x ->> 'rendition') FROM jsonb_array_elements(p_renditions) x) <> 3 THEN
        RAISE EXCEPTION 'A photo is kept in three sizes: original, display and thumb'
            USING ERRCODE = 'check_violation';
    END IF;

    WITH gone AS (DELETE FROM dog_photo WHERE dog_id = p_dog_id RETURNING object_key)
    SELECT array_agg(object_key) INTO v_old FROM gone;

    FOR r IN SELECT * FROM jsonb_array_elements(p_renditions) LOOP
        INSERT INTO dog_photo (dog_id, photo_group_id, object_key, rendition, width_px, height_px, exif_stripped)
        VALUES (p_dog_id, v_group, r ->> 'object_key', (r ->> 'rendition')::photo_rendition,
                (r ->> 'width')::integer, (r ->> 'height')::integer, true);
    END LOOP;

    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    VALUES (p_by, v_actor, 'create', 'dog_photo', v_group,
            jsonb_build_object('dog_id', p_dog_id, 'replaced', v_old IS NOT NULL));
    RETURN coalesce(v_old, '{}');
END $$;

COMMENT ON FUNCTION set_dog_photo(uuid, jsonb, uuid) IS
  'Makes this the dog''s profile photo, in its three sizes. Returns the replaced photo''s files, to delete.';

CREATE FUNCTION remove_dog_photo(p_dog_id uuid, p_by uuid)
RETURNS text[] LANGUAGE plpgsql AS $$
DECLARE
    v_actor text;
    v_keys  text[];
BEGIN
    SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_by;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No such groomer: %', p_by USING ERRCODE = 'foreign_key_violation';
    END IF;
    WITH gone AS (DELETE FROM dog_photo WHERE dog_id = p_dog_id RETURNING object_key)
    SELECT array_agg(object_key) INTO v_keys FROM gone;
    IF v_keys IS NOT NULL THEN
        INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
        VALUES (p_by, v_actor, 'delete', 'dog_photo', p_dog_id, jsonb_build_object('dog_id', p_dog_id));
    END IF;
    RETURN coalesce(v_keys, '{}');
END $$;

COMMENT ON FUNCTION remove_dog_photo(uuid, uuid) IS
  'Takes the dog''s profile photo off. Returns its files, to delete.';
