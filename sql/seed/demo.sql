-- =============================================================================
-- Demo data for the groomer interface — its own database, grooming_demo.
--
-- Not the test fixture. The fixture is small and fixed so the pgTAP suite
-- asserts exact numbers; this is a shop's worth of dogs so the check-in
-- screen has something true to show. Load it on the schema alone, never on
-- top of the fixture.
--
-- One dog per situation a groomer meets at the counter. Every date is
-- relative to today, so a dog that is "expiring soon" stays expiring soon
-- whenever the demo is run.
--
-- Jaddi and his owner are real (see the README's Disclosure), and his record
-- is what his real paperwork supports: a rabies certificate that has expired,
-- and a newer invoice that names the shot but prints no expiry. Nothing about
-- him is invented beyond that. Every other owner and dog is made up.
-- =============================================================================

SET search_path = groom, public;

-- --- People ------------------------------------------------------------------
INSERT INTO groomer (id, display_name, email, role) VALUES
  ('00000000-0000-0000-0000-0000000d0b01', 'Nadia', 'nadia@pawsandpolish.example', 'manager'),
  ('00000000-0000-0000-0000-0000000d0b02', 'Tanya', 'tanya@pawsandpolish.example', 'groomer');

INSERT INTO owner (id, first_name, last_name, email, phone) VALUES
  ('00000000-0000-0000-0000-0000000d0a01', 'Jason',  'Williams', 'jason@example.test',  '410-555-0100'),
  ('00000000-0000-0000-0000-0000000d0a02', 'Priya',  'Shah',     'priya@example.test',  '410-555-0142'),
  ('00000000-0000-0000-0000-0000000d0a03', 'Marcus', 'Reyes',    'marcus@example.test', '410-555-0177'),
  ('00000000-0000-0000-0000-0000000d0a04', 'Elena',  'Novak',    'elena@example.test',  '410-555-0119'),
  ('00000000-0000-0000-0000-0000000d0a05', 'Tom',    'Becker',   'tom@example.test',    '410-555-0163'),
  ('00000000-0000-0000-0000-0000000d0a06', 'Aisha',  'Karim',    'aisha@example.test',  '410-555-0128'),
  ('00000000-0000-0000-0000-0000000d0a07', 'Hannah', 'Lee',      'hannah@example.test', '410-555-0186'),
  ('00000000-0000-0000-0000-0000000d0a08', 'Sam',    'Ortiz',    'sam@example.test',    '410-555-0151'),
  ('00000000-0000-0000-0000-0000000d0a09', 'Grace',  'Kim',      NULL,                  '410-555-0134'),
  ('00000000-0000-0000-0000-0000000d0a10', 'Diego',  'Alvarez',  'diego@example.test',  '410-555-0195');

-- Breeds and allergens come from their lists (sql/23_breed_seed.sql, sql/25_allergen_seed.sql).

-- --- Dogs ---------------------------------------------------------------------------
-- A helper keeps the rows readable: breed by name, coat from the breed.
CREATE TEMP TABLE demo_dog (id uuid, owner uuid, name text, breed text, sex dog_sex, born date);
INSERT INTO demo_dog VALUES
  ('00000000-0000-0000-0000-0000000d0d01', '00000000-0000-0000-0000-0000000d0a01', 'Jaddi',  'Shih Tzu',             'male',   NULL),
  ('00000000-0000-0000-0000-0000000d0d02', '00000000-0000-0000-0000-0000000d0a02', 'Pepper', 'Labradoodle',          'female', CURRENT_DATE - 1460),
  ('00000000-0000-0000-0000-0000000d0d03', '00000000-0000-0000-0000-0000000d0a03', 'Moose',  'Bernese Mountain Dog', 'male',   CURRENT_DATE - 2190),
  ('00000000-0000-0000-0000-0000000d0d04', '00000000-0000-0000-0000-0000000d0a04', 'Olive',  'Miniature Schnauzer',  'female', CURRENT_DATE - 2555),
  ('00000000-0000-0000-0000-0000000d0d05', '00000000-0000-0000-0000-0000000d0a05', 'Bear',   'Golden Retriever',     'male',   CURRENT_DATE - 1095),
  ('00000000-0000-0000-0000-0000000d0d06', '00000000-0000-0000-0000-0000000d0a06', 'Daisy',  'Cavalier King Charles Spaniel', 'female', CURRENT_DATE - 1825),
  ('00000000-0000-0000-0000-0000000d0d07', '00000000-0000-0000-0000-0000000d0a07', 'Rocket', 'Border Collie',        'male',   CURRENT_DATE - 1280),
  ('00000000-0000-0000-0000-0000000d0d08', '00000000-0000-0000-0000-0000000d0a08', 'Noodle', 'Toy Poodle',           'female', CURRENT_DATE - 77),
  ('00000000-0000-0000-0000-0000000d0d09', '00000000-0000-0000-0000-0000000d0a09', 'Gus',    'French Bulldog',       'male',   CURRENT_DATE - 900),
  ('00000000-0000-0000-0000-0000000d0d10', '00000000-0000-0000-0000-0000000d0a10', 'Tank',   'American Pit Bull Terrier', 'male',   CURRENT_DATE - 3100),
  ('00000000-0000-0000-0000-0000000d0d11', '00000000-0000-0000-0000-0000000d0a02', 'Willow', 'Shih Tzu',             'female', CURRENT_DATE - 2000);

INSERT INTO dog (id, owner_id, name, breed_id, coat_type_id, sex, date_of_birth)
SELECT d.id, d.owner, d.name, b.id, b.default_coat_type_id, d.sex, d.born
  FROM demo_dog d JOIN breed b ON b.name = d.breed;

-- Tank is a pit bull mix; his owner doesn't know what else.
UPDATE dog SET is_mixed = true WHERE id = '00000000-0000-0000-0000-0000000d0d10';

-- --- Vaccination records ---------------------------------------------------------------
-- (dog, vaccine, given days ago, expires in days, verification). Negative
-- "expires in" is in the past.
CREATE TEMP TABLE demo_shot (dog text, vaccine text, given_ago int, expires_in int, status verification_status);
INSERT INTO demo_shot VALUES
  -- Jaddi: the BetterVet certificate, 2024-02-29 to 2025-02-28 — real dates.
  ('Jaddi',  'rabies',     NULL, NULL, 'verified'),
  -- Pepper: everything in order.
  ('Pepper', 'rabies',      300,  795, 'verified'),
  ('Pepper', 'dhpp',        300,  795, 'verified'),
  ('Pepper', 'bordetella',  120,  245, 'verified'),
  -- Moose: rabies runs out in twelve days.
  ('Moose',  'rabies',     1083,   12, 'verified'),
  ('Moose',  'dhpp',        200,  895, 'verified'),
  ('Moose',  'bordetella',   90,  275, 'verified'),
  -- Olive: Bordetella lapsed three weeks ago; it does not stop a groom.
  ('Olive',  'rabies',      400,  695, 'verified'),
  ('Olive',  'dhpp',        400,  695, 'verified'),
  ('Olive',  'bordetella',  386,  -21, 'verified'),
  -- Bear: DHPP and Bordetella fine; rabies is being chased (below).
  ('Bear',   'dhpp',        150,  945, 'verified'),
  ('Bear',   'bordetella',  150,  215, 'verified'),
  -- Daisy: a certificate came in yesterday and nobody has checked it yet.
  ('Daisy',  'rabies',        5, 1090, 'unverified'),
  ('Daisy',  'dhpp',        210,  885, 'verified'),
  ('Daisy',  'bordetella',  210,  155, 'verified'),
  -- Rocket: the rabies certificate's dates don't match the vet's records.
  ('Rocket', 'rabies',      500,  595, 'disputed'),
  ('Rocket', 'dhpp',        500,  595, 'verified'),
  ('Rocket', 'bordetella',  100,  265, 'verified'),
  -- Noodle: eleven weeks old. Puppy shots so far; too young for rabies.
  ('Noodle', 'dhpp',         14,  351, 'verified'),
  ('Noodle', 'bordetella',   14,  351, 'verified'),
  -- Gus: a new client. Nothing on file yet.
  -- Tank: rabies lapsed three days ago.
  ('Tank',   'rabies',     1098,   -3, 'verified'),
  ('Tank',   'dhpp',        600,  495, 'verified'),
  ('Tank',   'bordetella',  200,  165, 'verified'),
  -- Willow: everything in order.
  ('Willow', 'rabies',      250,  845, 'verified'),
  ('Willow', 'dhpp',        250,  845, 'verified'),
  ('Willow', 'bordetella',   60,  305, 'verified');

INSERT INTO vaccination_record (dog_id, vaccine_type_id, administered_on, expires_on, entry_method,
                                verification_status, verified_by, verified_at)
SELECT dg.id, vt.id,
       COALESCE(CURRENT_DATE - s.given_ago, DATE '2024-02-29'),
       COALESCE(CURRENT_DATE + s.expires_in, DATE '2025-02-28'),
       'manual', s.status,
       CASE WHEN s.status <> 'unverified' THEN '00000000-0000-0000-0000-0000000d0b01'::uuid END,
       CASE WHEN s.status <> 'unverified' THEN now() END
  FROM demo_shot s
  JOIN dog dg          ON dg.name = s.dog
  JOIN vaccine_type vt ON vt.code = s.vaccine;

-- --- What the shop is chasing -------------------------------------------------------------
INSERT INTO record_request (dog_id, owner_id, vaccine_type_id, channel, recipient_address, status,
                            reminder_count, next_reminder_on, unsubscribe_token, created_by) VALUES
  -- Bear: asked for his rabies certificate a week ago.
  ('00000000-0000-0000-0000-0000000d0d05', '00000000-0000-0000-0000-0000000d0a05',
   (SELECT id FROM vaccine_type WHERE code = 'rabies'), 'email', 'tom@example.test', 'sent',
   1, CURRENT_DATE + 2, gen_random_uuid()::text, '00000000-0000-0000-0000-0000000d0b01'),
  -- Jaddi: the Doc Side invoice names his rabies shot but prints no expiry.
  ('00000000-0000-0000-0000-0000000d0d01', '00000000-0000-0000-0000-0000000d0a01',
   (SELECT id FROM vaccine_type WHERE code = 'rabies'), 'email', 'jason@example.test', 'insufficient',
   0, NULL, gen_random_uuid()::text, '00000000-0000-0000-0000-0000000d0b01');

-- --- Allergies ----------------------------------------------------------------------------------
INSERT INTO allergy (dog_id, allergen_id, severity_ordinal, source, note, recorded_by)
SELECT dg.id, al.id, a.sev, a.src::allergy_source, a.note, '00000000-0000-0000-0000-0000000d0b01'
  FROM (VALUES
    ('Tank',   'Chlorhexidine shampoo', 4, 'vet_documented', 'Hives within minutes. Hypoallergenic shampoo only.'),
    ('Pepper', 'Oatmeal shampoo',       2, 'owner_reported', 'Itchy for a day or two afterwards.'),
    ('Willow', 'Added fragrance',       3, 'observed',       'Red, weepy eyes after a scented finishing spray.'),
    ('Olive',  'Tea tree oil',          1, 'owner_reported', NULL)
  ) a(dog, allergen, sev, src, note)
  JOIN dog dg      ON dg.name = a.dog
  JOIN allergen al ON al.name = a.allergen;

-- --- Behaviour ----------------------------------------------------------------------------------
INSERT INTO behavior_note (dog_id, handling_difficulty_ordinal, body_zone_id, trigger_kind, note,
                           observed_at, observed_by)
SELECT dg.id, b.diff, bz.id, b.trig, b.note, now() - (b.days_ago || ' days')::interval,
       '00000000-0000-0000-0000-0000000d0b02'
  FROM (VALUES
    ('Pepper', 3, NULL,        'dryer',        'Fine with the stand dryer on low. Panics at the force dryer near her face.', 40),
    ('Moose',  4, 'feet', 'nail_grinder', 'Two people for nails. Grinder only, no clippers.', 75),
    ('Willow', 4, 'ears',      'other',        'Snaps when her ears are plucked. Muzzle for that part only.', 20),
    ('Tank',   2, NULL,        'water',        'Wary of the tub. Lift him in; he settles once he is wet.', 120),
    ('Olive',  1, NULL,        NULL,           'An easy groom. Loves the table.', 30)
  ) b(dog, diff, zone, trig, note, days_ago)
  JOIN dog dg ON dg.name = b.dog
  LEFT JOIN body_zone bz ON bz.code = b.zone;

-- --- Past visits ------------------------------------------------------------------------------------
INSERT INTO visit (dog_id, performed_by, visit_date, check_in, check_out, overall_note)
SELECT dg.id, g.id, CURRENT_DATE - v.days_ago, v.cin::time, v.cout::time, v.note
  FROM (VALUES
    ('Pepper', 'Tanya', 40,  '09:00', '11:15', 'Teddy bear trim, medium. Force dryer kept away from the face.'),
    ('Pepper', 'Tanya', 96,  '09:30', '11:40', NULL),
    ('Moose',  'Nadia', 75,  '13:00', '15:30', 'Deshed and bath. Nails with two people.'),
    ('Olive',  'Tanya', 30,  '10:00', '11:00', 'Schnauzer trim.'),
    ('Willow', 'Nadia', 20,  '14:00', '15:20', 'Puppy cut, short. Muzzle on for ears only.'),
    ('Tank',   'Nadia', 120, '08:30', '09:30', 'Bath, hypoallergenic shampoo.')
  ) v(dog, groomer, days_ago, cin, cout, note)
  JOIN dog dg     ON dg.name = v.dog
  JOIN groomer g  ON g.display_name = v.groomer;

DROP TABLE demo_dog, demo_shot;
