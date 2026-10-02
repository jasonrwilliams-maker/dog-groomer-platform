-- =============================================================================
-- 19. Owner outreach
--
-- Layer 3 decides when the shop needs something from an owner: a request,
-- marked 'insufficient', for each tracked vaccine a page could not evidence.
-- This section decides whether the shop may ask by itself, and then asks.
--
-- Three rules, in the database for the same reason as every other rule here:
-- nothing downstream would catch a message that should not have gone out.
--
--   1. Nothing automated without consent. Consent is opt-in, per channel,
--      and kept as a history (who said yes, when, how) — the record a
--      complaint would ask for. The latest entry wins. No entry is a no.
--      Texts legally need prior consent; email is held to the same bar.
--      email_opted_out (GR005) still blocks email outright, consent or not.
--   2. One message per owner per dog, not one per vaccine. "Please send
--      Biscuit's Bordetella and DHPP" is one ask.
--   3. Reminders are spaced and capped. A request is asked about again only
--      after reminder_interval_days, and never more than its max_reminders.
--      After that it is a job for a person, and v_outreach_for_staff says so.
--
-- What is NOT here: delivery. outreach_message is an outbox. A sender
-- (extraction/review/outreach.py) takes queued messages, hands them to a
-- provider, and reports back through mark_outreach_sent() or
-- mark_outreach_failed(). In test mode the provider delivers nothing; the
-- outbox is what a reviewer reads. A real email or text provider plugs in
-- there without changing a rule here.
--
--   GR019  an automated message to an owner who has not consented to that
--          channel, or whose address for it is missing, or who opted out of
--          email
-- =============================================================================

SET search_path = groom, public;

INSERT INTO policy_enforcement (error_code, level, relaxable, description) VALUES
  ('GR019', 'block', false, 'Automated message without consent on that channel');

-- -----------------------------------------------------------------------------
-- Settings the messages need
-- -----------------------------------------------------------------------------

INSERT INTO shop_policy (key, value_type, int_value, description) VALUES
  ('reminder_interval_days', 'integer', 7,
   'Days between automated messages about the same request. The cap on how many is record_request.max_reminders.');
INSERT INTO shop_policy (key, value_type, text_value, description) VALUES
  ('shop_name', 'text', 'Paws & Polish Grooming',
   'How the shop signs its messages to owners.'),
  ('shop_records_email', 'text', 'records@pawsandpolish.example',
   'Where an owner or their vet can send a certificate. Named in every automated message.');

-- Same contract as shop_policy_int: a missing key fails loudly (GR013), never
-- as NULL. A NULL here would print "Thank you, " and sign nobody's name.
CREATE FUNCTION shop_policy_text(p_key text) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_value text;
BEGIN
    SELECT text_value INTO v_value
    FROM shop_policy WHERE key = p_key AND value_type = 'text';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'shop_policy has no text value for key %', p_key
            USING ERRCODE = 'GR013',
                  HINT = 'The key is missing or holds a different type. Restore the row; policy reads refuse to guess.';
    END IF;
    RETURN v_value;
END $$;

CREATE FUNCTION reminder_interval_days() RETURNS integer
  LANGUAGE sql STABLE AS $$ SELECT shop_policy_int('reminder_interval_days') $$;

-- -----------------------------------------------------------------------------
-- Consent
-- -----------------------------------------------------------------------------

CREATE TABLE contact_consent (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id     uuid NOT NULL REFERENCES owner(id) ON DELETE RESTRICT,
    channel      request_channel NOT NULL CHECK (channel IN ('email', 'sms')),
    granted      boolean NOT NULL,
    -- How the shop knows: 'ticked the box on the intake form', 'replied STOP'.
    -- Required, because "they said it was fine" is not evidence.
    source       text NOT NULL CHECK (btrim(source) <> ''),
    -- NULL when the owner did it themselves (a STOP reply, an unsubscribe link).
    recorded_by  uuid REFERENCES groomer(id) ON DELETE RESTRICT,
    recorded_at  timestamptz NOT NULL DEFAULT now(),
    -- Order of entry. now() is the transaction's start, so two answers given
    -- in one transaction share a timestamp; without this the tie would fall
    -- to a random id, and a STOP could lose to the yes before it.
    seq          bigint GENERATED ALWAYS AS IDENTITY UNIQUE
);
CREATE INDEX contact_consent_latest_idx ON contact_consent (owner_id, channel, recorded_at DESC);

COMMENT ON TABLE contact_consent IS
  'A history, not a flag. Each change of mind is a new row; the latest per '
  'owner and channel is the current answer, and the earlier ones are the '
  'evidence of what was true when an older message went out.';

-- Append-only, like audit_log: rewriting a consent row would rewrite the
-- grounds on which a message was sent.
CREATE FUNCTION reject_consent_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'contact_consent is a history: record a new answer instead of changing an old one'
        USING HINT = 'To withdraw consent, record a new entry with granted = false.';
END $$;

CREATE TRIGGER contact_consent_immutable
    BEFORE UPDATE OR DELETE ON contact_consent
    FOR EACH STATEMENT EXECUTE FUNCTION reject_consent_mutation();

CREATE VIEW v_owner_consent AS
SELECT DISTINCT ON (c.owner_id, c.channel)
       c.owner_id, c.channel, c.granted, c.source, c.recorded_by, c.recorded_at
  FROM contact_consent c
 ORDER BY c.owner_id, c.channel, c.recorded_at DESC, c.seq DESC;

-- The one question every automated message asks first.
CREATE FUNCTION may_message(p_owner_id uuid, p_channel request_channel) RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT COALESCE((
        SELECT c.granted
               AND CASE p_channel WHEN 'email' THEN o.email IS NOT NULL AND NOT o.email_opted_out
                                  WHEN 'sms'   THEN o.phone IS NOT NULL
                                  ELSE false END
          FROM owner o
          JOIN v_owner_consent c ON c.owner_id = o.id AND c.channel = p_channel
         WHERE o.id = p_owner_id), false)
$$;

-- Email first, then text. NULL: the shop may not message this owner by itself.
CREATE FUNCTION automated_channel(p_owner_id uuid) RETURNS request_channel
LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN may_message(p_owner_id, 'email') THEN 'email'::request_channel
                WHEN may_message(p_owner_id, 'sms')   THEN 'sms'::request_channel END
$$;

-- -----------------------------------------------------------------------------
-- The outbox
-- -----------------------------------------------------------------------------

CREATE TYPE outreach_status AS ENUM ('queued', 'sent', 'failed', 'cancelled');

CREATE TABLE outreach_message (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id             uuid NOT NULL REFERENCES owner(id) ON DELETE RESTRICT,
    dog_id               uuid NOT NULL REFERENCES dog(id) ON DELETE RESTRICT,
    channel              request_channel NOT NULL CHECK (channel IN ('email', 'sms')),
    recipient_address    text NOT NULL,
    subject              text,
    body                 text NOT NULL,
    is_reminder          boolean NOT NULL,
    status               outreach_status NOT NULL DEFAULT 'queued',
    queued_at            timestamptz NOT NULL DEFAULT now(),
    sent_at              timestamptz,
    provider             text,
    provider_message_id  text,
    error                text,
    CONSTRAINT subject_is_for_email CHECK ((channel = 'email') = (subject IS NOT NULL)),
    CONSTRAINT sent_is_recorded CHECK (
        (status = 'sent') = (sent_at IS NOT NULL AND provider IS NOT NULL)),
    CONSTRAINT failure_says_why CHECK ((status IN ('failed', 'cancelled')) = (error IS NOT NULL))
);
CREATE INDEX outreach_message_queued_idx ON outreach_message (queued_at) WHERE status = 'queued';
CREATE INDEX outreach_message_owner_idx  ON outreach_message (owner_id, queued_at DESC);

-- Which requests a message asks about.
CREATE TABLE outreach_message_request (
    message_id         uuid NOT NULL REFERENCES outreach_message(id) ON DELETE RESTRICT,
    record_request_id  uuid NOT NULL REFERENCES record_request(id) ON DELETE RESTRICT,
    PRIMARY KEY (message_id, record_request_id)
);
CREATE INDEX outreach_message_request_req_idx ON outreach_message_request (record_request_id);

-- GR019, on the way in and on the way out. Consent is checked when a message
-- is queued and again when it is marked sent: an owner who withdraws between
-- the two must not be sent the message they just declined.
CREATE FUNCTION enforce_outreach_consent() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status IN ('queued', 'sent') AND NOT may_message(NEW.owner_id, NEW.channel) THEN
        RAISE EXCEPTION 'No consent to message owner % by %', NEW.owner_id, NEW.channel
            USING ERRCODE = 'GR019',
                  HINT = 'Ask the owner whether the shop may email or text them, and record their answer. Until then, contact them in person.';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER outreach_message_consent_guard
    BEFORE INSERT OR UPDATE OF status ON outreach_message
    FOR EACH ROW EXECUTE FUNCTION enforce_outreach_consent();

-- -----------------------------------------------------------------------------
-- What is due
--
-- A request is due when the shop is waiting on the owner and has not asked
-- recently: never asked ('queued'), just told the last copy was not enough
-- ('insufficient' — asked again at once, whatever the schedule said), or asked
-- and the reminder date has come ('sent'). Never past its cap, never twice at
-- once (a message already queued for it), never for a dog no longer active.
-- -----------------------------------------------------------------------------

CREATE VIEW v_outreach_due AS
SELECT rr.id AS record_request_id, rr.dog_id, rr.owner_id, rr.vaccine_type_id,
       vt.name AS vaccine, rr.status, rr.reminder_count, rr.max_reminders,
       automated_channel(rr.owner_id) AS channel
  FROM record_request rr
  JOIN dog d           ON d.id = rr.dog_id AND d.is_active
  JOIN vaccine_type vt ON vt.id = rr.vaccine_type_id
 WHERE (rr.status IN ('queued', 'insufficient')
        OR (rr.status = 'sent' AND rr.next_reminder_on <= CURRENT_DATE))
   AND rr.reminder_count < rr.max_reminders
   AND NOT EXISTS (SELECT 1 FROM outreach_message_request mr
                     JOIN outreach_message m ON m.id = mr.message_id
                    WHERE mr.record_request_id = rr.id AND m.status = 'queued');

-- The ones the shop may not automate, and why — a list for a person.
CREATE VIEW v_outreach_for_staff AS
SELECT rr.id AS record_request_id, d.name AS dog_name, o.first_name || ' ' || o.last_name AS owner_name,
       o.phone, o.email, vt.name AS vaccine, rr.status, rr.reminder_count, rr.max_reminders,
       CASE WHEN rr.reminder_count >= rr.max_reminders THEN 'reminders used up — call or ask at the counter'
            ELSE 'no consent to email or text — ask at the counter, and record their answer'
       END AS why
  FROM record_request rr
  JOIN dog d           ON d.id = rr.dog_id AND d.is_active
  JOIN owner o         ON o.id = rr.owner_id
  JOIN vaccine_type vt ON vt.id = rr.vaccine_type_id
 WHERE rr.status IN ('queued', 'insufficient', 'sent')
   AND (rr.reminder_count >= rr.max_reminders OR automated_channel(rr.owner_id) IS NULL);

-- -----------------------------------------------------------------------------
-- Writing the message
--
-- Plain words, one ask, the vaccines by name, how to reply. Wording lives here
-- rather than in the sender so a test can read exactly what an owner reads.
-- -----------------------------------------------------------------------------

CREATE FUNCTION compose_outreach(p_channel request_channel, p_owner_first text, p_dog text,
                                 p_vaccines text[], p_had_a_copy boolean, p_reminder boolean,
                                 OUT subject text, OUT body text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_shop  text := shop_policy_text('shop_name');
    v_reply text := shop_policy_text('shop_records_email');
    v_list  text := array_to_string(p_vaccines, ', ');
    v_why   text;
BEGIN
    v_why := CASE WHEN p_had_a_copy
                  THEN format('Thanks for sending %s''s vaccination records. We couldn''t read everything we need for:', p_dog)
                  ELSE format('We don''t have a current certificate on file for %s for:', p_dog) END;
    IF p_channel = 'email' THEN
        subject := format('%s%s''s vaccination records', CASE WHEN p_reminder THEN 'Reminder: ' ELSE '' END, p_dog);
        body := format(E'Hi %s,\n\n%s%s\n\n%s\n\n'
                       || 'Could you reply with a clear photo or PDF of the certificate, or ask your vet to email it '
                       || E'to %s? A photo taken flat, in good light, works best.\n\n'
                       || E'Thank you,\n%s\n\n'
                       || 'Reply STOP and we won''t email you about this again.',
                       p_owner_first,
                       CASE WHEN p_reminder THEN E'A quick reminder.\n\n' ELSE '' END,
                       v_why,
                       '  - ' || array_to_string(p_vaccines, E'\n  - '),
                       v_reply, v_shop);
    ELSE
        subject := NULL;
        body := format('%s: %swe need a clear copy of %s''s %s %s. Reply with a photo, or have your vet '
                       'email %s. Reply STOP to opt out.',
                       v_shop, CASE WHEN p_reminder THEN 'reminder - ' ELSE '' END, p_dog, v_list,
                       CASE WHEN cardinality(p_vaccines) > 1 THEN 'certificates' ELSE 'certificate' END, v_reply);
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- Queueing: one message per owner and dog, on the channel they allow
-- -----------------------------------------------------------------------------

CREATE FUNCTION enqueue_due_outreach() RETURNS SETOF uuid
LANGUAGE plpgsql AS $$
DECLARE
    g      record;
    v_msg  outreach_message;
    v_text record;
BEGIN
    -- Two due requests for the same dog and vaccine — one a staff member
    -- opened, one a confirmation marked insufficient — are one ask. Keep the
    -- insufficient one (it knows a copy was tried) and close the other, or
    -- sending would leave two open requests for one shot.
    UPDATE record_request rr SET status = 'abandoned', next_reminder_on = NULL
     WHERE rr.id IN (
           SELECT d.record_request_id FROM v_outreach_due d WHERE d.channel IS NOT NULL
           EXCEPT
           (SELECT DISTINCT ON (d.dog_id, d.vaccine_type_id) d.record_request_id
              FROM v_outreach_due d WHERE d.channel IS NOT NULL
             ORDER BY d.dog_id, d.vaccine_type_id, (d.status = 'insufficient') DESC, d.record_request_id));

    FOR g IN
        SELECT due.owner_id, due.dog_id, due.channel,
               array_agg(due.record_request_id ORDER BY due.vaccine) AS request_ids,
               array_agg(due.vaccine ORDER BY due.vaccine)            AS vaccines,
               bool_or(due.status = 'insufficient')                    AS had_a_copy,
               bool_and(due.reminder_count > 0)                        AS reminder
          FROM v_outreach_due due
         WHERE due.channel IS NOT NULL
         GROUP BY due.owner_id, due.dog_id, due.channel
    LOOP
        SELECT * INTO v_text
          FROM compose_outreach(g.channel,
                                (SELECT o.first_name FROM owner o WHERE o.id = g.owner_id),
                                (SELECT d.name FROM dog d WHERE d.id = g.dog_id),
                                g.vaccines, g.had_a_copy, g.reminder);

        INSERT INTO outreach_message (owner_id, dog_id, channel, recipient_address, subject, body, is_reminder)
        SELECT g.owner_id, g.dog_id, g.channel,
               CASE g.channel WHEN 'email' THEN o.email ELSE o.phone END,
               v_text.subject, v_text.body, g.reminder
          FROM owner o WHERE o.id = g.owner_id
        RETURNING * INTO v_msg;

        INSERT INTO outreach_message_request (message_id, record_request_id)
        SELECT v_msg.id, unnest(g.request_ids);

        RETURN NEXT v_msg.id;
    END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- What the sender reports back
-- -----------------------------------------------------------------------------

CREATE FUNCTION mark_outreach_sent(p_message_id uuid, p_provider text, p_provider_message_id text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    m outreach_message;
BEGIN
    UPDATE outreach_message
       SET status = 'sent', sent_at = now(), provider = p_provider, provider_message_id = p_provider_message_id
     WHERE id = p_message_id AND status = 'queued'
    RETURNING * INTO m;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Message % is not queued', p_message_id;
    END IF;

    -- Every request the message asked about is now waiting on the owner. The
    -- request takes the channel actually used; the opt-out guard (GR005) on
    -- record_request checks it once more.
    UPDATE record_request rr
       SET status            = 'sent',
           channel           = m.channel,
           recipient_address = m.recipient_address,
           unsubscribe_token = CASE WHEN m.channel = 'email'
                                    THEN COALESCE(rr.unsubscribe_token, gen_random_uuid()::text)
                                    ELSE rr.unsubscribe_token END,
           reminder_count    = rr.reminder_count + 1,
           next_reminder_on  = CASE WHEN rr.reminder_count + 1 < rr.max_reminders
                                    THEN CURRENT_DATE + reminder_interval_days() END
      FROM outreach_message_request mr
     WHERE mr.message_id = m.id AND mr.record_request_id = rr.id;

    INSERT INTO record_request_event (record_request_id, event_type, provider_message_id, provider_payload)
    SELECT mr.record_request_id, 'sent', p_provider_message_id,
           jsonb_build_object('outreach_message_id', m.id, 'provider', p_provider, 'channel', m.channel)
      FROM outreach_message_request mr WHERE mr.message_id = m.id;

    INSERT INTO audit_log (actor_label, action, entity_type, entity_id, changed_fields)
    VALUES ('outreach sender', 'send_request', 'outreach_message', m.id,
            jsonb_build_object('channel', m.channel, 'provider', p_provider, 'dog_id', m.dog_id,
                               'reminder', m.is_reminder));
END $$;

-- A failure leaves the requests exactly as they were, so the next run asks again.
CREATE FUNCTION mark_outreach_failed(p_message_id uuid, p_error text) RETURNS void
LANGUAGE sql AS $$
    UPDATE outreach_message SET status = 'failed', error = p_error
     WHERE id = p_message_id AND status = 'queued'
$$;

-- Consent withdrawn, or the request answered, after queueing.
CREATE FUNCTION cancel_outreach(p_message_id uuid, p_reason text) RETURNS void
LANGUAGE sql AS $$
    UPDATE outreach_message SET status = 'cancelled', error = p_reason
     WHERE id = p_message_id AND status = 'queued'
$$;

ALTER FUNCTION shop_policy_text(text)                   SET search_path = groom, public;
ALTER FUNCTION reminder_interval_days()                 SET search_path = groom, public;
ALTER FUNCTION reject_consent_mutation()                SET search_path = groom, public;
ALTER FUNCTION may_message(uuid, request_channel)       SET search_path = groom, public;
ALTER FUNCTION automated_channel(uuid)                  SET search_path = groom, public;
ALTER FUNCTION enforce_outreach_consent()               SET search_path = groom, public;
ALTER FUNCTION compose_outreach(request_channel, text, text, text[], boolean, boolean)
                                                        SET search_path = groom, public;
ALTER FUNCTION enqueue_due_outreach()                   SET search_path = groom, public;
ALTER FUNCTION mark_outreach_sent(uuid, text, text)     SET search_path = groom, public;
ALTER FUNCTION mark_outreach_failed(uuid, text)         SET search_path = groom, public;
ALTER FUNCTION cancel_outreach(uuid, text)              SET search_path = groom, public;
