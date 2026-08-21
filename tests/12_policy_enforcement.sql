-- Policy is data, and the data is governed.
--
-- Five things are proven here:
--   1. shop_policy fails LOUDLY: a missing or mistyped key raises (GR013)
--      instead of returning NULL and quietly disabling a view branch, and the
--      rows cannot be deleted at all (GR014).
--   2. The dashboard label tracks the live warning window — "Expiring within
--      N days" is templated at read time, so a policy change cannot make the
--      label lie.
--   3. policy_enforcement converts block-versus-flag per invariant into an
--      UPDATE: 'warn' records the violation in audit_log and lets the row
--      land, 'off' lets it land silently, an unregistered code fails closed
--      to 'block', and pinned codes refuse to be relaxed at all.
--   4. A 'warn' on GR003 still yields a complete, truthful record — the zones
--      land, and exactly ONE warning is written, not one per zone row.
--   5. A regulatory vaccine rule (GR012) does not appear, change, or
--      disappear without a stated reason, the ceremony is scoped to the
--      legally-dictated columns, and the reason lands in audit_log with the
--      values involved.
--
-- SET CONSTRAINTS ALL IMMEDIATE for the same reason as test 10: the uniform-
-- length and groom-service guards are deferred to COMMIT, and this file rolls
-- back, so they must be forced immediate to fire at all.

BEGIN;
SET search_path = groom, public;
SET CONSTRAINTS ALL IMMEDIATE;
SELECT plan(27);

-- --- Every key the read functions reference exists ---------------------------
-- The cheapest defense against the silent-NULL failure: if a rename or a
-- botched seed ever removes a key, this is the test that goes red.
SELECT is(expiry_warning_days(), 30, 'expiry_warning_days reads its row');
SELECT is(min_groom_age_weeks(), 16, 'min_groom_age_weeks reads its row');

-- --- A missing key raises; it does not return NULL ---------------------------
SELECT throws_ok(
  $$ SELECT shop_policy_int('no_such_key') $$,
  'GR013',
  NULL,
  'A missing policy key fails loudly instead of guessing'
);

-- --- Policy rows are updated, never deleted ----------------------------------
SELECT throws_ok(
  $$ DELETE FROM shop_policy WHERE key = 'expiry_warning_days' $$,
  'GR014',
  NULL,
  'A policy row cannot be deleted out from under the functions that read it'
);

-- --- The dashboard label tracks the live warning window ----------------------
-- A dog whose only problem is a rabies shot expiring in 20 days. The other two
-- tracked vaccines have VERIFIED records resolving to 'current', so
-- expiring_soon is the worst state on its own merits, not by sort-order luck.
INSERT INTO dog (id, owner_id, name, coat_type_id) VALUES
  ('00000000-0000-0000-0000-00000000d301', '00000000-0000-0000-0000-00000000a001',
   'Expiring Soon Dog', (SELECT id FROM coat_type WHERE code = 'curly'));

INSERT INTO vaccination_record
  (dog_id, vaccine_type_id, administered_on, expires_on, entry_method,
   verification_status, verified_by, verified_at)
VALUES
  ('00000000-0000-0000-0000-00000000d301',
   (SELECT id FROM vaccine_type WHERE code = 'rabies'),
   CURRENT_DATE - 345, CURRENT_DATE + 20, 'manual', 'unverified', NULL, NULL),
  ('00000000-0000-0000-0000-00000000d301',
   (SELECT id FROM vaccine_type WHERE code = 'dhpp'),
   CURRENT_DATE - 65, CURRENT_DATE + 300, 'manual', 'verified',
   '00000000-0000-0000-0000-00000000b001', now()),
  ('00000000-0000-0000-0000-00000000d301',
   (SELECT id FROM vaccine_type WHERE code = 'bordetella'),
   CURRENT_DATE - 62, CURRENT_DATE + 120, 'manual', 'verified',
   '00000000-0000-0000-0000-00000000b001', now());

SELECT is(
  (SELECT plain_language_label FROM v_compliance_dashboard
    WHERE dog_id = '00000000-0000-0000-0000-00000000d301'),
  'Expiring within 30 days',
  'The dashboard label carries the default window'
);

UPDATE shop_policy SET int_value = 45 WHERE key = 'expiry_warning_days';

SELECT is(
  (SELECT plain_language_label FROM v_compliance_dashboard
    WHERE dog_id = '00000000-0000-0000-0000-00000000d301'),
  'Expiring within 45 days',
  'Widening the window updates the label with it — the label cannot lie'
);

SELECT ok(
  EXISTS (SELECT 1 FROM audit_log
           WHERE entity_type = 'shop_policy' AND action = 'update'
             AND changed_fields->>'key' = 'expiry_warning_days'
             AND changed_fields->'changed' ? 'int_value'),
  'The policy change landed in audit_log with old and new values'
);

-- --- Block versus flag is an UPDATE, not a migration -------------------------
-- The same under-age haircut test 11 proves is refused at 'block'. One owner
-- wants a hard stop; another wants a note. That is a level, not a trigger body.
INSERT INTO dog (id, owner_id, name, coat_type_id, date_of_birth) VALUES
  ('00000000-0000-0000-0000-00000000d302', '00000000-0000-0000-0000-00000000a001',
   'Warned Puppy', (SELECT id FROM coat_type WHERE code = 'curly'),
   CURRENT_DATE - 70);

INSERT INTO visit (id, dog_id, performed_by, visit_date) VALUES
  ('00000000-0000-0000-0000-0000000e0311', '00000000-0000-0000-0000-00000000d302',
   '00000000-0000-0000-0000-00000000b001', CURRENT_DATE),
  ('00000000-0000-0000-0000-0000000e0312', '00000000-0000-0000-0000-00000000d302',
   '00000000-0000-0000-0000-00000000b001', CURRENT_DATE);

INSERT INTO visit_service (visit_id, service_type_id)
SELECT v.id, (SELECT id FROM service_type WHERE code = 'full_groom')
FROM (VALUES ('00000000-0000-0000-0000-0000000e0311'::uuid),
             ('00000000-0000-0000-0000-0000000e0312'::uuid)) AS v(id);

UPDATE policy_enforcement SET level = 'warn' WHERE error_code = 'GR011';

SELECT lives_ok(
  $$ INSERT INTO cut_specification (visit_id, style_template_id, length_tier_id)
     VALUES ('00000000-0000-0000-0000-0000000e0311',
             (SELECT id FROM style_template WHERE code = 'teddy_bear'),
             (SELECT id FROM length_tier    WHERE code = 'medium')) $$,
  'At warn, the under-age haircut lands instead of raising'
);

SELECT ok(
  EXISTS (SELECT 1 FROM audit_log
           WHERE action = 'policy_warning'
             AND changed_fields->>'error_code' = 'GR011'),
  'and the violation is on the record as a policy_warning'
);

UPDATE policy_enforcement SET level = 'off' WHERE error_code = 'GR011';

SELECT lives_ok(
  $$ INSERT INTO cut_specification (visit_id, style_template_id, length_tier_id)
     VALUES ('00000000-0000-0000-0000-0000000e0312',
             (SELECT id FROM style_template WHERE code = 'teddy_bear'),
             (SELECT id FROM length_tier    WHERE code = 'medium')) $$,
  'At off, the same haircut lands silently'
);

SELECT is(
  (SELECT count(*)::int FROM audit_log
    WHERE action = 'policy_warning'
      AND changed_fields->>'error_code' = 'GR011'),
  1,
  'off writes no warning — still exactly one from the warn case'
);

-- --- Fail closed: the registry cannot switch a rule off by omission ----------
SELECT is(
  enforcement_level('GR999'),
  'block',
  'An unregistered code blocks, exactly as if the table did not exist'
);

-- --- A warn on GR003 yields a truthful record, and exactly one warning -------
-- The dangerous case: 'warn' feeds code that consumes the row afterward. The
-- zones must land in full, and the per-row constraint trigger must not write
-- one warning per zone.
--
-- Its own adult-equivalent dog (no birth date, like the rescue-dog fixture),
-- so this section does not depend on GR011's level being left 'off' above —
-- reorder the sections and it still passes.
INSERT INTO dog (id, owner_id, name, coat_type_id) VALUES
  ('00000000-0000-0000-0000-00000000d303', '00000000-0000-0000-0000-00000000a001',
   'Uniform Dog', (SELECT id FROM coat_type WHERE code = 'curly'));

INSERT INTO visit (id, dog_id, performed_by, visit_date) VALUES
  ('00000000-0000-0000-0000-0000000e0313', '00000000-0000-0000-0000-00000000d303',
   '00000000-0000-0000-0000-00000000b001', CURRENT_DATE);

INSERT INTO visit_service (visit_id, service_type_id) VALUES
  ('00000000-0000-0000-0000-0000000e0313',
   (SELECT id FROM service_type WHERE code = 'full_groom'));

INSERT INTO style_template_zone_spec
    (style_template_id, length_tier_id, body_zone_id, tool, blade_id)
VALUES
    ((SELECT id FROM style_template WHERE code = 'kennel_puppy'),
     (SELECT id FROM length_tier    WHERE code = 'short'),
     (SELECT id FROM body_zone      WHERE code = 'body'),
     'clipper', (SELECT id FROM blade WHERE number = 7 AND is_finish)),
    ((SELECT id FROM style_template WHERE code = 'kennel_puppy'),
     (SELECT id FROM length_tier    WHERE code = 'short'),
     (SELECT id FROM body_zone      WHERE code = 'neck'),
     'clipper', (SELECT id FROM blade WHERE number = 4 AND is_finish));

INSERT INTO cut_specification (id, visit_id, style_template_id, length_tier_id)
VALUES
    ('00000000-0000-0000-0000-0000000c0301',
     '00000000-0000-0000-0000-0000000e0313',
     (SELECT id FROM style_template WHERE code = 'kennel_puppy'),
     (SELECT id FROM length_tier    WHERE code = 'short'));

UPDATE policy_enforcement SET level = 'warn' WHERE error_code = 'GR003';

SELECT lives_ok(
  $$ SELECT resolve_cut_spec_zones('00000000-0000-0000-0000-0000000c0301') $$,
  'At warn, the two-length Kennel trim expands instead of raising'
);

SELECT is(
  (SELECT count(*)::int FROM cut_spec_zone
    WHERE cut_specification_id = '00000000-0000-0000-0000-0000000c0301'
      AND resolved_from = 'template'),
  2,
  'and the record is complete — both template zones landed'
);

SELECT is(
  (SELECT count(*)::int FROM audit_log
    WHERE action = 'policy_warning'
      AND changed_fields->>'error_code' = 'GR003'),
  1,
  'with exactly one warning, not one per zone row'
);

-- --- Pinned codes refuse to be relaxed ---------------------------------------
-- GR001: the expansion keys remedial templates on the coat level GR001
-- validates, so a warn would land a "Shaved" spec that resolves to hygiene
-- zones only — a falsified record. The laxer lever is the template's own
-- min_coat_ordinal_required, which is already data.
SELECT throws_ok(
  $$ UPDATE policy_enforcement SET level = 'warn' WHERE error_code = 'GR001' $$,
  '23514',
  NULL,
  'GR001 is pinned: relaxing it would falsify the shave-down record'
);

-- GR009: a tiered template with no tier expands against nothing — a
-- structurally empty haircut, not a policy choice.
SELECT throws_ok(
  $$ UPDATE policy_enforcement SET level = 'warn' WHERE error_code = 'GR009' $$,
  '23514',
  NULL,
  'GR009 is pinned: a structurally empty haircut is not a policy choice'
);

-- --- The LEGAL tier is load-bearing ------------------------------------------
-- Rabies at 16 weeks is COMAR 10.06.02, and it sits in a freely editable
-- reference table. GR012 is what separates it from a shop preference.
SELECT throws_ok(
  $$ UPDATE vaccine_type SET min_age_weeks = 12 WHERE code = 'rabies' $$,
  'GR012',
  NULL,
  'A regulatory vaccine rule does not change without a stated reason'
);

SELECT throws_ok(
  $$ DELETE FROM vaccine_type WHERE code = 'rabies' $$,
  'GR012',
  NULL,
  'and it does not disappear without one either'
);

-- The add door is locked too: a new regulatory vaccine starts driving every
-- dog's compliance the moment it exists, so creating one is a GR012 event.
SELECT throws_ok(
  $$ INSERT INTO vaccine_type
       (code, name, regulatory_required, min_age_weeks, authority,
        plausible_validity_min_months, plausible_validity_max_months)
     VALUES ('zz_uncited', 'Uncited Regulatory Vaccine', true, 16, 'none given',
             12, 36) $$,
  'GR012',
  NULL,
  'and a new one is not born without a citation'
);

SELECT lives_ok(
  $$ UPDATE vaccine_type SET plausible_validity_max_months = 13
      WHERE code = 'leptospirosis' $$,
  'A facility-policy vaccine needs no ceremony'
);

-- The ceremony is scoped to the legally-dictated columns, not the whole row.
SELECT lives_ok(
  $$ UPDATE vaccine_type SET name = 'Rabies (1yr/3yr)' WHERE code = 'rabies' $$,
  'Renaming a regulatory vaccine is shop data — no citation demanded'
);

SET LOCAL groom.change_reason = 'COMAR 10.06.02 amendment effective 2026-10-01';

SELECT lives_ok(
  $$ UPDATE vaccine_type SET min_age_weeks = 12 WHERE code = 'rabies' $$,
  'With a stated reason the change goes through'
);

SELECT ok(
  EXISTS (SELECT 1 FROM audit_log
           WHERE entity_type = 'vaccine_type' AND action = 'update'
             AND changed_fields->>'reason' LIKE 'COMAR%'
             AND changed_fields->'changed' ? 'min_age_weeks'),
  'and the reason, authority and old/new values are the dated record'
);

-- The DELETE branch writes its own audit entry. A throwaway regulatory row,
-- because the real ones are referenced and RESTRICTed.
INSERT INTO vaccine_type
  (code, name, regulatory_required, required_by_policy, min_age_weeks, authority,
   plausible_validity_min_months, plausible_validity_max_months)
VALUES
  ('zz_test_reg', 'Test Regulatory Vaccine', true, false, 16, 'TEST CITATION', 12, 36);

SELECT ok(
  EXISTS (SELECT 1 FROM audit_log
           WHERE entity_type = 'vaccine_type' AND action = 'create'
             AND changed_fields->'created'->>'code' = 'zz_test_reg'),
  'Creating a regulatory vaccine with the reason set is a dated record'
);

SELECT lives_ok(
  $$ DELETE FROM vaccine_type WHERE code = 'zz_test_reg' $$,
  'With the reason still set, deleting a regulatory row goes through'
);

SELECT ok(
  EXISTS (SELECT 1 FROM audit_log
           WHERE entity_type = 'vaccine_type' AND action = 'delete'
             AND changed_fields->>'reason' LIKE 'COMAR%'
             AND changed_fields->'deleted'->>'code' = 'zz_test_reg'),
  'and the deletion is a dated record with the full row preserved'
);

SELECT * FROM finish();
ROLLBACK;
