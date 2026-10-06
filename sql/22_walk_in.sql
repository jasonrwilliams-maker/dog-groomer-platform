-- =============================================================================
-- 22. Walk-ins, and putting right what was typed wrong
--
-- A new client walks up to the counter with their dog and a copy of its
-- records. Until now the only ways in were the demo seed and the records
-- tool's upload, review and confirm — right for a stack of paperwork, too slow
-- for someone standing at the desk.
--
-- Each door is a function so the interface never writes these tables
-- directly, and each is audited with who used it:
--
--   add_client()          the owner: a name, and a phone or an email
--   add_dog()             the dog: a name and a coat type, a breed from the
--                         list (sql/23_breed_seed.sql), and whether it is a
--                         mix — of a second breed, or of something unknown
--   record_counter_shot() one vaccine typed in off the paper the owner brought
--   update_client()       a typo in the owner's details put right
--   update_dog()          the same for the dog
--
-- Breeds come from the list. A name that is not on it is almost always a
-- misspelling ("Shitzu"), and saving it would add a second Shih Tzu to the
-- list for good, so it is refused with the nearest names (GR023) unless the
-- groomer says it really is a breed the list lacks. suggest_breeds() gives the
-- screen the same nearest names as the groomer types.
--
-- An edit records what each changed field was before and after. It asks for no
-- reason: a typo needs no explanation, and the reason prompt is kept for the
-- changes that need one (a style edit, a regulatory rule).
--
-- A shot entered at the counter is 'manual' and 'unverified': nobody has yet
-- checked it against the page, so the dog reads "Received, awaiting
-- verification". The shop already treats that state as fit to groom
-- (compliance_state_meta), so the walk-in can be groomed today, and the
-- manager's Admin view lists it until someone verifies it.
--
-- The rule the project is organised around holds here too: no expiry printed,
-- no record. The counter cannot type one in from memory, and the system does
-- not infer one.
--
--   GR021  a counter-entered shot whose dates cannot go on a vaccination
--          record: no expiry, no date given, given in the future, or expiring
--          before it was given
--   GR022  a counter-entered shot that disagrees with one already on file for
--          that dog: the same vaccine given within a few days, with different
--          dates. Choosing between them is a manager's job.
--   GR023  a breed that is not on the list, without saying it is a new one
-- =============================================================================

SET search_path = groom, public;

INSERT INTO policy_enforcement (error_code, level, relaxable, description) VALUES
  ('GR021', 'block', false, 'A shot entered at the counter with dates that cannot go on a vaccination record'),
  ('GR022', 'block', false, 'A shot entered at the counter that disagrees with one already on file'),
  ('GR023', 'block', false, 'A breed not on the list, saved without saying it is a new breed');

-- Similar-name matching, for "did you mean".
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;

-- Blank answers from a form are no answer at all.
CREATE FUNCTION nullif_blank(p_value text) RETURNS text
  LANGUAGE sql IMMUTABLE AS $$ SELECT nullif(btrim(p_value), '') $$;

-- -----------------------------------------------------------------------------
-- The owner
-- -----------------------------------------------------------------------------

CREATE FUNCTION add_client(p_first_name text, p_last_name text, p_phone text, p_email text,
                           p_added_by uuid)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_id    uuid;
    v_email text := lower(nullif_blank(p_email));
BEGIN
    IF nullif_blank(p_first_name) IS NULL OR nullif_blank(p_last_name) IS NULL THEN
        RAISE EXCEPTION 'A new client needs a first and a last name'
            USING ERRCODE = 'check_violation';
    END IF;
    -- The email is how the shop tells two owners apart; the same one twice is
    -- the same person.
    IF v_email IS NOT NULL AND EXISTS (SELECT 1 FROM owner o WHERE lower(o.email) = v_email) THEN
        RAISE EXCEPTION 'An owner with the email % is already on file', v_email
            USING ERRCODE = 'unique_violation',
                  HINT = 'Search by owner to find them, and add the dog to their record.';
    END IF;

    INSERT INTO owner (first_name, last_name, phone, email)
    VALUES (nullif_blank(p_first_name), nullif_blank(p_last_name), nullif_blank(p_phone), v_email)
    RETURNING id INTO v_id;

    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    SELECT p_added_by, g.display_name, 'create', 'owner', v_id, jsonb_build_object('source', 'walk_in')
      FROM groomer g WHERE g.id = p_added_by;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No such groomer: %', p_added_by USING ERRCODE = 'foreign_key_violation';
    END IF;
    RETURN v_id;
END $$;

-- -----------------------------------------------------------------------------
-- The dog, and its breed
--
-- A mix is the dog's main breed, is_mixed, and the other breed when the owner
-- knows it. "Shih Tzu mix" is a Shih Tzu, mixed, other breed unknown; "Mixed
-- breed" is no main breed at all, mixed. A cross with a name of its own (a
-- Cavapoo) is a breed on the list, not a mix.
-- -----------------------------------------------------------------------------

ALTER TABLE dog
    ADD COLUMN is_mixed        boolean NOT NULL DEFAULT false,
    ADD COLUMN second_breed_id uuid REFERENCES breed(id) ON DELETE RESTRICT,
    ADD CONSTRAINT second_breed_is_a_mix CHECK (
        second_breed_id IS NULL
     OR (is_mixed AND breed_id IS NOT NULL AND second_breed_id <> breed_id));

CREATE FUNCTION breed_label(p_breed_id uuid, p_is_mixed boolean, p_second_breed_id uuid)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN b1.name IS NULL AND p_is_mixed THEN 'Mixed breed'
        WHEN b1.name IS NULL                THEN NULL
        WHEN b2.name IS NOT NULL            THEN b1.name || ' × ' || b2.name
        WHEN p_is_mixed                     THEN b1.name || ' mix'
        ELSE b1.name END
      FROM (SELECT 1) one
      LEFT JOIN breed b1 ON b1.id = p_breed_id
      LEFT JOIN breed b2 ON b2.id = p_second_breed_id
$$;

-- The nearest names on the list to what was typed, best first. Spaces and
-- punctuation are ignored, so "Shitzu" finds Shih Tzu and "husky" finds
-- Siberian Husky.
CREATE FUNCTION suggest_breeds(p_text text, p_limit integer DEFAULT 3)
RETURNS TABLE (name text, coat text) LANGUAGE sql STABLE AS $$
    SELECT b.name, ct.code
      FROM breed b
      JOIN coat_type ct ON ct.id = b.default_coat_type_id
      CROSS JOIN LATERAL (
          SELECT greatest(
                   similarity(lower(regexp_replace(p_text, '[^[:alnum:]]', '', 'g')),
                              lower(regexp_replace(b.name, '[^[:alnum:]]', '', 'g'))),
                   word_similarity(lower(p_text), lower(b.name))) AS score) m
     WHERE nullif_blank(p_text) IS NOT NULL AND m.score >= 0.3
     ORDER BY m.score DESC, b.name
     LIMIT p_limit
$$;

-- The breed a typed name means: the one on the list by that name (in any
-- case), NULL for a blank, or — only when the groomer says it is new — a new
-- breed with this dog's coat as its usual coat. Anything else is GR023.
CREATE FUNCTION resolve_breed(p_text text, p_is_new boolean, p_coat_id uuid)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_name text := nullif_blank(p_text);
    v_id   uuid;
    v_near text;
BEGIN
    IF v_name IS NULL THEN
        RETURN NULL;
    END IF;
    SELECT b.id INTO v_id FROM breed b WHERE lower(b.name) = lower(v_name);
    IF FOUND THEN
        RETURN v_id;
    END IF;
    IF NOT COALESCE(p_is_new, false) OR p_coat_id IS NULL THEN
        SELECT string_agg(s.name, ', ') INTO v_near FROM suggest_breeds(v_name) s;
        RAISE EXCEPTION '"%" is not on the breed list', v_name
            USING ERRCODE = 'GR023',
                  HINT = CASE WHEN v_near IS NOT NULL THEN 'Did you mean ' || v_near || '? ' ELSE '' END
                         || 'If it really is a breed the list lacks, add it as a new breed.';
    END IF;
    INSERT INTO breed (name, default_coat_type_id, is_mixed)
    VALUES (v_name, p_coat_id, false)
    RETURNING id INTO v_id;
    RETURN v_id;
END $$;

-- The coat the groomer chose, or the main breed's usual coat when left blank.
CREATE FUNCTION choose_coat(p_coat_code text, p_breed_text text)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_coat_id uuid;
BEGIN
    IF nullif_blank(p_coat_code) IS NOT NULL THEN
        SELECT ct.id INTO v_coat_id FROM coat_type ct WHERE ct.code = p_coat_code;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown coat type: %', p_coat_code USING ERRCODE = 'check_violation';
        END IF;
        RETURN v_coat_id;
    END IF;
    SELECT b.default_coat_type_id INTO v_coat_id
      FROM breed b WHERE lower(b.name) = lower(nullif_blank(p_breed_text));
    IF v_coat_id IS NULL THEN
        RAISE EXCEPTION 'Choose the dog''s coat type'
            USING ERRCODE = 'check_violation',
                  HINT = 'The coat decides the clippers, combs and cuts the system suggests.';
    END IF;
    RETURN v_coat_id;
END $$;

CREATE FUNCTION add_dog(p_owner_id uuid, p_name text, p_breed text, p_coat_code text,
                        p_sex dog_sex, p_date_of_birth date, p_added_by uuid,
                        p_is_mixed boolean DEFAULT false, p_second_breed text DEFAULT NULL,
                        p_new_breed boolean DEFAULT false)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_id        uuid;
    v_coat_id   uuid;
    v_breed_id  uuid;
    v_second_id uuid;
    v_actor     text;
BEGIN
    IF nullif_blank(p_name) IS NULL THEN
        RAISE EXCEPTION 'A new dog needs a name' USING ERRCODE = 'check_violation';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM owner o WHERE o.id = p_owner_id) THEN
        RAISE EXCEPTION 'No such owner: %', p_owner_id USING ERRCODE = 'foreign_key_violation';
    END IF;
    SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_added_by;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No such groomer: %', p_added_by USING ERRCODE = 'foreign_key_violation';
    END IF;

    -- The coat drives the work, so it is the groomer's call, not the breed
    -- label's. A known breed only fills it in when the groomer leaves it blank.
    v_coat_id   := choose_coat(p_coat_code, p_breed);
    v_breed_id  := resolve_breed(p_breed, p_new_breed, v_coat_id);
    -- The second breed is only ever picked from the list: a new breed is added
    -- as a dog's main breed, where its coat means something.
    v_second_id := resolve_breed(p_second_breed, false, NULL);

    INSERT INTO dog (owner_id, name, breed_id, coat_type_id, sex, date_of_birth, is_mixed, second_breed_id)
    VALUES (p_owner_id, nullif_blank(p_name), v_breed_id, v_coat_id, COALESCE(p_sex, 'unknown'),
            p_date_of_birth, COALESCE(p_is_mixed, false) OR v_second_id IS NOT NULL, v_second_id)
    RETURNING id INTO v_id;

    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    VALUES (p_added_by, v_actor, 'create', 'dog', v_id,
            jsonb_build_object('source', 'walk_in', 'owner_id', p_owner_id));
    RETURN v_id;
END $$;

-- -----------------------------------------------------------------------------
-- A shot typed in off the paper
--
-- Returns the record's id. Typing in a shot that is already on file with the
-- same dates returns the record already there, so pressing Save twice is one
-- record. The same vaccine given within duplicate_shot_window_days() of a
-- record on file, with any date different, is GR022: two papers disagree.
-- -----------------------------------------------------------------------------

CREATE FUNCTION record_counter_shot(p_dog_id uuid, p_vaccine_code text, p_administered_on date,
                                    p_expires_on date, p_entered_by uuid)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_vaccine   record;
    v_existing  record;
    v_id        uuid;
    v_actor     text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dog d WHERE d.id = p_dog_id AND d.is_active) THEN
        RAISE EXCEPTION 'Dog % is not an active client', p_dog_id;
    END IF;
    SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_entered_by;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No such groomer: %', p_entered_by USING ERRCODE = 'foreign_key_violation';
    END IF;
    SELECT vt.id, vt.name INTO v_vaccine FROM vaccine_type vt WHERE vt.code = p_vaccine_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vaccine: %', p_vaccine_code USING ERRCODE = 'check_violation';
    END IF;

    -- GR021
    IF p_expires_on IS NULL THEN
        RAISE EXCEPTION '%: no expiry date, so it cannot be recorded', v_vaccine.name
            USING ERRCODE = 'GR021',
                  HINT = 'A record needs the expiry date the vet printed, and the system never guesses one. Ask the owner for a certificate that shows it, or call the vet.';
    END IF;
    IF p_administered_on IS NULL THEN
        RAISE EXCEPTION '%: no date given, so it cannot be recorded', v_vaccine.name
            USING ERRCODE = 'GR021',
                  HINT = 'Type the date the shot was given, as the paper prints it.';
    END IF;
    IF p_administered_on > CURRENT_DATE THEN
        RAISE EXCEPTION '%: given % is in the future', v_vaccine.name, p_administered_on
            USING ERRCODE = 'GR021',
                  HINT = 'Check the date the shot was given against the paper.';
    END IF;
    IF p_expires_on <= p_administered_on THEN
        RAISE EXCEPTION '%: expires % is not after it was given (%)', v_vaccine.name, p_expires_on, p_administered_on
            USING ERRCODE = 'GR021',
                  HINT = 'The two dates may be the wrong way round. Check them against the paper.';
    END IF;

    -- The same shot, or a disagreement about it.
    SELECT vr.id, vr.administered_on, vr.expires_on INTO v_existing
      FROM vaccination_record vr
     WHERE vr.dog_id = p_dog_id AND vr.vaccine_type_id = v_vaccine.id
       AND vr.administered_on BETWEEN p_administered_on - duplicate_shot_window_days()
                                  AND p_administered_on + duplicate_shot_window_days()
     ORDER BY (vr.administered_on = p_administered_on AND vr.expires_on = p_expires_on) DESC,
              abs(vr.administered_on - p_administered_on)
     LIMIT 1;
    IF FOUND THEN
        IF v_existing.administered_on = p_administered_on AND v_existing.expires_on = p_expires_on THEN
            RETURN v_existing.id;
        END IF;
        RAISE EXCEPTION '%: already on file as given % and expiring %', v_vaccine.name,
                        v_existing.administered_on, v_existing.expires_on
            USING ERRCODE = 'GR022',
                  HINT = 'The paper and the record on file disagree. Leave the record as it is and ask a manager to compare them in the records tool.';
    END IF;

    INSERT INTO vaccination_record (dog_id, vaccine_type_id, administered_on, expires_on,
                                    entry_method, verification_status)
    VALUES (p_dog_id, v_vaccine.id, p_administered_on, p_expires_on, 'manual', 'unverified')
    RETURNING id INTO v_id;

    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    VALUES (p_entered_by, v_actor, 'create', 'vaccination_record', v_id,
            jsonb_build_object('source', 'counter', 'vaccine', p_vaccine_code,
                               'administered_on', p_administered_on, 'expires_on', p_expires_on));

    -- The owner has brought the paper the shop was asking for: stop asking. An
    -- old certificate does not answer the request, as in confirm_extraction().
    IF p_expires_on >= CURRENT_DATE THEN
        UPDATE record_request rr
           SET status = 'resolved', resolved_at = now(), next_reminder_on = NULL
         WHERE rr.dog_id = p_dog_id AND rr.vaccine_type_id = v_vaccine.id
           AND rr.status IN ('queued', 'sent', 'responded', 'insufficient');
    END IF;
    RETURN v_id;
END $$;

COMMENT ON FUNCTION record_counter_shot(uuid, text, date, date, uuid) IS
  'A vaccine typed in at the counter off the owner''s paper: manual, unverified, '
  'so the dog can be groomed and a manager verifies it later. No expiry, no record (GR021).';

-- -----------------------------------------------------------------------------
-- Putting a typo right
--
-- Each takes the whole form as it now stands, writes it, and records in the
-- audit log only the fields that changed, before and after, in words (the
-- breed's name, not its id). Saving with nothing changed records nothing.
-- Returns what changed.
-- -----------------------------------------------------------------------------

CREATE FUNCTION owner_details(p_owner_id uuid) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('first_name', o.first_name, 'last_name', o.last_name,
                              'phone', o.phone, 'email', o.email)
      FROM owner o WHERE o.id = p_owner_id
$$;

CREATE FUNCTION update_client(p_owner_id uuid, p_first_name text, p_last_name text, p_phone text,
                              p_email text, p_edited_by uuid)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_before jsonb := owner_details(p_owner_id);
    v_email  text  := lower(nullif_blank(p_email));
    v_actor  text;
    v_diff   jsonb;
BEGIN
    IF v_before IS NULL THEN
        RAISE EXCEPTION 'No such owner: %', p_owner_id USING ERRCODE = 'foreign_key_violation';
    END IF;
    SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_edited_by;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No such groomer: %', p_edited_by USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF nullif_blank(p_first_name) IS NULL OR nullif_blank(p_last_name) IS NULL THEN
        RAISE EXCEPTION 'An owner needs a first and a last name' USING ERRCODE = 'check_violation';
    END IF;
    IF v_email IS NOT NULL
       AND EXISTS (SELECT 1 FROM owner o WHERE lower(o.email) = v_email AND o.id <> p_owner_id) THEN
        RAISE EXCEPTION 'Another owner already has the email %', v_email
            USING ERRCODE = 'unique_violation',
                  HINT = 'Check the email with the owner. Two owners cannot share one.';
    END IF;

    UPDATE owner
       SET first_name = nullif_blank(p_first_name), last_name = nullif_blank(p_last_name),
           phone = nullif_blank(p_phone), email = v_email
     WHERE id = p_owner_id;

    v_diff := jsonb_diff(v_before, owner_details(p_owner_id));
    IF v_diff <> '{}' THEN
        INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
        VALUES (p_edited_by, v_actor, 'update', 'owner', p_owner_id, v_diff);
    END IF;
    RETURN v_diff;
END $$;

CREATE FUNCTION dog_details(p_dog_id uuid) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object('name', d.name,
                              'breed', breed_label(d.breed_id, d.is_mixed, d.second_breed_id),
                              'coat', ct.code, 'sex', d.sex, 'date_of_birth', d.date_of_birth)
      FROM dog d JOIN coat_type ct ON ct.id = d.coat_type_id
     WHERE d.id = p_dog_id AND d.is_active
$$;

CREATE FUNCTION update_dog(p_dog_id uuid, p_name text, p_breed text, p_coat_code text,
                           p_sex dog_sex, p_date_of_birth date, p_edited_by uuid,
                           p_is_mixed boolean DEFAULT false, p_second_breed text DEFAULT NULL,
                           p_new_breed boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_before    jsonb := dog_details(p_dog_id);
    v_actor     text;
    v_coat_id   uuid;
    v_breed_id  uuid;
    v_second_id uuid;
    v_diff      jsonb;
BEGIN
    IF v_before IS NULL THEN
        RAISE EXCEPTION 'Dog % is not an active client', p_dog_id;
    END IF;
    SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_edited_by;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No such groomer: %', p_edited_by USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF nullif_blank(p_name) IS NULL THEN
        RAISE EXCEPTION 'A dog needs a name' USING ERRCODE = 'check_violation';
    END IF;

    v_coat_id   := choose_coat(p_coat_code, p_breed);
    v_breed_id  := resolve_breed(p_breed, p_new_breed, v_coat_id);
    v_second_id := resolve_breed(p_second_breed, false, NULL);

    UPDATE dog
       SET name = nullif_blank(p_name), breed_id = v_breed_id, coat_type_id = v_coat_id,
           sex = COALESCE(p_sex, 'unknown'), date_of_birth = p_date_of_birth,
           is_mixed = COALESCE(p_is_mixed, false) OR v_second_id IS NOT NULL,
           second_breed_id = v_second_id
     WHERE id = p_dog_id;

    v_diff := jsonb_diff(v_before, dog_details(p_dog_id));
    IF v_diff <> '{}' THEN
        INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
        VALUES (p_edited_by, v_actor, 'update', 'dog', p_dog_id, v_diff);
    END IF;
    RETURN v_diff;
END $$;
