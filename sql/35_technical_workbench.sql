-- =============================================================================
-- 35. The Technical workbench's name
--
-- The records tool (extraction/review/, port 8501) is now called the
-- Technical workbench. It is for the person responsible for the database,
-- not for managers day to day, and Admin no longer links to it.
--
-- Three refusals a manager or groomer reads named the old tool and sent them
-- to it. Sections 22 and 28 are merged and stay as they are, so the two
-- functions are made again here, the same but for those words:
--
--   record_counter_shot()   GR022: tell a manager; the person responsible
--                           for the database compares the two records
--   correct_counter_shot()  a record read from paperwork, and GR022: tell the
--                           person responsible for the database
--
-- Nothing else changes: no rule, no code, no column.
-- =============================================================================

SET search_path = groom, public;

-- -----------------------------------------------------------------------------
-- From section 22: a vaccine typed in at the counter
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION record_counter_shot(p_dog_id uuid, p_vaccine_code text, p_administered_on date,
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
                  HINT = 'The paper and the record on file disagree. Leave the record as it is and tell a manager; the person responsible for the database compares the two records.';
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


-- -----------------------------------------------------------------------------
-- From section 28: a manager fixing a shot's dates
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION correct_counter_shot(p_record_id uuid, p_administered_on date, p_expires_on date,
                                     p_manager_id uuid)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_actor  text := require_manager(p_manager_id, 'fix a shot''s dates');
    v_rec      record;
    v_other    record;
    v_reopened boolean;
    v_regraded integer;
BEGIN
    SELECT vr.*, vt.name AS vaccine INTO v_rec
      FROM vaccination_record vr JOIN vaccine_type vt ON vt.id = vr.vaccine_type_id
     WHERE vr.id = p_record_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No vaccination record with id %', p_record_id USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF v_rec.entry_method = 'extracted' THEN
        RAISE EXCEPTION '%: this record was read from paperwork in the Technical workbench', v_rec.vaccine
            USING ERRCODE = 'check_violation',
                  HINT = 'Tell the person responsible for the database; they fix it in the Technical workbench, where the reading it came from is kept.';
    END IF;
    IF v_rec.administered_on = p_administered_on AND v_rec.expires_on = p_expires_on THEN
        RETURN;     -- nothing changed
    END IF;

    -- GR021, as at the counter.
    IF p_expires_on IS NULL THEN
        RAISE EXCEPTION '%: no expiry date, so it cannot be recorded', v_rec.vaccine
            USING ERRCODE = 'GR021',
                  HINT = 'A record needs the expiry date the vet printed, and the system never guesses one.';
    END IF;
    IF p_administered_on IS NULL THEN
        RAISE EXCEPTION '%: no date given, so it cannot be recorded', v_rec.vaccine
            USING ERRCODE = 'GR021', HINT = 'Type the date the shot was given, as the paper prints it.';
    END IF;
    IF p_administered_on > CURRENT_DATE THEN
        RAISE EXCEPTION '%: given % is in the future', v_rec.vaccine, p_administered_on
            USING ERRCODE = 'GR021', HINT = 'Check the date the shot was given against the paper.';
    END IF;
    IF p_expires_on <= p_administered_on THEN
        RAISE EXCEPTION '%: expires % is not after it was given (%)', v_rec.vaccine, p_expires_on, p_administered_on
            USING ERRCODE = 'GR021',
                  HINT = 'The two dates may be the wrong way round. Check them against the paper.';
    END IF;

    -- GR022: now the same shot as another record on file.
    SELECT vr.administered_on, vr.expires_on INTO v_other
      FROM vaccination_record vr
     WHERE vr.dog_id = v_rec.dog_id AND vr.vaccine_type_id = v_rec.vaccine_type_id AND vr.id <> p_record_id
       AND vr.administered_on BETWEEN p_administered_on - duplicate_shot_window_days()
                                  AND p_administered_on + duplicate_shot_window_days()
     ORDER BY abs(vr.administered_on - p_administered_on) LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION '%: another record on file is given % and expiring %', v_rec.vaccine,
                        v_other.administered_on, v_other.expires_on
            USING ERRCODE = 'GR022',
                  HINT = 'Two records for the same shot. Tell the person responsible for the database; they compare the two records.';
    END IF;

    v_reopened := v_rec.verification_status = 'verified' AND NOT v_rec.checked_by_hand;
    UPDATE vaccination_record
       SET administered_on = p_administered_on, expires_on = p_expires_on,
           fixed_by = p_manager_id, fixed_at = now(),
           second_look_by = CASE WHEN checked_by_hand THEN p_manager_id ELSE second_look_by END,
           second_look_at = CASE WHEN checked_by_hand THEN now() ELSE second_look_at END,
           verification_status = CASE WHEN v_reopened THEN 'unverified' ELSE verification_status END,
           verified_by  = CASE WHEN v_reopened THEN NULL ELSE verified_by END,
           verified_at  = CASE WHEN v_reopened THEN NULL ELSE verified_at END,
           verified_how = CASE WHEN v_reopened THEN NULL ELSE verified_how END
     WHERE id = p_record_id;

    -- The AI's grade for the dates it gave this shot, redone against the
    -- manager's: right only if it read what the manager now says.
    WITH lines AS (
        SELECT li.line_item_id
          FROM v_extraction_line_item li
          JOIN extraction e    ON e.id = li.extraction_id
          JOIN vaccine_type vt ON vt.code = li.vaccine_code
         WHERE e.read_at_counter AND e.document_id = v_rec.document_id
           AND vt.id = v_rec.vaccine_type_id
           AND iso_date_or_null(li.administered_on) = v_rec.administered_on
           AND iso_date_or_null(li.expires_on)      = v_rec.expires_on
    ), regraded AS (
        UPDATE extraction_field ef
           SET correction_action = CASE WHEN ef.extracted_value IS NOT DISTINCT FROM s.value
                                        THEN 'confirmed' ELSE 'edited' END::correction_action,
               corrected_value   = CASE WHEN ef.extracted_value IS NOT DISTINCT FROM s.value THEN NULL ELSE s.value END
          FROM (VALUES ('administered_on', p_administered_on::text), ('expires_on', p_expires_on::text)) s(field, value)
         WHERE ef.line_item_id IN (SELECT line_item_id FROM lines) AND ef.field_name = s.field
           AND ef.correction_action IN ('confirmed', 'edited')
        RETURNING 1)
    SELECT count(*) INTO v_regraded FROM regraded;

    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    VALUES (p_manager_id, v_actor, 'update', 'vaccination_record', p_record_id,
            jsonb_build_object('fixed_by_manager', true,
                               'administered_on', jsonb_build_object('before', v_rec.administered_on, 'after', p_administered_on),
                               'expires_on',      jsonb_build_object('before', v_rec.expires_on, 'after', p_expires_on))
            || CASE WHEN v_rec.checked_by_hand THEN jsonb_build_object('second_look', true) ELSE '{}' END
            || CASE WHEN v_reopened THEN jsonb_build_object('verification_status', 'unverified') ELSE '{}' END
            || CASE WHEN v_regraded > 0 THEN jsonb_build_object('ai_dates_regraded', v_regraded) ELSE '{}' END);

    -- Current now: the shop can stop asking the owner for it, as at the counter.
    IF p_expires_on >= CURRENT_DATE THEN
        UPDATE record_request rr
           SET status = 'resolved', resolved_at = now(), next_reminder_on = NULL
         WHERE rr.dog_id = v_rec.dog_id AND rr.vaccine_type_id = v_rec.vaccine_type_id
           AND rr.status IN ('queued', 'sent', 'responded', 'insufficient');
    END IF;
END $$;


COMMENT ON COLUMN extraction.read_at_counter IS
  'Read from a copy taken at the counter, on request, and graded there by the '
  'person who checked it. Not offered on the Technical workbench''s Confirm screen.';
