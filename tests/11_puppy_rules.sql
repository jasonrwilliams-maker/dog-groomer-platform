-- Puppy rules. Two separate rules that both hang off a birth date.
--
-- Rule A (service): a dog under min_groom_age_weeks() does not get a haircut
--   without a stated, approved reason. GR011. A soft block — the visit is still
--   recorded, because a past-visit log that refuses history is useless.
--
-- Rule B (compliance): a dog too young for a vaccine reads not_yet_due, not
--   no_record. Maryland requires rabies by 16 weeks; chasing the owner of a
--   10-week-old puppy is a false alarm, not diligence.
--
-- An unknown birth date gets no grace period under either rule.

BEGIN;
SET search_path = groom, public;
SELECT plan(7);

INSERT INTO dog (id, owner_id, name, coat_type_id, date_of_birth) VALUES
  -- Ten weeks old: too young for rabies (16w), old enough for DHPP (8w)
  ('00000000-0000-0000-0000-00000000d201', '00000000-0000-0000-0000-00000000a001',
   'Ten Week Puppy', (SELECT id FROM coat_type WHERE code = 'curly'),
   CURRENT_DATE - 70),
  -- Thirty weeks old: everything is due
  ('00000000-0000-0000-0000-00000000d202', '00000000-0000-0000-0000-00000000a001',
   'Thirty Week Dog', (SELECT id FROM coat_type WHERE code = 'curly'),
   CURRENT_DATE - 210);
  -- (fixture dog d003 has a NULL birth date and serves as the rescue case)

-- --- Rule B: the compliance side -------------------------------------------
SELECT is(
  (SELECT state::text FROM v_dog_vaccine_compliance
    WHERE dog_id = '00000000-0000-0000-0000-00000000d201'
      AND vaccine_code = 'rabies'),
  'not_yet_due',
  'A ten-week-old puppy is not yet due for rabies'
);

SELECT is(
  (SELECT state::text FROM v_dog_vaccine_compliance
    WHERE dog_id = '00000000-0000-0000-0000-00000000d201'
      AND vaccine_code = 'dhpp'),
  'no_record',
  'but it is old enough for DHPP, so that one is a real finding'
);

SELECT is(
  (SELECT state::text FROM v_dog_vaccine_compliance
    WHERE dog_id = '00000000-0000-0000-0000-00000000d202'
      AND vaccine_code = 'rabies'),
  'no_record',
  'A thirty-week-old dog with no rabies record is non-compliant'
);

SELECT is(
  (SELECT state::text FROM v_dog_vaccine_compliance
    WHERE dog_id = '00000000-0000-0000-0000-00000000d003'
      AND vaccine_code = 'rabies'),
  'no_record',
  'An unknown birth date gets no grace period'
);

-- --- Rule A: the service side ----------------------------------------------
INSERT INTO visit (id, dog_id, performed_by, visit_date) VALUES
    ('00000000-0000-0000-0000-0000000e0201',
     '00000000-0000-0000-0000-00000000d201',
     '00000000-0000-0000-0000-00000000b001', CURRENT_DATE);

INSERT INTO visit_service (visit_id, service_type_id) VALUES
    ('00000000-0000-0000-0000-0000000e0201',
     (SELECT id FROM service_type WHERE code = 'full_groom'));

SELECT throws_ok(
  $$ INSERT INTO cut_specification (visit_id, style_template_id, length_tier_id)
     VALUES ('00000000-0000-0000-0000-0000000e0201',
             (SELECT id FROM style_template WHERE code = 'teddy_bear'),
             (SELECT id FROM length_tier    WHERE code = 'medium')) $$,
  'GR011',
  NULL,
  'A haircut on a ten-week-old puppy is refused'
);

SELECT lives_ok(
  $$ INSERT INTO cut_specification
       (visit_id, style_template_id, length_tier_id,
        under_age_override_reason, approved_by, approved_at)
     VALUES ('00000000-0000-0000-0000-0000000e0201',
             (SELECT id FROM style_template WHERE code = 'teddy_bear'),
             (SELECT id FROM length_tier    WHERE code = 'medium'),
             'Severe matting around the sanitary area; owner counselled',
             '00000000-0000-0000-0000-00000000b001', now()) $$,
  'but goes ahead with a stated reason and a manager approval'
);

-- A bath on the same puppy was never in question. Only cut specifications
-- carry the age rule, because only haircuts are the thing being restricted.
INSERT INTO visit (id, dog_id, performed_by, visit_date) VALUES
    ('00000000-0000-0000-0000-0000000e0202',
     '00000000-0000-0000-0000-00000000d201',
     '00000000-0000-0000-0000-00000000b001', CURRENT_DATE);

SELECT lives_ok(
  $$ INSERT INTO visit_service (visit_id, service_type_id)
     VALUES ('00000000-0000-0000-0000-0000000e0202',
             (SELECT id FROM service_type WHERE code = 'bath')) $$,
  'A bath for a ten-week-old puppy is unaffected'
);

SELECT * FROM finish();
ROLLBACK;