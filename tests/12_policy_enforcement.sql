-- Policy is data, and the data is governed.
--
-- Four things are proven here:
--   1. shop_policy fails LOUDLY: a missing or mistyped key raises (GR013)
--      instead of returning NULL and quietly disabling a view branch, and the
--      rows cannot be deleted at all (GR014).
--   2. The dashboard label tracks the live warning window — "Expiring within
--      N days" is templated at read time, so a policy change cannot make the
--      label lie.
--   3. policy_enforcement converts block-versus-flag per invariant into an
--      UPDATE: 'warn' records the violation in audit_log and lets the row
--      land, 'off' lets it land silently, and pinned codes refuse to be
--      relaxed at all.
--   4. A regulatory vaccine rule (GR012) does not change without a stated
--      reason, and the reason lands in audit_log with the old and new values.

BEGIN;
SET search_path = groom, public;
SELECT plan(16);

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
-- tracked vaccines have records too, so expiring_soon is the worst state.
INSERT INTO dog (id, owner_id, name, coat_type_id) VALUES
  ('00000000-0000-0000-0000-00000000d301', '00000000-0000-0000-0000-00000000a001',
   'Expiring Soon Dog', (SELECT id FROM coat_type WHERE code = 'curly'));

INSERT INTO vaccination_record
  (dog_id, vaccine_type_id, administered_on, expires_on, entry_method)
VALUES
  ('00000000-0000-0000-0000-00000000d301',
   (SELECT id FROM vaccine_type WHERE code = 'rabies'),
   CURRENT_DATE - 345, CURRENT_DATE + 20, 'manual'),
  ('00000000-0000-0000-0000-00000000d301',
   (SELECT id FROM vaccine_type WHERE code = 'dhpp'),
   CURRENT_DATE - 65, CURRENT_DATE + 300, 'manual'),
  ('00000000-0000-0000-0000-00000000d301',
   (SELECT id FROM vaccine_type WHERE code = 'bordetella'),
   CURRENT_DATE - 62, CURRENT_DATE + 120, 'manual');

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

-- A pinned code stays a block. Relaxing GR009 would let a tiered template
-- expand against nothing: a structurally empty haircut, not a policy choice.
SELECT throws_ok(
  $$ UPDATE policy_enforcement SET level = 'warn' WHERE error_code = 'GR009' $$,
  '23514',
  NULL,
  'A pinned code refuses to be relaxed'
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

SELECT lives_ok(
  $$ UPDATE vaccine_type SET plausible_validity_max_months = 13
      WHERE code = 'leptospirosis' $$,
  'A facility-policy vaccine needs no ceremony'
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

SELECT * FROM finish();
ROLLBACK;
