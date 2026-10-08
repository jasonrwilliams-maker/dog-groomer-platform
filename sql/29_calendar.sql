-- =============================================================================
-- 29. The calendar: grooms and vaccine expiries, by date
--
-- One list of dated things the shop wants to see on a month view:
--
--   groom    a visit, on the day it happened, with who groomed
--   expiry   the day a dog's vaccine runs out: the one the dog's compliance
--            rests on (dog_vaccine_compliance), so an older certificate that a
--            newer one replaced does not crowd the calendar
--
-- The shop does not book grooms ahead in this system, so there are no future
-- appointments to show; what lies ahead is when paperwork runs out. An expiry
-- says whether that vaccine stops a groom when it lapses
-- (vaccine_type.blocks_service_if_expired: rabies, as the shop is set up), so
-- the calendar can mark the ones that matter most.
--
-- Read only. The screen asks for a span of dates, or for one dog's whole
-- history.
-- =============================================================================

SET search_path = groom, public;

CREATE VIEW v_calendar_event AS
SELECT v.visit_date                                   AS on_date,
       'groom'::text                                  AS kind,
       d.id                                           AS dog_id,
       d.name                                         AS dog,
       o.first_name || ' ' || o.last_name             AS owner,
       NULL::text                                     AS vaccine,
       g.display_name                                 AS groomer,
       v.overall_note                                 AS note,
       false                                          AS stops_grooms,
       v.check_out IS NULL AND v.visit_date = CURRENT_DATE AS in_progress
  FROM visit v
  JOIN dog d     ON d.id = v.dog_id
  JOIN owner o   ON o.id = d.owner_id
  JOIN groomer g ON g.id = v.performed_by
 WHERE d.is_active
UNION ALL
SELECT c.expires_on, 'expiry', d.id, d.name, o.first_name || ' ' || o.last_name,
       vt.name, NULL, NULL, vt.blocks_service_if_expired, false
  FROM dog_vaccine_compliance c
  JOIN vaccine_type vt ON vt.id = c.vaccine_type_id
  JOIN dog d           ON d.id = c.dog_id
  JOIN owner o         ON o.id = d.owner_id
 WHERE c.expires_on IS NOT NULL AND d.is_active;

COMMENT ON VIEW v_calendar_event IS
  'Grooms and vaccine expiries by date, for the calendar. An expiry is the record '
  'the dog''s compliance rests on; stops_grooms marks a vaccine whose lapse blocks a groom.';
