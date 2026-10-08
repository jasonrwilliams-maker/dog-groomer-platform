-- =============================================================================
-- 30. Booking grooms ahead
--
-- Until now a groom existed only once the dog was at the counter (start_visit,
-- section 20). This adds the appointment: a dog, a groomer, a start time and
-- how long it is expected to take, booked by anyone at the counter.
--
-- How long: each service has a usual length (service_type.default_minutes; a
-- full groom, bath and cut, is 90 minutes) and whoever books can change it. A
-- big matted dog can take the whole day, so a booking may run from opening to
-- closing. Bookings are in the shop's own time (shop_now(), section 20) and
-- within its hours (shop_opens, shop_closes in shop_policy).
--
-- Vaccines are a warning at booking, not a refusal. The owner often brings
-- new paperwork before the day, and the check-in screen still stops the groom
-- itself (GR020). appointment_warnings() says what will be out of date by the
-- appointment, so the shop can ask for it in good time.
--
-- Groomers and their clients. A dog's regular groomer is whoever groomed it
-- last (or, before its first groom, whoever it was first booked with). The
-- booking screen offers that groomer first, with their free times, ahead of
-- whoever happens to be free (booking_choices()). Booking a regular client
-- with someone else is allowed, but takes a word on why ("Tanya is on
-- holiday", "owner asked"), and that is kept with the booking (GR032). A new
-- client has no regular groomer, and goes to whoever is free.
--
-- Nobody is in two places at once: a groomer, or a dog, booked over a time
-- they are already booked is refused (GR031). An exclusion constraint backs
-- that up for the groomer, whatever writes the table.
--
--   GR031  a booking over one the groomer, or the dog, already has
--   GR032  a regular client booked with another groomer, without saying why
-- =============================================================================

SET search_path = groom, public;

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;

INSERT INTO policy_enforcement (error_code, level, relaxable, description) VALUES
  ('GR031', 'block', false, 'A booking over one the groomer or the dog already has'),
  ('GR032', 'block', false, 'A regular client booked with another groomer without a reason');

INSERT INTO shop_policy (key, value_type, text_value, description) VALUES
  ('shop_opens',  'text', '08:00', 'When the first groom of the day can start (shop time, HH:MM).'),
  ('shop_closes', 'text', '18:00', 'When the last groom of the day has to be finished (shop time, HH:MM).');
INSERT INTO shop_policy (key, value_type, int_value, description) VALUES
  ('booking_step_minutes', 'integer', 15, 'Start times offered when booking are this many minutes apart.');

CREATE FUNCTION shop_opens()  RETURNS time LANGUAGE sql STABLE AS $$ SELECT shop_policy_text('shop_opens')::time $$;
CREATE FUNCTION shop_closes() RETURNS time LANGUAGE sql STABLE AS $$ SELECT shop_policy_text('shop_closes')::time $$;

-- How long each service usually takes. A full groom is the shop's number; the
-- rest are starting guesses, to be changed in this table.
ALTER TABLE service_type ADD COLUMN default_minutes integer NOT NULL DEFAULT 90
    CHECK (default_minutes BETWEEN 5 AND 720);
UPDATE service_type SET default_minutes = CASE code
    WHEN 'full_groom' THEN 90 WHEN 'bath' THEN 45 WHEN 'deshed' THEN 60
    WHEN 'nail_trim' THEN 15 WHEN 'ear_clean' THEN 15 WHEN 'teeth' THEN 15 ELSE 60 END;

CREATE TYPE appointment_status AS ENUM ('booked', 'cancelled');

CREATE TABLE appointment (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    dog_id                uuid NOT NULL REFERENCES dog(id) ON DELETE RESTRICT,
    groomer_id            uuid NOT NULL REFERENCES groomer(id) ON DELETE RESTRICT,
    service_type_id       uuid NOT NULL REFERENCES service_type(id) ON DELETE RESTRICT,
    starts_at             timestamp NOT NULL,      -- the shop's own time
    minutes               integer NOT NULL CHECK (minutes BETWEEN 5 AND 720),
    ends_at               timestamp GENERATED ALWAYS AS (starts_at + minutes * interval '1 minute') STORED,
    note                  text,
    -- Why a regular client is with someone other than their usual groomer.
    other_groomer_reason  text,
    status                appointment_status NOT NULL DEFAULT 'booked',
    booked_by             uuid NOT NULL REFERENCES groomer(id) ON DELETE RESTRICT,
    booked_at             timestamptz NOT NULL DEFAULT now(),
    cancelled_by          uuid REFERENCES groomer(id) ON DELETE RESTRICT,
    cancelled_at          timestamptz,
    cancel_reason         text,
    CONSTRAINT cancelled_coherent CHECK (
        (status = 'cancelled') = (cancelled_by IS NOT NULL AND cancelled_at IS NOT NULL)),
    CONSTRAINT groomer_not_double_booked EXCLUDE USING gist (
        groomer_id WITH =, tsrange(starts_at, ends_at) WITH &&) WHERE (status = 'booked')
);
CREATE INDEX appointment_day_idx ON appointment (starts_at) WHERE status = 'booked';
CREATE INDEX appointment_dog_idx ON appointment (dog_id, starts_at DESC);
COMMENT ON TABLE appointment IS
  'A groom booked ahead: dog, groomer, start (shop time) and expected length. '
  'Cancelled bookings are kept, with who cancelled and why.';

-- -----------------------------------------------------------------------------
-- Who usually grooms a dog
-- -----------------------------------------------------------------------------

CREATE FUNCTION regular_groomer(p_dog_id uuid) RETURNS uuid
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT v.performed_by FROM visit v JOIN groomer g ON g.id = v.performed_by
          WHERE v.dog_id = p_dog_id AND g.is_active
          ORDER BY v.visit_date DESC, v.created_at DESC LIMIT 1),
        (SELECT a.groomer_id FROM appointment a JOIN groomer g ON g.id = a.groomer_id
          WHERE a.dog_id = p_dog_id AND a.status = 'booked' AND g.is_active
          ORDER BY a.booked_at LIMIT 1))
$$;
COMMENT ON FUNCTION regular_groomer(uuid) IS
  'Whoever groomed the dog last; before its first groom, whoever it was first booked with. NULL for a new client.';

-- -----------------------------------------------------------------------------
-- What will be out of date by the appointment
--
-- The vaccines that stop a groom, as they will stand on the day: not on file,
-- in question, or expired by then. A warning for the booking screen; the
-- check-in screen still decides on the day.
-- -----------------------------------------------------------------------------

CREATE FUNCTION appointment_warnings(p_dog_id uuid, p_on date)
RETURNS TABLE (vaccine text, expires_on date, warning text)
LANGUAGE sql STABLE AS $$
    SELECT c.vaccine, c.expires_on,
           CASE WHEN c.expires_on IS NULL THEN 'none on file'
                WHEN c.expires_on < CURRENT_DATE THEN 'already expired'
                WHEN c.expires_on < p_on THEN 'expires before the appointment'
                ELSE lower(c.label) END
      FROM v_check_in_vaccine c
      JOIN vaccine_type vt ON vt.code = c.vaccine_code
     WHERE c.dog_id = p_dog_id AND vt.blocks_service_if_expired
       AND (c.blocks_service OR c.expires_on IS NULL OR c.expires_on < p_on)
     ORDER BY c.sort_order, c.vaccine
$$;
COMMENT ON FUNCTION appointment_warnings(uuid, date) IS
  'Vaccines that stop a groom and will be missing or expired by the given day. A warning, never a refusal.';

-- -----------------------------------------------------------------------------
-- The checks every booking and every change goes through
-- -----------------------------------------------------------------------------

CREATE FUNCTION check_booking(p_appointment_id uuid, p_dog_id uuid, p_groomer_id uuid,
                              p_starts_at timestamp, p_minutes integer, p_other_groomer_reason text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_ends     timestamp := p_starts_at + p_minutes * interval '1 minute';
    v_clash    record;
    v_regular  uuid := regular_groomer(p_dog_id);
    v_names    record;
BEGIN
    SELECT d.name AS dog, g.display_name AS groomer INTO v_names
      FROM dog d, groomer g
     WHERE d.id = p_dog_id AND d.is_active AND g.id = p_groomer_id AND g.is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'That dog or groomer is not on the books' USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF p_minutes IS NULL OR p_minutes NOT BETWEEN 5 AND 720 THEN
        RAISE EXCEPTION 'A groom needs between 5 minutes and 12 hours' USING ERRCODE = 'check_violation';
    END IF;
    IF p_starts_at < shop_now() THEN
        RAISE EXCEPTION 'That time has already passed' USING ERRCODE = 'check_violation',
              HINT = 'Pick a time later today or another day.';
    END IF;
    IF p_starts_at::time < shop_opens() OR v_ends::time > shop_closes() OR v_ends::date <> p_starts_at::date THEN
        RAISE EXCEPTION 'The shop is open % to %; this groom would run %–%',
                        to_char(shop_opens(), 'FMHH12:MI AM'), to_char(shop_closes(), 'FMHH12:MI AM'),
                        to_char(p_starts_at, 'FMHH12:MI AM'), to_char(v_ends, 'FMHH12:MI AM')
            USING ERRCODE = 'check_violation', HINT = 'Start it earlier, or shorten it.';
    END IF;

    -- GR031: the groomer, then the dog.
    SELECT a.starts_at, a.ends_at, d.name AS dog INTO v_clash
      FROM appointment a JOIN dog d ON d.id = a.dog_id
     WHERE a.groomer_id = p_groomer_id AND a.status = 'booked'
       AND a.id IS DISTINCT FROM p_appointment_id
       AND a.starts_at < v_ends AND a.ends_at > p_starts_at
     ORDER BY a.starts_at LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION '% is already booked %–% (%)', v_names.groomer,
                        to_char(v_clash.starts_at, 'FMHH12:MI AM'), to_char(v_clash.ends_at, 'FMHH12:MI AM'), v_clash.dog
            USING ERRCODE = 'GR031', HINT = 'Pick one of their free times, or another day.';
    END IF;
    SELECT a.starts_at, a.ends_at, g.display_name AS groomer INTO v_clash
      FROM appointment a JOIN groomer g ON g.id = a.groomer_id
     WHERE a.dog_id = p_dog_id AND a.status = 'booked'
       AND a.id IS DISTINCT FROM p_appointment_id
       AND a.starts_at < v_ends AND a.ends_at > p_starts_at
     LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION '% is already booked %–% with %', v_names.dog,
                        to_char(v_clash.starts_at, 'FMHH12:MI AM'), to_char(v_clash.ends_at, 'FMHH12:MI AM'), v_clash.groomer
            USING ERRCODE = 'GR031', HINT = 'Change that booking instead of adding a second one.';
    END IF;

    -- GR032
    IF v_regular IS NOT NULL AND v_regular <> p_groomer_id AND nullif_blank(p_other_groomer_reason) IS NULL THEN
        RAISE EXCEPTION '% usually goes to %', v_names.dog, (SELECT display_name FROM groomer WHERE id = v_regular)
            USING ERRCODE = 'GR032',
                  HINT = 'Book them with their usual groomer, or say why it is someone else this time.';
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- Booking, changing, cancelling
-- -----------------------------------------------------------------------------

CREATE FUNCTION book_appointment(p_dog_id uuid, p_groomer_id uuid, p_starts_at timestamp, p_minutes integer,
                                 p_service_code text, p_note text, p_other_groomer_reason text, p_booked_by uuid)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_service uuid;
    v_actor   text;
    v_id      uuid;
BEGIN
    SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_booked_by;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No such groomer: %', p_booked_by USING ERRCODE = 'foreign_key_violation';
    END IF;
    SELECT st.id INTO v_service FROM service_type st WHERE st.code = COALESCE(p_service_code, 'full_groom');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown service: %', p_service_code USING ERRCODE = 'check_violation';
    END IF;
    PERFORM check_booking(NULL, p_dog_id, p_groomer_id, p_starts_at, p_minutes, p_other_groomer_reason);

    INSERT INTO appointment (dog_id, groomer_id, service_type_id, starts_at, minutes, note,
                             other_groomer_reason, booked_by)
    VALUES (p_dog_id, p_groomer_id, v_service, p_starts_at, p_minutes, nullif_blank(p_note),
            CASE WHEN regular_groomer(p_dog_id) IS DISTINCT FROM p_groomer_id THEN nullif_blank(p_other_groomer_reason) END,
            p_booked_by)
    RETURNING id INTO v_id;

    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    VALUES (p_booked_by, v_actor, 'create', 'appointment', v_id,
            jsonb_build_object('dog_id', p_dog_id, 'groomer_id', p_groomer_id, 'starts_at', p_starts_at,
                               'minutes', p_minutes, 'service', COALESCE(p_service_code, 'full_groom'),
                               'vaccine_warnings', (SELECT count(*) FROM appointment_warnings(p_dog_id, p_starts_at::date))));
    RETURN v_id;
END $$;

COMMENT ON FUNCTION book_appointment(uuid, uuid, timestamp, integer, text, text, text, uuid) IS
  'Books a groom. Refused over another booking (GR031), or with someone other than a regular '
  'client''s usual groomer without a reason (GR032). Vaccines are warned about, not refused.';

CREATE FUNCTION change_appointment(p_id uuid, p_groomer_id uuid, p_starts_at timestamp, p_minutes integer,
                                   p_note text, p_other_groomer_reason text, p_changed_by uuid)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_old   appointment;
    v_actor text;
BEGIN
    SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_changed_by;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No such groomer: %', p_changed_by USING ERRCODE = 'foreign_key_violation';
    END IF;
    SELECT * INTO v_old FROM appointment WHERE id = p_id AND status = 'booked';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No booking with id % to change', p_id USING ERRCODE = 'foreign_key_violation';
    END IF;
    PERFORM check_booking(p_id, v_old.dog_id, p_groomer_id, p_starts_at, p_minutes, p_other_groomer_reason);

    UPDATE appointment
       SET groomer_id = p_groomer_id, starts_at = p_starts_at, minutes = p_minutes, note = nullif_blank(p_note),
           other_groomer_reason = CASE WHEN regular_groomer(v_old.dog_id) IS DISTINCT FROM p_groomer_id
                                       THEN nullif_blank(p_other_groomer_reason) END
     WHERE id = p_id;

    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    VALUES (p_changed_by, v_actor, 'update', 'appointment', p_id,
            jsonb_diff(jsonb_build_object('groomer_id', v_old.groomer_id, 'starts_at', v_old.starts_at,
                                          'minutes', v_old.minutes, 'note', v_old.note),
                       jsonb_build_object('groomer_id', p_groomer_id, 'starts_at', p_starts_at,
                                          'minutes', p_minutes, 'note', nullif_blank(p_note))));
END $$;

CREATE FUNCTION cancel_appointment(p_id uuid, p_reason text, p_cancelled_by uuid)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_actor text;
BEGIN
    SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_cancelled_by;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No such groomer: %', p_cancelled_by USING ERRCODE = 'foreign_key_violation';
    END IF;
    UPDATE appointment
       SET status = 'cancelled', cancelled_by = p_cancelled_by, cancelled_at = now(),
           cancel_reason = nullif_blank(p_reason)
     WHERE id = p_id AND status = 'booked';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No booking with id % to cancel', p_id USING ERRCODE = 'foreign_key_violation';
    END IF;
    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    VALUES (p_cancelled_by, v_actor, 'update', 'appointment', p_id,
            jsonb_build_object('status', 'cancelled', 'reason', nullif_blank(p_reason)));
END $$;

-- -----------------------------------------------------------------------------
-- Choosing a groomer and a time
--
-- free_starts(): the start times a groomer has free on a day for a groom of
-- this length, booking_step_minutes apart, within the shop's hours and not in
-- the past. p_ignore is the booking being moved, which does not get in its
-- own way.
--
-- booking_choices(): every active groomer for this dog on this day, the
-- regular groomer first, then whoever has the most room, each with whether the
-- time asked about is free and their first free start that day.
-- -----------------------------------------------------------------------------

CREATE FUNCTION free_starts(p_groomer_id uuid, p_day date, p_minutes integer, p_ignore uuid DEFAULT NULL)
RETURNS SETOF timestamp LANGUAGE sql STABLE AS $$
    SELECT s
      FROM generate_series(p_day + shop_opens(),
                           p_day + shop_closes() - p_minutes * interval '1 minute',
                           shop_policy_int('booking_step_minutes') * interval '1 minute') s
     WHERE s >= shop_now()
       AND NOT EXISTS (SELECT 1 FROM appointment a
                        WHERE a.groomer_id = p_groomer_id AND a.status = 'booked'
                          AND a.id IS DISTINCT FROM p_ignore
                          AND a.starts_at < s + p_minutes * interval '1 minute' AND a.ends_at > s)
     ORDER BY s
$$;

CREATE FUNCTION booking_choices(p_dog_id uuid, p_starts_at timestamp, p_minutes integer, p_ignore uuid DEFAULT NULL)
RETURNS TABLE (groomer_id uuid, groomer text, is_regular boolean, last_groomed_on date,
               free_then boolean, first_free timestamp, free_count integer)
LANGUAGE sql STABLE AS $$
    WITH g AS (
        SELECT g.id, g.display_name,
               g.id = regular_groomer(p_dog_id) AS is_regular,
               (SELECT max(v.visit_date) FROM visit v WHERE v.dog_id = p_dog_id AND v.performed_by = g.id) AS last_on,
               ARRAY(SELECT free_starts(g.id, p_starts_at::date, p_minutes, p_ignore)) AS starts
          FROM groomer g WHERE g.is_active)
    SELECT id, display_name, is_regular, last_on, p_starts_at = ANY (starts), starts[1], cardinality(starts)
      FROM g
     ORDER BY is_regular DESC, (p_starts_at = ANY (starts)) DESC, cardinality(starts) DESC, display_name
$$;

-- -----------------------------------------------------------------------------
-- In good standing
--
-- Every vaccine the shop tracks is current: nothing expired, expiring soon,
-- missing, waiting on paperwork or in question. Stricter than "cleared to
-- groom", which only asks about the vaccines that stop a groom; this is the
-- green check beside a dog's name on the calendar and the booking screen.
-- -----------------------------------------------------------------------------

CREATE FUNCTION vaccines_all_current(p_dog_id uuid) RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT NOT EXISTS (SELECT 1 FROM v_check_in_vaccine c
                        WHERE c.dog_id = p_dog_id AND c.state NOT IN ('current', 'not_yet_due'))
$$;

-- -----------------------------------------------------------------------------
-- Reading bookings
-- -----------------------------------------------------------------------------

CREATE VIEW v_appointment AS
SELECT a.id, a.dog_id, d.name AS dog, breed_label(d.breed_id, d.is_mixed, d.second_breed_id) AS breed,
       o.first_name || ' ' || o.last_name AS owner,
       a.groomer_id, g.display_name AS groomer, st.code AS service_code, st.name AS service,
       a.starts_at, a.ends_at, a.minutes, a.note, a.other_groomer_reason,
       a.other_groomer_reason IS NOT NULL AS not_usual_groomer,
       a.status::text AS status, b.display_name AS booked_by, a.booked_at
  FROM appointment a
  JOIN dog d          ON d.id = a.dog_id
  JOIN owner o        ON o.id = d.owner_id
  JOIN groomer g      ON g.id = a.groomer_id
  JOIN groomer b      ON b.id = a.booked_by
  JOIN service_type st ON st.id = a.service_type_id
 WHERE d.is_active;

-- The calendar (section 29) shows bookings too: on their day, with the time,
-- length and groomer; and every dog's breed, so a name the groomer hasn't seen
-- in months still means something. New columns go on the end.
CREATE OR REPLACE VIEW v_calendar_event AS
SELECT v.visit_date                                   AS on_date,
       'groom'::text                                  AS kind,
       d.id                                           AS dog_id,
       d.name                                         AS dog,
       o.first_name || ' ' || o.last_name             AS owner,
       NULL::text                                     AS vaccine,
       g.display_name                                 AS groomer,
       v.overall_note                                 AS note,
       false                                          AS stops_grooms,
       v.check_out IS NULL AND v.visit_date = CURRENT_DATE AS in_progress,
       NULL::uuid                                     AS appointment_id,
       v.check_in                                     AS starts_at,
       NULL::integer                                  AS minutes,
       NULL::text                                     AS service,
       breed_label(d.breed_id, d.is_mixed, d.second_breed_id) AS breed
  FROM visit v
  JOIN dog d     ON d.id = v.dog_id
  JOIN owner o   ON o.id = d.owner_id
  JOIN groomer g ON g.id = v.performed_by
 WHERE d.is_active
UNION ALL
SELECT c.expires_on, 'expiry', d.id, d.name, o.first_name || ' ' || o.last_name,
       vt.name, NULL, NULL, vt.blocks_service_if_expired, false,
       NULL, NULL, NULL, NULL, breed_label(d.breed_id, d.is_mixed, d.second_breed_id)
  FROM dog_vaccine_compliance c
  JOIN vaccine_type vt ON vt.id = c.vaccine_type_id
  JOIN dog d           ON d.id = c.dog_id
  JOIN owner o         ON o.id = d.owner_id
 WHERE c.expires_on IS NOT NULL AND d.is_active
UNION ALL
SELECT a.starts_at::date, 'booking', a.dog_id, a.dog, a.owner, NULL, a.groomer, a.note, false, false,
       a.id, a.starts_at::time, a.minutes, a.service, breed_label(d.breed_id, d.is_mixed, d.second_breed_id)
  FROM v_appointment a
  JOIN dog d ON d.id = a.dog_id
 WHERE a.status = 'booked';
