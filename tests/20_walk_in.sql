-- Walk-ins: a new client and their dog are added at the counter, and the
-- shots on the paper they brought are typed in.
--
-- Eight things are proven:
--   1. A new client is added and audited; the same email twice is one owner,
--      and an owner the shop cannot reach is refused.
--   2. A dog of a breed the shop has never seen adds the breed, with the
--      dog's coat as its usual coat; a known breed fills in the coat when it
--      is left blank; no coat at all is refused.
--   3. A walk-in with no paperwork cannot be groomed (GR020, as for anyone).
--   4. A shot typed in off the paper is manual and unverified, and the dog
--      can be groomed today.
--   5. No expiry on the paper, no record (GR021) — and nothing is written.
--   6. A shot given in the future, or expiring before it was given, is GR021.
--   7. The same shot typed twice is one record; a different date for the
--      same shot is GR022 and leaves the record on file alone.
--   8. A current shot answers the shop's open request for it, and the entry
--      is audited with who typed it.

BEGIN;
SET search_path = groom, public;
SELECT plan(21);

-- --- 1. The owner --------------------------------------------------------------------
CREATE TEMP TABLE t_owner AS
SELECT add_client(' Maria ', 'Lopez', '410-555-0300', 'Maria@Example.test',
                  '00000000-0000-0000-0000-00000000b002') AS id;

SELECT results_eq(
  $$ SELECT first_name, last_name, email FROM owner WHERE id = (SELECT id FROM t_owner) $$,
  $$ VALUES ('Maria'::text, 'Lopez'::text, 'maria@example.test'::text) $$,
  'A new client is saved tidied: no stray spaces, the email in lower case');

SELECT is(
  (SELECT actor_label FROM audit_log WHERE entity_type = 'owner' AND entity_id = (SELECT id FROM t_owner)),
  'Tanya', 'Adding a client is audited with who did it');

SELECT throws_ok(
  $$ SELECT add_client('M', 'Lopez', NULL, 'MARIA@example.test', '00000000-0000-0000-0000-00000000b002') $$,
  '23505', 'An owner with the email maria@example.test is already on file',
  'The same email twice is the same owner, not a second one');

SELECT throws_ok(
  $$ SELECT add_client('Sam', 'Nobody', ' ', '', '00000000-0000-0000-0000-00000000b002') $$,
  '23514', NULL, 'A client with neither a phone nor an email is refused: the shop could never reach them');

-- --- 2. The dog --------------------------------------------------------------------------
CREATE TEMP TABLE t_dog AS
SELECT add_dog((SELECT id FROM t_owner), 'Biscuit', 'Cavapoo', 'curly', 'female',
               CURRENT_DATE - 800, '00000000-0000-0000-0000-00000000b002') AS id;

SELECT results_eq(
  $$ SELECT b.name, ct.code FROM breed b JOIN coat_type ct ON ct.id = b.default_coat_type_id
      WHERE b.id = (SELECT breed_id FROM dog WHERE id = (SELECT id FROM t_dog)) $$,
  $$ VALUES ('Cavapoo'::text, 'curly'::text) $$,
  'A breed the shop has not seen is added, with this dog''s coat as its usual coat');

CREATE TEMP TABLE t_mochi AS
SELECT add_dog((SELECT id FROM t_owner), 'Mochi', 'shih tzu', NULL, NULL, NULL,
               '00000000-0000-0000-0000-00000000b002') AS id;

SELECT is(
  (SELECT ct.code FROM dog d JOIN coat_type ct ON ct.id = d.coat_type_id WHERE d.id = (SELECT id FROM t_mochi)),
  'silky', 'A known breed, in any case, fills in the coat when it is left blank');

SELECT throws_ok(
  $$ SELECT add_dog((SELECT id FROM t_owner), 'Rolo', 'Not sure', NULL, NULL, NULL,
                    '00000000-0000-0000-0000-00000000b002') $$,
  '23514', 'Choose the dog''s coat type', 'No coat and no known breed to take one from: refused');

SELECT is((SELECT count(*) FROM breed WHERE name = 'Not sure'), 0::bigint,
  'A refused dog leaves no breed behind');

-- --- 3. No paperwork, no groom ---------------------------------------------------------------
SELECT throws_ok(
  $$ SELECT start_visit((SELECT id FROM t_dog), '00000000-0000-0000-0000-00000000b002') $$,
  'GR020', 'Cannot start the groom: Rabies (no record on file)',
  'A walk-in is held to the same rule as everyone: no rabies record, no groom');

-- --- 5. No expiry, no record (before 4, so Biscuit is still bare) -----------------------------------
SELECT throws_ok(
  $$ SELECT record_counter_shot((SELECT id FROM t_dog), 'rabies', CURRENT_DATE - 30, NULL,
                                '00000000-0000-0000-0000-00000000b002') $$,
  'GR021', 'Rabies: no expiry date, so it cannot be recorded',
  'The Jaddi case at the counter: a paper with no expiry date makes no record');

SELECT is((SELECT count(*) FROM vaccination_record WHERE dog_id = (SELECT id FROM t_dog)), 0::bigint,
  'And nothing is written');

-- --- 6. Dates that cannot be right --------------------------------------------------------------------
SELECT throws_ok(
  $$ SELECT record_counter_shot((SELECT id FROM t_dog), 'rabies', CURRENT_DATE + 3, CURRENT_DATE + 400,
                                '00000000-0000-0000-0000-00000000b002') $$,
  'GR021', NULL, 'A shot given in the future is refused');

SELECT throws_ok(
  $$ SELECT record_counter_shot((SELECT id FROM t_dog), 'rabies', CURRENT_DATE - 30, CURRENT_DATE - 60,
                                '00000000-0000-0000-0000-00000000b002') $$,
  'GR021', NULL, 'A shot that expires before it was given is refused');

-- --- 4. Typed in, groomable --------------------------------------------------------------------------------
INSERT INTO record_request (dog_id, owner_id, vaccine_type_id, channel, status, created_by)
VALUES ((SELECT id FROM t_dog), (SELECT id FROM t_owner), (SELECT id FROM vaccine_type WHERE code = 'rabies'),
        'verbal_at_counter', 'sent', '00000000-0000-0000-0000-00000000b002');

CREATE TEMP TABLE t_shot AS
SELECT record_counter_shot((SELECT id FROM t_dog), 'rabies', CURRENT_DATE - 30, CURRENT_DATE + 1065,
                           '00000000-0000-0000-0000-00000000b002') AS id;

SELECT results_eq(
  $$ SELECT entry_method::text, verification_status::text FROM vaccination_record WHERE id = (SELECT id FROM t_shot) $$,
  $$ VALUES ('manual', 'unverified') $$,
  'A shot typed in at the counter is manual, and unverified until a manager checks it');

SELECT is(
  (SELECT state::text FROM v_dog_vaccine_compliance c JOIN vaccine_type vt ON vt.id = c.vaccine_type_id
    WHERE c.dog_id = (SELECT id FROM t_dog) AND vt.code = 'rabies'),
  'received_unverified', 'The dog reads "Received, awaiting verification"');

SELECT lives_ok(
  $$ SELECT start_visit((SELECT id FROM t_dog), '00000000-0000-0000-0000-00000000b002') $$,
  'And can be groomed today');

-- --- 7. Twice is once; a disagreement is a manager's -----------------------------------------------------------
SELECT is(
  record_counter_shot((SELECT id FROM t_dog), 'rabies', CURRENT_DATE - 30, CURRENT_DATE + 1065,
                      '00000000-0000-0000-0000-00000000b001'),
  (SELECT id FROM t_shot), 'The same shot typed twice is the record already there');

SELECT throws_ok(
  $$ SELECT record_counter_shot((SELECT id FROM t_dog), 'rabies', CURRENT_DATE - 28, CURRENT_DATE + 700,
                                '00000000-0000-0000-0000-00000000b002') $$,
  'GR022', NULL, 'The same shot with different dates is a disagreement, not a second record');

SELECT is((SELECT count(*) FROM vaccination_record WHERE dog_id = (SELECT id FROM t_dog)), 1::bigint,
  'And the record on file is the only one');

-- --- 8. The request is answered, and it is audited -----------------------------------------------------------
SELECT is(
  (SELECT status::text FROM record_request WHERE dog_id = (SELECT id FROM t_dog)),
  'resolved', 'A current shot answers the shop''s open request for it');

SELECT results_eq(
  $$ SELECT actor_label, changed_fields->>'source' FROM audit_log
      WHERE entity_type = 'vaccination_record' AND entity_id = (SELECT id FROM t_shot) $$,
  $$ VALUES ('Tanya'::text, 'counter'::text) $$,
  'The entry is audited once, with who typed it and that it came from the counter');

SELECT * FROM finish();
ROLLBACK;
