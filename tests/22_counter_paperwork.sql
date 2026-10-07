-- Paperwork at the counter: a photo of the owner's paperwork is kept with the
-- dog, and a shot typed in while reading it counts as verified.
--
-- Eight things are proven:
--   1. A copy taken at the counter is filed against the owner and the dog,
--      and waits on the manager's list; the same file twice is one copy.
--   2. A shot cannot be checked by hand against a copy that is not on file
--      for that dog (GR027).
--   3. A shot checked by hand is verified by whoever checked it, linked to the
--      photo and marked checked by hand, and the dog reads Current.
--   4. The section 22 rules still hold: no expiry, no record (GR021).
--   5. A groomer's hand check waits for a manager's second look, which only a
--      manager can give (GR028); a manager's own check needs none.
--   6. A shot typed in earlier with no photo becomes verified once it is
--      checked against one.
--   7. Done with a copy takes it off the list; receiving it again puts it back.
--   8. Nothing is marked checked by hand without a photo behind it.

BEGIN;
SET search_path = groom, public;
SELECT plan(22);

CREATE TEMP TABLE t_owner AS
SELECT add_client('Rosa', 'Diaz', '410-555-0400', NULL, '00000000-0000-0000-0000-00000000b002') AS id;
CREATE TEMP TABLE t_dog AS
SELECT add_dog((SELECT id FROM t_owner), 'Pepper', NULL, 'curly', 'female', NULL,
               '00000000-0000-0000-0000-00000000b002') AS id;

-- --- 1. The copy ---------------------------------------------------------------------------------------
CREATE TEMP TABLE t_doc AS
SELECT receive_paperwork((SELECT id FROM t_dog), 'private/counter/test-a.jpg', 'image/jpeg', 120000,
                         repeat('a', 64), 1, true, '00000000-0000-0000-0000-00000000b002') AS id;

SELECT results_eq(
  $$ SELECT owner_id, source::text, exif_stripped FROM document WHERE id = (SELECT id FROM t_doc) $$,
  $$ SELECT (SELECT id FROM t_owner), 'upload'::text, true $$,
  'A copy taken at the counter is filed against the owner, as an upload');

SELECT is(
  (SELECT count(*) FROM document_dog WHERE document_id = (SELECT id FROM t_doc) AND dog_id = (SELECT id FROM t_dog)),
  1::bigint, 'And against the dog');

SELECT is(
  (SELECT received_by FROM v_paperwork_waiting WHERE document_id = (SELECT id FROM t_doc)),
  'Tanya', 'It waits on the manager''s list, with who took it');

SELECT is(
  receive_paperwork((SELECT id FROM t_dog), 'private/counter/test-a-again.jpg', 'image/jpeg', 120000,
                    repeat('a', 64), 1, true, '00000000-0000-0000-0000-00000000b002'),
  (SELECT id FROM t_doc), 'The same file twice is the copy already on file');

SELECT is(
  (SELECT count(*) FROM document WHERE owner_id = (SELECT id FROM t_owner)), 1::bigint,
  'And is stored once');

-- --- 2. A copy that is not this dog's -----------------------------------------------------------------------
SELECT throws_ok(
  $$ SELECT record_checked_shot('00000000-0000-0000-0000-00000000d001', (SELECT id FROM t_doc), 'rabies',
                                CURRENT_DATE - 30, CURRENT_DATE + 1065, '00000000-0000-0000-0000-00000000b002') $$,
  'GR027', NULL, 'A shot cannot be checked against another dog''s paperwork');

SELECT throws_ok(
  $$ SELECT record_checked_shot((SELECT id FROM t_dog), NULL, 'rabies',
                                CURRENT_DATE - 30, CURRENT_DATE + 1065, '00000000-0000-0000-0000-00000000b002') $$,
  'GR027', NULL, 'Or against no paperwork at all');

-- --- 3. Checked by hand ---------------------------------------------------------------------------------------
CREATE TEMP TABLE t_rabies AS
SELECT record_checked_shot((SELECT id FROM t_dog), (SELECT id FROM t_doc), 'rabies',
                           CURRENT_DATE - 30, CURRENT_DATE + 1065, '00000000-0000-0000-0000-00000000b002') AS id;

SELECT results_eq(
  $$ SELECT entry_method::text, verification_status::text, verified_by, document_id, checked_by_hand
       FROM vaccination_record WHERE id = (SELECT id FROM t_rabies) $$,
  $$ SELECT 'manual'::text, 'verified'::text, '00000000-0000-0000-0000-00000000b002'::uuid,
            (SELECT id FROM t_doc), true $$,
  'A shot checked against the photo is verified by the groomer, linked to the photo, and marked checked by hand');

SELECT is(
  (SELECT state::text FROM v_check_in_vaccine WHERE dog_id = (SELECT id FROM t_dog) AND vaccine_code = 'rabies'),
  'current', 'The dog reads Current for it, not "awaiting verification"');

SELECT is(
  (SELECT count(*) FROM audit_log WHERE entity_type = 'vaccination_record' AND entity_id = (SELECT id FROM t_rabies)
      AND changed_fields ->> 'checked_by_hand' = 'true' AND actor_label = 'Tanya'),
  1::bigint, 'The check is audited with who did it');

-- --- 4. Still no expiry, no record ----------------------------------------------------------------------------
SELECT throws_ok(
  $$ SELECT record_checked_shot((SELECT id FROM t_dog), (SELECT id FROM t_doc), 'dhpp',
                                CURRENT_DATE - 30, NULL, '00000000-0000-0000-0000-00000000b002') $$,
  'GR021', NULL, 'A photo does not stand in for an expiry date');

-- --- 5. The second look ----------------------------------------------------------------------------------------
SELECT is(
  (SELECT checked_by FROM v_hand_checked_open WHERE id = (SELECT id FROM t_rabies)),
  'Tanya', 'A groomer''s hand check goes on the manager''s list for a second look');

SELECT throws_ok(
  $$ SELECT give_second_look((SELECT id FROM t_rabies), '00000000-0000-0000-0000-00000000b002') $$,
  'GR028', NULL, 'Only a manager gives the second look');

SELECT lives_ok(
  $$ SELECT give_second_look((SELECT id FROM t_rabies), '00000000-0000-0000-0000-00000000b001') $$,
  'A manager can');

SELECT is(
  (SELECT count(*) FROM v_hand_checked_open WHERE id = (SELECT id FROM t_rabies)), 0::bigint,
  'And it comes off the list');

CREATE TEMP TABLE t_dhpp AS
SELECT record_checked_shot((SELECT id FROM t_dog), (SELECT id FROM t_doc), 'dhpp',
                           CURRENT_DATE - 30, CURRENT_DATE + 335, '00000000-0000-0000-0000-00000000b001') AS id;

SELECT is(
  (SELECT second_look_by FROM vaccination_record WHERE id = (SELECT id FROM t_dhpp)),
  '00000000-0000-0000-0000-00000000b001'::uuid, 'A manager''s own hand check is its own second look');

-- --- 6. Typed in earlier, checked now ----------------------------------------------------------------------------
CREATE TEMP TABLE t_bord AS
SELECT record_counter_shot((SELECT id FROM t_dog), 'bordetella', CURRENT_DATE - 30, CURRENT_DATE + 150,
                           '00000000-0000-0000-0000-00000000b002') AS id;

SELECT is(
  record_checked_shot((SELECT id FROM t_dog), (SELECT id FROM t_doc), 'bordetella',
                      CURRENT_DATE - 30, CURRENT_DATE + 150, '00000000-0000-0000-0000-00000000b002'),
  (SELECT id FROM t_bord), 'A shot typed in with no photo is the same record when checked against one');

SELECT results_eq(
  $$ SELECT verification_status::text, checked_by_hand FROM vaccination_record WHERE id = (SELECT id FROM t_bord) $$,
  $$ VALUES ('verified'::text, true) $$,
  'And is now verified');

-- --- 7. Done, and received again ---------------------------------------------------------------------------------
SELECT finish_paperwork_check((SELECT id FROM t_doc), (SELECT id FROM t_dog), '00000000-0000-0000-0000-00000000b002');

SELECT is(
  (SELECT count(*) FROM v_paperwork_waiting WHERE document_id = (SELECT id FROM t_doc)), 0::bigint,
  'Done with a copy takes it off the list');

SELECT receive_paperwork((SELECT id FROM t_dog), 'private/counter/test-a.jpg', 'image/jpeg', 120000,
                         repeat('a', 64), 1, true, '00000000-0000-0000-0000-00000000b001');

SELECT is(
  (SELECT received_by FROM v_paperwork_waiting WHERE document_id = (SELECT id FROM t_doc)),
  'Nadia', 'Receiving it again puts it back');

-- --- 8. No photo, no hand check -------------------------------------------------------------------------------------
SELECT throws_ok(
  $$ UPDATE vaccination_record SET document_id = NULL WHERE id = (SELECT id FROM t_bord) $$,
  '23514', NULL, 'A record checked by hand cannot lose the photo it was checked against');

SELECT throws_ok(
  $$ UPDATE vaccination_record SET verification_status = 'unverified', verified_by = NULL, verified_at = NULL
      WHERE id = (SELECT id FROM t_bord) $$,
  '23514', NULL, 'Nor be checked by hand and unverified at once');

SELECT * FROM finish();
ROLLBACK;
