-- Invariant 3.6 — no email reminder to an owner who has opted out.
-- The cap on reminder_count is a plain CHECK; the opt-out reads another table
-- and therefore needs a trigger.

BEGIN;
SET search_path = groom, public;
SELECT plan(3);

SELECT throws_ok(
  $$ INSERT INTO record_request
       (dog_id, owner_id, vaccine_type_id, channel, status,
        recipient_address, unsubscribe_token)
     VALUES ('00000000-0000-0000-0000-00000000d003',
             '00000000-0000-0000-0000-00000000a002',
             (SELECT id FROM vaccine_type WHERE code = 'rabies'),
             'email', 'sent', 'dana@example.test', 'tok-test-1') $$,
  'GR005',
  NULL,
  'An email reminder to an opted-out owner is refused'
);

SELECT lives_ok(
  $$ INSERT INTO record_request
       (dog_id, owner_id, vaccine_type_id, channel, status)
     VALUES ('00000000-0000-0000-0000-00000000d003',
             '00000000-0000-0000-0000-00000000a002',
             (SELECT id FROM vaccine_type WHERE code = 'rabies'),
             'verbal_at_counter', 'sent') $$,
  'Asking her at the counter is still allowed'
);

-- Opting out is about the channel, not the dog.
SELECT lives_ok(
  $$ INSERT INTO record_request
       (dog_id, owner_id, vaccine_type_id, channel, status,
        recipient_address, unsubscribe_token)
     VALUES ('00000000-0000-0000-0000-00000000d001',
             '00000000-0000-0000-0000-00000000a001',
             (SELECT id FROM vaccine_type WHERE code = 'rabies'),
             'email', 'sent', 'jason@example.test', 'tok-test-2') $$,
  'An owner who has not opted out still receives email'
);

SELECT * FROM finish();
ROLLBACK;
