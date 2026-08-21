-- Remaining invariants: GR002, GR003, GR004, the audit log, the one-open-request
-- index, the flag-not-block plausibility rule, and a check that all 25 triggers
-- are actually attached.
--
-- SET CONSTRAINTS ALL IMMEDIATE is the key line. Two of these invariants are
-- deferred constraint triggers that normally fire at COMMIT — and this file
-- rolls back, so they would never fire at all. Forcing them immediate makes
-- them raise on the statement instead, where throws_ok can catch them.

BEGIN;
SET search_path = groom, public;
SET CONSTRAINTS ALL IMMEDIATE;
SELECT plan(9);

-- --- GR004: a haircut record needs a service that carries one ---------------
INSERT INTO visit (id, dog_id, performed_by, visit_date) VALUES
    ('00000000-0000-0000-0000-0000000e0010',
     '00000000-0000-0000-0000-00000000d002',
     '00000000-0000-0000-0000-00000000b001', CURRENT_DATE);

INSERT INTO visit_service (visit_id, service_type_id) VALUES
    ('00000000-0000-0000-0000-0000000e0010',
     (SELECT id FROM service_type WHERE code = 'bath'));

SELECT throws_ok(
  $$ INSERT INTO cut_specification (visit_id, style_template_id, length_tier_id)
     VALUES ('00000000-0000-0000-0000-0000000e0010',
             (SELECT id FROM style_template WHERE code = 'teddy_bear'),
             (SELECT id FROM length_tier    WHERE code = 'medium')) $$,
  'GR004',
  NULL,
  'A bath-only visit does not get a haircut record'
);

-- --- GR002: an approved override must still state the coat level ------------
INSERT INTO visit (id, dog_id, performed_by, visit_date) VALUES
    ('00000000-0000-0000-0000-0000000e0011',
     '00000000-0000-0000-0000-00000000d002',
     '00000000-0000-0000-0000-00000000b001', CURRENT_DATE);

INSERT INTO visit_service (visit_id, service_type_id) VALUES
    ('00000000-0000-0000-0000-0000000e0011',
     (SELECT id FROM service_type WHERE code = 'full_groom'));

SELECT throws_ok(
  $$ INSERT INTO cut_specification
       (visit_id, style_template_id, remedial_override_reason, approved_by, approved_at)
     VALUES ('00000000-0000-0000-0000-0000000e0011',
             (SELECT id FROM style_template WHERE code = 'shaved'),
             'Owner insisted despite a level 3 coat',
             '00000000-0000-0000-0000-00000000b001', now()) $$,
  'GR002',
  NULL,
  'A manager-approved shave-down still has to say what the coat looked like'
);

-- --- GR003: a uniform-length template must resolve uniformly ----------------
-- Kennel/Puppy is one length everywhere; that absence of a differential is the
-- style. Configure it with two lengths and the expansion refuses.
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

INSERT INTO visit (id, dog_id, performed_by, visit_date) VALUES
    ('00000000-0000-0000-0000-0000000e0012',
     '00000000-0000-0000-0000-00000000d002',
     '00000000-0000-0000-0000-00000000b001', CURRENT_DATE);

INSERT INTO visit_service (visit_id, service_type_id) VALUES
    ('00000000-0000-0000-0000-0000000e0012',
     (SELECT id FROM service_type WHERE code = 'full_groom'));

INSERT INTO cut_specification (id, visit_id, style_template_id, length_tier_id)
VALUES
    ('00000000-0000-0000-0000-0000000c0012',
     '00000000-0000-0000-0000-0000000e0012',
     (SELECT id FROM style_template WHERE code = 'kennel_puppy'),
     (SELECT id FROM length_tier    WHERE code = 'short'));

SELECT throws_ok(
  $$ SELECT resolve_cut_spec_zones('00000000-0000-0000-0000-0000000c0012') $$,
  'GR003',
  NULL,
  'A Kennel trim resolving to two lengths is not a Kennel trim'
);

-- --- The audit log is append-only -------------------------------------------
INSERT INTO audit_log (id, actor_id, actor_label, action, entity_type, entity_id)
VALUES ('00000000-0000-0000-0000-00000000aa01',
        '00000000-0000-0000-0000-00000000b001', 'Nadia', 'update',
        'vaccination_record', '00000000-0000-0000-0000-00000000f101');

SELECT throws_ok(
  $$ UPDATE audit_log SET actor_label = 'Someone else'
      WHERE id = '00000000-0000-0000-0000-00000000aa01' $$,
  'P0001',
  'audit_log is append-only',
  'An audit entry cannot be edited'
);

SELECT throws_ok(
  $$ DELETE FROM audit_log WHERE id = '00000000-0000-0000-0000-00000000aa01' $$,
  'P0001',
  'audit_log is append-only',
  'An audit entry cannot be deleted'
);

-- --- One open request per dog per vaccine -----------------------------------
-- Without this, dog_vaccine_compliance.open_request_id would be ambiguous.
INSERT INTO record_request (dog_id, owner_id, vaccine_type_id, channel, status)
VALUES ('00000000-0000-0000-0000-00000000d001', '00000000-0000-0000-0000-00000000a001',
        (SELECT id FROM vaccine_type WHERE code = 'rabies'), 'verbal_at_counter', 'queued');

SELECT throws_ok(
  $$ INSERT INTO record_request (dog_id, owner_id, vaccine_type_id, channel, status)
     VALUES ('00000000-0000-0000-0000-00000000d001', '00000000-0000-0000-0000-00000000a001',
             (SELECT id FROM vaccine_type WHERE code = 'rabies'),
             'verbal_at_counter', 'sent') $$,
  '23505',
  NULL,
  'A second open request for the same dog and vaccine is refused'
);

-- --- Plausibility flags, it does not block ----------------------------------
-- Both 1-year and 3-year rabies are legal and the clinic decides. A 5-year
-- validity is odd, but the certificate is what the health department will see,
-- so the system records it and flags it for a human.
SELECT lives_ok(
  $$ INSERT INTO vaccination_record
       (id, dog_id, vaccine_type_id, administered_on, expires_on, entry_method)
     VALUES ('00000000-0000-0000-0000-00000000f110',
             '00000000-0000-0000-0000-00000000d003',
             (SELECT id FROM vaccine_type WHERE code = 'rabies'),
             DATE '2021-08-01', DATE '2026-08-01', 'manual') $$,
  'An implausible validity period is accepted, not blocked'
);

SELECT is(
  (SELECT validity_implausible FROM vaccination_record
    WHERE id = '00000000-0000-0000-0000-00000000f110'),
  true,
  'but it is flagged for a human to look at'
);

-- --- Every trigger is still attached ----------------------------------------
-- Catches the silent failure mode a future migration creates: recreating a
-- table drops its triggers, and nothing looks wrong until a bad row appears.
SELECT is_empty(
  $$ SELECT expected.name
       FROM (VALUES
         ('owner_touch'), ('dog_touch'), ('profile_touch'), ('vacc_touch'),
         ('request_touch'), ('cut_spec_zone_snapshot'), ('cut_spec_remedial_guard'),
         ('cut_spec_zone_uniform_guard'), ('cut_spec_service_guard'),
         ('vaccination_plausibility'), ('record_request_opt_out_guard'),
         ('template_zone_spec_clamp_guard'), ('cut_spec_tier_shape_guard'),
         ('profile_tier_shape_guard'), ('audit_log_immutable'),
         ('cut_spec_min_age_guard'),
         ('vaccination_record_compliance'), ('record_request_compliance'),
         ('dog_seed_compliance'),
         ('shop_policy_touch'), ('policy_enforcement_touch'),
         ('shop_policy_audit'), ('policy_enforcement_audit'),
         ('shop_policy_no_delete'), ('vaccine_type_regulatory_guard')
       ) AS expected(name)
     EXCEPT
     SELECT tgname FROM pg_trigger WHERE NOT tgisinternal $$,
  'All 25 triggers are attached'
);

SELECT * FROM finish();
ROLLBACK;