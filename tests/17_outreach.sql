-- Owner outreach: the shop asks by itself only when it may, once per dog, and
-- not too often.
--
-- Jason (a001) owns Jaddi and Luna, and has an email and a phone. Dana (a002)
-- owns Biscuit, has opted out of email (GR005), and has a phone.
--
-- Nine things are proven:
--   1. Consent is a history, the latest answer wins, no answer is a no, and
--      an email opt-out beats a yes.
--   2. Nothing automated without consent (GR019), and what can't be automated
--      is listed for a person with the reason.
--   3. One message per owner per dog, naming every vaccine needed, on the
--      channel the owner allows — and two requests for one shot are one ask.
--   4. Sending moves every request it asked about to 'sent', counts it, and
--      schedules the reminder; the dashboard reads "requested".
--   5. A reminder waits for its date, and says it is a reminder.
--   6. After max_reminders it is a person's job, not the sender's.
--   7. A failed send changes nothing, so the next run asks again.
--   8. Consent withdrawn after queueing stops the send (GR019 again).
--   9. Texts are short, signed, and say how to stop them.

BEGIN;
SET search_path = groom, public;
SELECT plan(25);

-- --- Fixture --------------------------------------------------------------------
INSERT INTO record_request (id, dog_id, owner_id, vaccine_type_id, channel, recipient_address,
                            status, unsubscribe_token) VALUES
  -- Luna: two vaccines a confirmed page could not evidence.
  ('00000000-0000-0000-0000-0000000f5001', '00000000-0000-0000-0000-00000000d002',
   '00000000-0000-0000-0000-00000000a001', (SELECT id FROM vaccine_type WHERE code = 'rabies'),
   'email', 'jason@example.test', 'insufficient', 't1'),
  ('00000000-0000-0000-0000-0000000f5002', '00000000-0000-0000-0000-00000000d002',
   '00000000-0000-0000-0000-00000000a001', (SELECT id FROM vaccine_type WHERE code = 'bordetella'),
   'email', 'jason@example.test', 'insufficient', 't2'),
  -- Biscuit: one.
  ('00000000-0000-0000-0000-0000000f5003', '00000000-0000-0000-0000-00000000d003',
   '00000000-0000-0000-0000-00000000a002', (SELECT id FROM vaccine_type WHERE code = 'dhpp'),
   'sms', '410-555-0101', 'insufficient', NULL),
  -- Jaddi: DHPP twice — a staff member's request, and a confirmation's.
  ('00000000-0000-0000-0000-0000000f5004', '00000000-0000-0000-0000-00000000d001',
   '00000000-0000-0000-0000-00000000a001', (SELECT id FROM vaccine_type WHERE code = 'dhpp'),
   'email', 'jason@example.test', 'queued', 't4'),
  ('00000000-0000-0000-0000-0000000f5005', '00000000-0000-0000-0000-00000000d001',
   '00000000-0000-0000-0000-00000000a001', (SELECT id FROM vaccine_type WHERE code = 'dhpp'),
   'email', 'jason@example.test', 'insufficient', 't5');

-- --- 1. Consent -------------------------------------------------------------------
SELECT is(may_message('00000000-0000-0000-0000-00000000a001', 'email'), false,
  'No answer is a no: Jason has never been asked');

INSERT INTO contact_consent (owner_id, channel, granted, source, recorded_by) VALUES
  ('00000000-0000-0000-0000-00000000a001', 'email', true, 'ticked the box on the intake form',
   '00000000-0000-0000-0000-00000000b001'),
  ('00000000-0000-0000-0000-00000000a002', 'email', true, 'said yes at the counter',
   '00000000-0000-0000-0000-00000000b002');

SELECT is(may_message('00000000-0000-0000-0000-00000000a001', 'email'), true,
  'Jason said yes to email');

SELECT throws_ok(
  $$ UPDATE contact_consent SET granted = false WHERE owner_id = '00000000-0000-0000-0000-00000000a001' $$,
  'P0001', NULL,
  'A consent answer is never rewritten — a change of mind is a new entry');

SELECT is(may_message('00000000-0000-0000-0000-00000000a002', 'email'), false,
  'Dana said yes to email, but she opted out of email: the opt-out wins');

-- --- 2. Nothing without consent ---------------------------------------------------------
SELECT throws_ok(
  $$ INSERT INTO outreach_message (owner_id, dog_id, channel, recipient_address, body, is_reminder)
     VALUES ('00000000-0000-0000-0000-00000000a002', '00000000-0000-0000-0000-00000000d003',
             'sms', '410-555-0101', 'hello', false) $$,
  'GR019', NULL,
  'A text to an owner who never agreed to texts cannot even be queued');

SELECT results_eq(
  $$ SELECT dog_name, vaccine, why FROM v_outreach_for_staff WHERE dog_name = 'Biscuit' $$,
  $$ VALUES ('Biscuit', 'DHPP', 'no consent to email or text — ask at the counter, and record their answer') $$,
  'What the sender may not send is a list for a person, with the reason');

-- --- 3. Queueing ----------------------------------------------------------------------------
CREATE TEMP TABLE t_q1 AS SELECT id FROM enqueue_due_outreach() AS id;

SELECT results_eq(
  $$ SELECT d.name, m.channel::text, m.recipient_address, m.is_reminder
       FROM outreach_message m JOIN dog d ON d.id = m.dog_id
      WHERE m.id IN (SELECT id FROM t_q1) ORDER BY d.name $$,
  $$ VALUES ('Jaddi', 'email', 'jason@example.test', false),
            ('Luna',  'email', 'jason@example.test', false) $$,
  'One email per dog for Jason, none for Dana');

SELECT ok((SELECT m.subject = 'Luna''s vaccination records'
              AND m.body LIKE '%- Bordetella%' AND m.body LIKE '%- Rabies%'
              AND m.body LIKE 'Hi Jason,%' AND m.body LIKE '%records@pawsandpolish.example%'
             FROM outreach_message m WHERE m.dog_id = '00000000-0000-0000-0000-00000000d002'),
  'Luna''s message asks for both vaccines by name, in one email, and says where to send them');

SELECT results_eq(
  $$ SELECT rr.status::text,
            (SELECT count(*) FROM outreach_message_request mr WHERE mr.record_request_id = rr.id)
       FROM record_request rr
      WHERE rr.id IN ('00000000-0000-0000-0000-0000000f5004', '00000000-0000-0000-0000-0000000f5005')
      ORDER BY rr.id $$,
  $$ VALUES ('abandoned', 0::bigint), ('insufficient', 1::bigint) $$,
  'Two requests for Jaddi''s one DHPP shot are one ask: the duplicate is closed, not sent twice');

SELECT is((SELECT count(*) FROM enqueue_due_outreach()), 0::bigint,
  'Nothing is queued twice while a message is waiting to go');

-- --- 4. Sending ------------------------------------------------------------------------------
SELECT mark_outreach_sent((SELECT id FROM outreach_message WHERE dog_id = '00000000-0000-0000-0000-00000000d002'),
                          'test-mode', 'test-0001');

SELECT results_eq(
  $$ SELECT status::text, reminder_count, next_reminder_on FROM record_request
      WHERE id IN ('00000000-0000-0000-0000-0000000f5001', '00000000-0000-0000-0000-0000000f5002') $$,
  $$ VALUES ('sent', 1, CURRENT_DATE + 7), ('sent', 1, CURRENT_DATE + 7) $$,
  'Both of Luna''s requests are sent, counted, and due a reminder in reminder_interval_days');

SELECT is((SELECT count(*) FROM record_request_event
            WHERE event_type = 'sent' AND provider_message_id = 'test-0001'), 2::bigint,
  'Each request records the send, with the provider''s message id');

SELECT is((SELECT state::text FROM v_dog_vaccine_compliance
            WHERE dog_id = '00000000-0000-0000-0000-00000000d002' AND vaccine_code = 'rabies'),
  'requested_pending', 'The dashboard now reads "requested": the shop has asked and is waiting');

SELECT is((SELECT count(*) FROM audit_log WHERE action = 'send_request' AND entity_type = 'outreach_message'),
  1::bigint, 'The send is in the audit log');

SELECT is((SELECT count(*) FROM enqueue_due_outreach()), 0::bigint,
  'A request just asked about is not asked about again before its reminder date');

-- --- 5. Reminders ------------------------------------------------------------------------------
UPDATE record_request SET next_reminder_on = CURRENT_DATE
 WHERE id IN ('00000000-0000-0000-0000-0000000f5001', '00000000-0000-0000-0000-0000000f5002');

CREATE TEMP TABLE t_q2 AS SELECT id FROM enqueue_due_outreach() AS id;

SELECT results_eq(
  $$ SELECT is_reminder, left(subject, 9), body LIKE '%A quick reminder.%'
       FROM outreach_message WHERE id IN (SELECT id FROM t_q2) $$,
  $$ VALUES (true, 'Reminder:', true) $$,
  'On its date, one reminder for Luna — and it says it is one');

-- --- 6. The cap -------------------------------------------------------------------------------
SELECT cancel_outreach((SELECT id FROM t_q2), 'test: cleared to set up the cap');
UPDATE record_request SET reminder_count = max_reminders
 WHERE id IN ('00000000-0000-0000-0000-0000000f5001', '00000000-0000-0000-0000-0000000f5002');

SELECT is((SELECT count(*) FROM enqueue_due_outreach()), 0::bigint,
  'After max_reminders the sender stops asking');

SELECT is((SELECT count(*) FROM v_outreach_for_staff
            WHERE dog_name = 'Luna' AND why LIKE 'reminders used up%'), 2::bigint,
  '...and a person is told to call');

-- --- 7. A failed send --------------------------------------------------------------------------
SELECT mark_outreach_failed((SELECT id FROM outreach_message
                              WHERE dog_id = '00000000-0000-0000-0000-00000000d001' AND status = 'queued'),
                            'mailbox full');

SELECT results_eq(
  $$ SELECT status::text, reminder_count FROM record_request WHERE id = '00000000-0000-0000-0000-0000000f5005' $$,
  $$ VALUES ('insufficient', 0) $$,
  'A failed send leaves the request exactly as it was');

CREATE TEMP TABLE t_q3 AS SELECT id FROM enqueue_due_outreach() AS id;

SELECT is((SELECT d.name FROM outreach_message m JOIN dog d ON d.id = m.dog_id WHERE m.id IN (SELECT id FROM t_q3)),
  'Jaddi', '...so the next run asks again');

-- --- 8. Consent withdrawn after queueing -----------------------------------------------------
INSERT INTO contact_consent (owner_id, channel, granted, source) VALUES
  ('00000000-0000-0000-0000-00000000a001', 'email', false, 'replied STOP');

SELECT throws_ok(
  format($$ SELECT mark_outreach_sent(%L, 'test-mode', 'test-0002') $$, (SELECT id FROM t_q3)),
  'GR019', NULL,
  'Jason replied STOP after the message was queued: it cannot be marked sent');

SELECT results_eq(
  $$ SELECT count(*), bool_and(c.granted) FILTER (WHERE c.source = 'replied STOP')
       FROM contact_consent c WHERE c.owner_id = '00000000-0000-0000-0000-00000000a001' AND c.channel = 'email' $$,
  $$ VALUES (2::bigint, false) $$,
  'Both answers are kept: the yes that covered the earlier email, and the no that stops the next');

-- --- 9. Texts ---------------------------------------------------------------------------------------
INSERT INTO contact_consent (owner_id, channel, granted, source, recorded_by) VALUES
  ('00000000-0000-0000-0000-00000000a002', 'sms', true, 'said yes to texts at the counter',
   '00000000-0000-0000-0000-00000000b002');

CREATE TEMP TABLE t_q4 AS SELECT id FROM enqueue_due_outreach() AS id;

SELECT ok((SELECT m.channel = 'sms' AND m.subject IS NULL AND m.recipient_address = '410-555-0101'
              AND m.body LIKE 'Paws & Polish Grooming:%' AND m.body LIKE '%Reply STOP to opt out.'
              AND length(m.body) <= 320
             FROM outreach_message m WHERE m.id IN (SELECT id FROM t_q4)),
  'Dana agreed to texts: one short, signed text about Biscuit, with how to stop them');

-- --- The wording and the settings it reads ------------------------------------------------------------
SELECT ok((compose_outreach('email', 'Sam', 'Rex', ARRAY['Rabies'], false, false)).body
           LIKE '%We don''t have a current certificate on file for Rex for:%',
  'With no copy ever sent, the message says so instead of thanking them for one');

SELECT throws_ok(
  $$ SELECT shop_policy_text('shop_motto') $$,
  'GR013', NULL,
  'A missing text setting fails loudly, never as an unsigned message');

SELECT * FROM finish();
ROLLBACK;
