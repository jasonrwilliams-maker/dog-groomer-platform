-- =============================================================================
-- 28. A manager verifies a shot, or puts a wrong one right
--
-- Two gaps the manager's lists left open:
--
--   * A shot typed in at the counter with no photo (record_counter_shot(),
--     section 22) sat under "Waiting to be verified" for good. The only way to
--     clear it was to type it in again against a photo. Now a manager can
--     verify it where it is, by saying how they checked it: they saw the
--     owner's paper, or called the vet's office. That is kept on the record,
--     because "verified" with nothing behind it is what an inspector asks
--     about.
--   * A shot a groomer checked by hand against a photo (section 26) could only
--     be passed ("Matches the photo") or left on the list. When the manager
--     finds a date misread, they now fix it there: the record takes the
--     manager's dates, and that counts as its second look. It still says who
--     checked it by hand, and now who fixed it too, so the shop can see whose
--     counter checks need fixing. The groomer's dates are kept in the audit
--     log, before and after, so the mistake can be talked through.
--
-- A fix also puts the AI's grade right. When the AI read the copy and the
-- groomer kept its date, the AI was graded right (section 27). If the manager
-- then finds that date wrong, so was the AI: its grade for the shot's dates is
-- redone against the manager's. Otherwise the scoreboard would count the very
-- mistake it exists to catch, a confident wrong date, as a success.
--
-- A shot verified some other way (a manager who called the vet) was verified
-- for its old dates, not its new ones. Fixing its dates sends it back to
-- "Waiting to be verified", to be checked again.
--
-- Both are a manager's (GR030). Fixed dates are held to the same rules as
-- dates typed in at the counter: no expiry, no record, and nothing given in
-- the future (GR021); a fix that makes it disagree with another record on
-- file for the same shot is a manager's job in the records tool (GR022).
-- A record read by the AI and confirmed in the records tool is fixed there,
-- where its reading is graded, not here.
--
--   GR030  a shot verified or fixed by someone who is not a manager
-- =============================================================================

SET search_path = groom, public;

INSERT INTO policy_enforcement (error_code, level, relaxable, description) VALUES
  ('GR030', 'block', false, 'A vaccination record verified or fixed by someone who is not a manager');

ALTER TABLE vaccination_record
    ADD COLUMN verified_how text,
    ADD COLUMN fixed_by     uuid REFERENCES groomer(id) ON DELETE RESTRICT,
    ADD COLUMN fixed_at     timestamptz,
    ADD CONSTRAINT fixed_coherent CHECK ((fixed_by IS NULL) = (fixed_at IS NULL));
COMMENT ON COLUMN vaccination_record.fixed_by IS
  'The manager who last put this shot''s dates right. Whoever checked it before '
  'stays in verified_by; the dates they typed are in the audit log.';
COMMENT ON COLUMN vaccination_record.verified_how IS
  'How a manager checked a shot that had no copy of the paperwork behind it '
  '("Called the vet''s office"). Empty when the record was checked against a copy.';

-- The manager, or GR030. Returns the name the audit log keeps.
CREATE FUNCTION require_manager(p_groomer_id uuid, p_doing text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_actor text;
BEGIN
    SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_groomer_id AND g.role = 'manager';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Only a manager can %', p_doing
            USING ERRCODE = 'GR030',
                  HINT = 'It stays on the manager''s list until a manager looks at it.';
    END IF;
    RETURN v_actor;
END $$;

-- -----------------------------------------------------------------------------
-- Verifying a shot typed in with no photo
-- -----------------------------------------------------------------------------

CREATE FUNCTION verify_counter_shot(p_record_id uuid, p_how text, p_manager_id uuid)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_actor text := require_manager(p_manager_id, 'verify a shot');
    v_how   text := nullif_blank(p_how);
BEGIN
    IF v_how IS NULL THEN
        RAISE EXCEPTION 'Say how you checked it: you saw the owner''s paper, or called the vet'
            USING ERRCODE = 'check_violation';
    END IF;
    UPDATE vaccination_record
       SET verification_status = 'verified', verified_by = p_manager_id, verified_at = now(),
           verified_how = v_how
     WHERE id = p_record_id AND verification_status = 'unverified';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No shot waiting to be verified with id %', p_record_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;
    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    VALUES (p_manager_id, v_actor, 'update', 'vaccination_record', p_record_id,
            jsonb_build_object('verification_status', 'verified', 'verified_how', v_how));
END $$;

COMMENT ON FUNCTION verify_counter_shot(uuid, text, uuid) IS
  'A manager verifies a shot that is waiting to be, saying how they checked it (GR030).';

-- -----------------------------------------------------------------------------
-- Fixing a shot's dates
--
-- The record keeps its id, so anything that points at it still does. A
-- hand-checked record keeps the name of whoever checked it, and the fix is its
-- second look. One still waiting to be verified stays waiting unless the
-- manager verifies it too (the API does both in one go). One verified some
-- other way goes back to waiting (see the top of this file).
-- -----------------------------------------------------------------------------

CREATE FUNCTION correct_counter_shot(p_record_id uuid, p_administered_on date, p_expires_on date,
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
        RAISE EXCEPTION '%: this record was read from paperwork in the records tool', v_rec.vaccine
            USING ERRCODE = 'check_violation',
                  HINT = 'Fix it in the records tool, where the reading it came from is kept.';
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
                  HINT = 'Two records for the same shot. Compare them in the records tool.';
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

COMMENT ON FUNCTION correct_counter_shot(uuid, date, date, uuid) IS
  'A manager puts a shot''s dates right (GR030), held to the counter''s rules (GR021, GR022). '
  'A hand-checked record takes the fix as its second look; the AI''s grade for those dates is redone.';

-- -----------------------------------------------------------------------------
-- The manager's list of shots waiting to be verified
-- -----------------------------------------------------------------------------

CREATE VIEW v_waiting_verification AS
SELECT vr.id, vr.dog_id, d.name AS dog, o.first_name || ' ' || o.last_name AS owner,
       vt.code AS vaccine_code, vt.name AS vaccine, vr.administered_on, vr.expires_on,
       vr.entry_method::text AS entry_method, typed.actor_label AS entered_by, vr.created_at AS entered_at
  FROM vaccination_record vr
  JOIN vaccine_type vt ON vt.id = vr.vaccine_type_id
  JOIN dog d           ON d.id = vr.dog_id
  JOIN owner o         ON o.id = d.owner_id
  LEFT JOIN LATERAL (SELECT a.actor_label FROM audit_log a
                      WHERE a.entity_type = 'vaccination_record' AND a.entity_id = vr.id AND a.action = 'create'
                      ORDER BY a.occurred_at LIMIT 1) typed ON true
 WHERE vr.verification_status = 'unverified' AND d.is_active
 ORDER BY vr.created_at;
