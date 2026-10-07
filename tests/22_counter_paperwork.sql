-- Paperwork at the counter: a photo of the owner's paperwork is kept with the
-- dog, and a shot typed in while reading it counts as verified.
--
-- Ten things are proven:
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
--   9. A vaccine the paperwork does not show is asked for at the counter: one
--      open request, followed up by the reminders; nothing to ask for when a
--      current record is on file.
--  10. A copy is its pages, in order. One nobody checked a shot against can be
--      removed, files and all, or lose a page; one a record rests on cannot (GR029).

BEGIN;
SET search_path = groom, public;
SELECT plan(37);

CREATE TEMP TABLE t_owner AS
SELECT add_client('Rosa', 'Diaz', '410-555-0400', NULL, '00000000-0000-0000-0000-00000000b002') AS id;
CREATE TEMP TABLE t_dog AS
SELECT add_dog((SELECT id FROM t_owner), 'Pepper', NULL, 'curly', 'female', NULL,
               '00000000-0000-0000-0000-00000000b002') AS id;

-- --- 1. The copy ---------------------------------------------------------------------------------------
CREATE TEMP TABLE t_doc AS
SELECT receive_paperwork((SELECT id FROM t_dog), 'private/counter/test-a.pdf', 'application/pdf', 120000,
                         repeat('a', 64), ARRAY['private/counter/test-a-p1.jpg', 'private/counter/test-a-p2.jpg'], true, '00000000-0000-0000-0000-00000000b002') AS id;

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
  receive_paperwork((SELECT id FROM t_dog), 'private/counter/test-a-again.pdf', 'application/pdf', 120000,
                    repeat('a', 64), ARRAY['private/counter/test-a-again-p1.jpg'], true, '00000000-0000-0000-0000-00000000b002'),
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

SELECT receive_paperwork((SELECT id FROM t_dog), 'private/counter/test-a.pdf', 'application/pdf', 120000,
                         repeat('a', 64), ARRAY['private/counter/test-a-p1.jpg', 'private/counter/test-a-p2.jpg'], true, '00000000-0000-0000-0000-00000000b001');

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

-- --- 9. Not on the paperwork -----------------------------------------------------------------------------------
CREATE TEMP TABLE t_ask AS
SELECT ask_owner_at_counter((SELECT id FROM t_dog), 'leptospirosis', '00000000-0000-0000-0000-00000000b002') AS id;

SELECT results_eq(
  $$ SELECT channel::text, status::text, next_reminder_on FROM record_request WHERE id = (SELECT id FROM t_ask) $$,
  $$ SELECT 'verbal_at_counter'::text, 'sent'::text, CURRENT_DATE + reminder_interval_days() $$,
  'A vaccine not on the paperwork is asked for at the counter, with a reminder due');

SELECT is(
  ask_owner_at_counter((SELECT id FROM t_dog), 'leptospirosis', '00000000-0000-0000-0000-00000000b001'),
  (SELECT id FROM t_ask), 'Asking twice is the same request');

SELECT throws_ok(
  $$ SELECT ask_owner_at_counter((SELECT id FROM t_dog), 'rabies', '00000000-0000-0000-0000-00000000b002') $$,
  '23514', NULL, 'There is nothing to ask for when a current record is on file');

CREATE TEMP TABLE t_dog2 AS
SELECT add_dog((SELECT id FROM t_owner), 'Salt', NULL, 'curly', 'male', NULL,
               '00000000-0000-0000-0000-00000000b002') AS id;
SELECT ask_owner_at_counter((SELECT id FROM t_dog2), 'rabies', '00000000-0000-0000-0000-00000000b002');

SELECT is(
  (SELECT state::text FROM v_check_in_vaccine WHERE dog_id = (SELECT id FROM t_dog2) AND vaccine_code = 'rabies'),
  'requested_pending', 'The card reads "Requested, awaiting response"');

SELECT is(
  (SELECT count(*) FROM audit_log WHERE entity_type = 'record_request' AND actor_label = 'Tanya'
      AND changed_fields ->> 'reason' = 'not on the paperwork'),
  2::bigint, 'And who asked is audited');

-- --- 10. Pages, and removing a copy -------------------------------------------------------------------------------
SELECT results_eq(
  $$ SELECT page_number, render_object_key FROM document_page WHERE document_id = (SELECT id FROM t_doc) ORDER BY 1 $$,
  $$ VALUES (1, 'private/counter/test-a-p1.jpg'), (2, 'private/counter/test-a-p2.jpg') $$,
  'A copy of two photos is one copy with two pages, in order');

SELECT is((SELECT page_count FROM document WHERE id = (SELECT id FROM t_doc)), 2, 'And says so');

SELECT throws_ok(
  $$ SELECT remove_paperwork((SELECT id FROM t_doc), (SELECT id FROM t_dog), '00000000-0000-0000-0000-00000000b002') $$,
  'GR029', NULL, 'A copy shots were checked against cannot be removed');

CREATE TEMP TABLE t_blurry AS
SELECT receive_paperwork((SELECT id FROM t_dog), 'private/counter/blurry.jpg', 'image/jpeg', 90000,
                         repeat('b', 64), ARRAY['private/counter/blurry.jpg'], true,
                         '00000000-0000-0000-0000-00000000b002') AS id;

CREATE TEMP TABLE t_three AS
SELECT receive_paperwork((SELECT id FROM t_dog), 'private/counter/three.pdf', 'application/pdf', 90000,
                         repeat('c', 64), ARRAY['private/counter/p1.jpg', 'private/counter/dark.jpg', 'private/counter/p3.jpg'],
                         true, '00000000-0000-0000-0000-00000000b002') AS id;

SELECT is(
  remove_paperwork_page((SELECT id FROM t_three), (SELECT id FROM t_dog), 2, '00000000-0000-0000-0000-00000000b002',
                        'private/counter/three-v2.pdf', 60000, repeat('d', 64)),
  ARRAY['private/counter/dark.jpg', 'private/counter/three.pdf'],
  'A dark page can be taken out of a copy; its file and the old copy file are named for deleting');

SELECT results_eq(
  $$ SELECT page_number, render_object_key FROM document_page WHERE document_id = (SELECT id FROM t_three) ORDER BY 1 $$,
  $$ VALUES (1, 'private/counter/p1.jpg'), (2, 'private/counter/p3.jpg') $$,
  'The pages after it move up');

SELECT throws_ok(
  $$ SELECT remove_paperwork_page((SELECT id FROM t_doc), (SELECT id FROM t_dog), 2, '00000000-0000-0000-0000-00000000b002',
                                  'x.pdf', 1, repeat('e', 64)) $$,
  'GR029', NULL, 'No page comes out of a copy a record rests on');

SELECT throws_ok(
  $$ SELECT remove_paperwork_page((SELECT id FROM t_blurry), (SELECT id FROM t_dog), 1, '00000000-0000-0000-0000-00000000b002',
                                  'x.pdf', 1, repeat('e', 64)) $$,
  '23514', NULL, 'The only page is removed by removing the copy');

SELECT is(
  remove_paperwork((SELECT id FROM t_blurry), (SELECT id FROM t_dog), '00000000-0000-0000-0000-00000000b002'),
  ARRAY['private/counter/blurry.jpg'], 'A blurry photo nobody used can be removed, and its file is named for deleting');

SELECT is((SELECT count(*) FROM document WHERE id = (SELECT id FROM t_blurry)), 0::bigint,
  'It is gone, off the list with it');

SELECT is(
  (SELECT count(*) FROM audit_log WHERE entity_type = 'document' AND entity_id = (SELECT id FROM t_blurry) AND action = 'delete'),
  1::bigint, 'And who removed it is audited');

SELECT * FROM finish();
ROLLBACK;
