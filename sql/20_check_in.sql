-- =============================================================================
-- 20. Check-in
--
-- The first thing the groomer interface does is open a groom. Until now
-- nothing stopped one from starting for a dog whose rabies had lapsed:
-- v_dog_compliance_status.blocks_service was a flag a dashboard could read and
-- a person could ignore.
--
-- start_visit() is the only way the interface opens a visit, and it refuses
-- while any service-blocking vaccine is not in order (GR020). What blocks is
-- configuration that already exists — vaccine_type.blocks_service_if_expired
-- per vaccine, compliance_state_meta.blocks_service per state — so this
-- section adds a door, not a rule of its own.
--
-- What it deliberately does NOT do is guard the visit table. The README's
-- rule holds: a system of record that refuses to record what happened is
-- worse than useless. A visit that already took place can still be entered
-- as history; it is starting one now, through the front door, that is refused.
--
--   GR020  a groom started for a dog whose service-blocking vaccine is
--          expired, missing, disputed, or still being chased
-- =============================================================================

SET search_path = groom, public;

INSERT INTO policy_enforcement (error_code, level, relaxable, description) VALUES
  ('GR020', 'block', false, 'Groom started while a service-blocking vaccine is not in order');

-- Visits are dated where the shop is, not where the database server is. A
-- groom at 8pm in Maryland is that day's groom, though it is tomorrow in UTC.
INSERT INTO shop_policy (key, value_type, text_value, description) VALUES
  ('shop_time_zone', 'text', 'America/New_York',
   'The shop''s time zone. Check-in dates and times are recorded in it.');

CREATE FUNCTION shop_now() RETURNS timestamp
  LANGUAGE sql STABLE AS $$ SELECT now() AT TIME ZONE shop_policy_text('shop_time_zone') $$;

-- -----------------------------------------------------------------------------
-- The check-in card's vaccine lines
--
-- One row per dog per tracked vaccine, worded for the counter: the state, its
-- label (with the live warning window, as on the dashboard), the expiry, and
-- whether this line alone stops the groom.
-- -----------------------------------------------------------------------------

CREATE VIEW v_check_in_vaccine AS
SELECT v.dog_id,
       v.vaccine_code,
       vt.name                        AS vaccine,
       v.state,
       CASE WHEN v.state = 'expiring_soon'
            THEN format('Expiring within %s days', expiry_warning_days())
            ELSE m.plain_language_label END AS label,
       v.expires_on,
       v.days_until_expiry,
       v.regulatory_required,
       (m.blocks_service AND v.blocks_service_if_expired) AS blocks_service,
       m.actionable,
       m.sort_order
  FROM v_dog_vaccine_compliance v
  JOIN vaccine_type vt          ON vt.id = v.vaccine_type_id
  JOIN compliance_state_meta m  ON m.state = v.state;

COMMENT ON VIEW v_check_in_vaccine IS
  'What the check-in card shows per vaccine. blocks_service is the line-level '
  'reason a groom cannot start; start_visit() refuses on any of them.';

-- -----------------------------------------------------------------------------
-- Starting a groom
-- -----------------------------------------------------------------------------

CREATE FUNCTION start_visit(p_dog_id uuid, p_groomer_id uuid) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v_now      timestamp := shop_now();
    v_visit_id uuid;
    v_blocking text;
    v_actor    text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dog d WHERE d.id = p_dog_id AND d.is_active) THEN
        RAISE EXCEPTION 'Dog % is not an active client', p_dog_id
            USING HINT = 'Reactivate the dog''s record before booking a groom.';
    END IF;

    -- Already checked in today and not yet out: the same visit, not a second one.
    SELECT v.id INTO v_visit_id
      FROM visit v
     WHERE v.dog_id = p_dog_id AND v.visit_date = v_now::date AND v.check_out IS NULL
     ORDER BY v.created_at DESC LIMIT 1;
    IF FOUND THEN
        RETURN v_visit_id;
    END IF;

    -- GR020. Every blocking line, named, so the counter knows what to ask for.
    SELECT string_agg(format('%s (%s)', c.vaccine, lower(c.label)), ', ' ORDER BY c.sort_order, c.vaccine)
      INTO v_blocking
      FROM v_check_in_vaccine c
     WHERE c.dog_id = p_dog_id AND c.blocks_service;
    IF v_blocking IS NOT NULL THEN
        RAISE EXCEPTION 'Cannot start the groom: %', v_blocking
            USING ERRCODE = 'GR020',
                  HINT = 'Ask the owner for a current certificate. Once it is confirmed, check the dog in again.';
    END IF;

    INSERT INTO visit (dog_id, performed_by, visit_date, check_in)
    VALUES (p_dog_id, p_groomer_id, v_now::date, v_now::time(0))
    RETURNING id INTO v_visit_id;

    SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_groomer_id;
    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    VALUES (p_groomer_id, COALESCE(v_actor, current_user), 'create', 'visit', v_visit_id,
            jsonb_build_object('dog_id', p_dog_id, 'check_in', v_now::time(0), 'via', 'start_visit'));
    RETURN v_visit_id;
END $$;

COMMENT ON FUNCTION start_visit(uuid, uuid) IS
  'The interface''s only way to open a visit. Refuses (GR020) while any '
  'service-blocking vaccine is not in order; returns the open visit if the dog '
  'is already checked in today. Entering past visits as history is unaffected.';

ALTER FUNCTION shop_now()                 SET search_path = groom, public;
ALTER FUNCTION start_visit(uuid, uuid)    SET search_path = groom, public;
