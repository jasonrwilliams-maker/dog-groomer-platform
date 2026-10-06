-- =============================================================================
-- 22. Walk-ins
--
-- A new client walks up to the counter with their dog and a copy of its
-- records. Until now the only ways in were the demo seed and the records
-- tool's upload, review and confirm — right for a stack of paperwork, too slow
-- for someone standing at the desk.
--
-- Three doors, each a function so the interface never writes these tables
-- directly, and each audited with who used it:
--
--   add_client()          the owner: a name, and a phone or an email
--   add_dog()             the dog: a name and a coat type. A breed the shop
--                         has not seen before is added to the list, with the
--                         dog's coat as its usual coat.
--   record_counter_shot() one vaccine typed in off the paper the owner brought.
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
-- =============================================================================

SET search_path = groom, public;

INSERT INTO policy_enforcement (error_code, level, relaxable, description) VALUES
  ('GR021', 'block', false, 'A shot entered at the counter with dates that cannot go on a vaccination record'),
  ('GR022', 'block', false, 'A shot entered at the counter that disagrees with one already on file');

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
-- The dog
-- -----------------------------------------------------------------------------

CREATE FUNCTION add_dog(p_owner_id uuid, p_name text, p_breed text, p_coat_code text,
                        p_sex dog_sex, p_date_of_birth date, p_added_by uuid)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_id       uuid;
    v_breed_id uuid;
    v_coat_id  uuid;
    v_breed    text := nullif_blank(p_breed);
BEGIN
    IF nullif_blank(p_name) IS NULL THEN
        RAISE EXCEPTION 'A new dog needs a name' USING ERRCODE = 'check_violation';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM owner o WHERE o.id = p_owner_id) THEN
        RAISE EXCEPTION 'No such owner: %', p_owner_id USING ERRCODE = 'foreign_key_violation';
    END IF;

    SELECT b.id, b.default_coat_type_id INTO v_breed_id, v_coat_id
      FROM breed b WHERE lower(b.name) = lower(v_breed);

    -- The coat drives the work, so it is the groomer's call, not the breed
    -- label's. A known breed only fills it in when the groomer leaves it blank.
    IF nullif_blank(p_coat_code) IS NOT NULL THEN
        SELECT ct.id INTO v_coat_id FROM coat_type ct WHERE ct.code = p_coat_code;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown coat type: %', p_coat_code USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    IF v_coat_id IS NULL THEN
        RAISE EXCEPTION 'Choose the dog''s coat type'
            USING ERRCODE = 'check_violation',
                  HINT = 'The coat decides the clippers, combs and cuts the system suggests.';
    END IF;

    IF v_breed IS NOT NULL AND v_breed_id IS NULL THEN
        INSERT INTO breed (name, default_coat_type_id, is_mixed)
        VALUES (v_breed, v_coat_id, v_breed ~* '\m(mix|mixed|cross|x)\M')
        RETURNING id INTO v_breed_id;
    END IF;

    INSERT INTO dog (owner_id, name, breed_id, coat_type_id, sex, date_of_birth)
    VALUES (p_owner_id, nullif_blank(p_name), v_breed_id, v_coat_id, COALESCE(p_sex, 'unknown'), p_date_of_birth)
    RETURNING id INTO v_id;

    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    SELECT p_added_by, g.display_name, 'create', 'dog', v_id,
           jsonb_build_object('source', 'walk_in', 'owner_id', p_owner_id)
      FROM groomer g WHERE g.id = p_added_by;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No such groomer: %', p_added_by USING ERRCODE = 'foreign_key_violation';
    END IF;
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
