-- =============================================================================
-- 18. Confirmation — Layer 3
--
-- The step where a reviewed page becomes the dog's paperwork. Layers 1 and 2
-- only ever describe a document: what it said, and what the vocabulary made of
-- it. This is the first point at which the system acts on it, so it is the
-- point at which every earlier rule has to hold at once.
--
-- One function, confirm_extraction(extraction, dog, groomer). It refuses to
-- run on an unfinished review, then decides every printed line's fate and
-- writes that decision down:
--
--   record_created          a tracked vaccine, both dates on the page, every
--                           field the record carries reviewed. A verified
--                           vaccination_record, signed by the reviewer.
--   already_on_file         the dog already has this shot with these dates —
--                           a re-upload, a re-run, or the same shot printed
--                           twice on one page. Nothing new is written.
--   conflicts_with_record   the dog already has this shot given within a few
--                           days of this one (shop_policy
--                           'duplicate_shot_window_days'), with any date that
--                           differs. Two documents disagree, and choosing
--                           between them is a human's job. The existing record
--                           is left alone.
--   missing_date            a tracked vaccine the page names without a date it
--                           needs, or with one the reviewer marked unreadable.
--                           The Jaddi case: evidence, no record. If the
--                           dog has no current record for that vaccine, the
--                           owner is asked for a proper certificate.
--   not_tracked             not a vaccine, or one this shop does not track.
--   no_term                 the reviewer struck the line's name out.
--
-- The decisions are rows, not log lines: line_item_outcome says which printed
-- line produced which record, which is the question an inspector asks.
--
-- Refusals, each with its own code. All pinned to 'block': relaxing any of
-- them writes a vaccination record nobody vouched for.
--
--   GR015  the extraction is not awaiting review (already confirmed, rejected,
--          or never loaded)
--   GR016  the review is unfinished: a tracked vaccine line with a field nobody
--          has checked, or a term nobody has ruled on
--   GR017  the dog is not one this document is filed under
--   GR018  a reviewed date is not usable: not a real calendar date, a shot in
--          the future, or an expiry that is not after the shot
-- =============================================================================

SET search_path = groom, public;

INSERT INTO policy_enforcement (error_code, level, relaxable, description) VALUES
  ('GR015', 'block', false, 'Confirmation of an extraction that is not awaiting review'),
  ('GR016', 'block', false, 'Confirmation before every tracked line and unfamiliar term is reviewed'),
  ('GR017', 'block', false, 'Confirmation for a dog the document is not filed under'),
  ('GR018', 'block', false, 'Confirmation with a date that cannot go on a vaccination record');

-- -----------------------------------------------------------------------------
-- How close two records of one shot have to be to be the same shot
--
-- Matching on the exact date misses a misread one. The held-out photo gives
-- DHPP as given Oct 19; the screenshot of the same page says Oct 15. Both
-- confirmed, that is two verified DHPP records for one shot, one of them wrong.
-- Within this many days of a record already on file, a new reading is a
-- conflict for a human, not a second record.
--
-- Seven, because the shortest real interval between two doses of the same
-- vaccine is a puppy series at two to four weeks. A wider window would start
-- calling genuine boosters conflicts; zero restores exact matching.
-- -----------------------------------------------------------------------------

INSERT INTO shop_policy (key, value_type, int_value, description) VALUES
  ('duplicate_shot_window_days', 'integer', 7,
   'A newly confirmed shot given within this many days of one already on file for the same dog and vaccine is flagged as a conflict instead of recorded. 0 matches exact dates only.');

CREATE FUNCTION duplicate_shot_window_days() RETURNS integer
  LANGUAGE sql STABLE AS $$ SELECT shop_policy_int('duplicate_shot_window_days') $$;

-- -----------------------------------------------------------------------------
-- What was decided, per printed line
-- -----------------------------------------------------------------------------

CREATE TYPE line_outcome AS ENUM (
    'record_created', 'already_on_file', 'conflicts_with_record',
    'missing_date', 'not_tracked', 'no_term'
);

-- One row per confirmed extraction: whose page it was, and who said so.
-- RESTRICT throughout. Once a page has been confirmed, the extraction behind it
-- is evidence for a record, and deleting it would leave a record whose origin
-- nobody can show.
CREATE TABLE extraction_confirmation (
    extraction_id  uuid PRIMARY KEY REFERENCES extraction(id) ON DELETE RESTRICT,
    dog_id         uuid NOT NULL REFERENCES dog(id) ON DELETE RESTRICT,
    confirmed_by   uuid NOT NULL REFERENCES groomer(id) ON DELETE RESTRICT,
    confirmed_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE line_item_outcome (
    line_item_id           uuid PRIMARY KEY REFERENCES extraction_line_item(id) ON DELETE RESTRICT,
    extraction_id          uuid NOT NULL REFERENCES extraction_confirmation(extraction_id) ON DELETE RESTRICT,
    outcome                line_outcome NOT NULL,
    vaccine_type_id        uuid REFERENCES vaccine_type(id) ON DELETE RESTRICT,
    vaccination_record_id  uuid REFERENCES vaccination_record(id) ON DELETE RESTRICT,
    record_request_id      uuid REFERENCES record_request(id) ON DELETE RESTRICT,
    -- A record outcome points at the record it made or matched; nothing else
    -- does. Only a missing date can ask the owner for anything.
    CONSTRAINT record_outcome_has_record CHECK (
        (outcome IN ('record_created', 'already_on_file', 'conflicts_with_record'))
        = (vaccination_record_id IS NOT NULL)),
    CONSTRAINT only_missing_date_requests CHECK (
        record_request_id IS NULL OR outcome = 'missing_date'),
    CONSTRAINT vaccine_outcome_has_vaccine CHECK (
        outcome IN ('not_tracked', 'no_term') OR vaccine_type_id IS NOT NULL)
);
CREATE INDEX line_item_outcome_extraction_idx ON line_item_outcome (extraction_id);
CREATE INDEX line_item_outcome_record_idx
  ON line_item_outcome (vaccination_record_id) WHERE vaccination_record_id IS NOT NULL;

COMMENT ON TABLE line_item_outcome IS
  'Which printed line produced which record, and why the others produced none. '
  'already_on_file and conflicts_with_record point at the record that was '
  'already there, so a duplicate upload is traceable to what it duplicated.';

-- -----------------------------------------------------------------------------
-- A date as the record will hold it
--
-- Layer 1 values are text by design. This is the one place they become dates,
-- and it accepts exactly one spelling. NULL for anything else, so the caller
-- can refuse with a groomer-readable reason instead of a cast error.
-- -----------------------------------------------------------------------------

CREATE FUNCTION iso_date_or_null(p_value text) RETURNS date
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_value IS NULL OR p_value !~ '^\d{4}-\d{2}-\d{2}$' THEN
        RETURN NULL;
    END IF;
    -- The pattern fixes the spelling; the cast refuses '2027-02-30'.
    RETURN p_value::date;
EXCEPTION WHEN datetime_field_overflow OR invalid_datetime_format THEN
    RETURN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- Confirmation
-- -----------------------------------------------------------------------------

CREATE FUNCTION confirm_extraction(p_extraction_id uuid, p_dog_id uuid, p_confirmed_by uuid)
RETURNS TABLE (n integer, term text, vaccine_code text, outcome line_outcome,
               vaccination_record_id uuid, record_request_id uuid)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_document_id  uuid;
    v_status       extraction_status;
    v_owner_id     uuid;
    v_actor        text;
    v_unmapped     integer;
    v_unreviewed   integer;
    v_bad_date     record;
    li             record;
    v_adm          date;
    v_exp          date;
    v_record_id    uuid;
    v_request_id   uuid;
    v_outcome      line_outcome;
    v_vaccine_id   uuid;
BEGIN
    -- GR015. The row lock makes a second, simultaneous confirmation wait and
    -- then find the status already changed.
    SELECT e.document_id, e.status INTO v_document_id, v_status
      FROM extraction e WHERE e.id = p_extraction_id FOR UPDATE;
    IF NOT FOUND OR v_status <> 'needs_review' THEN
        RAISE EXCEPTION 'Extraction % is not awaiting review (status: %)',
                        p_extraction_id, COALESCE(v_status::text, 'not found')
            USING ERRCODE = 'GR015',
                  HINT = 'This page has already been confirmed or rejected. Open it from the dog''s paperwork instead.';
    END IF;

    -- GR017
    IF NOT EXISTS (SELECT 1 FROM document_dog dd
                    WHERE dd.document_id = v_document_id AND dd.dog_id = p_dog_id) THEN
        RAISE EXCEPTION 'Document % is not filed under dog %', v_document_id, p_dog_id
            USING ERRCODE = 'GR017',
                  HINT = 'Check which dog this page is about, and file the document under that dog first.';
    END IF;

    -- GR016. Every tracked line fully checked — including the ones that will
    -- not become records, because "your certificate is missing a date" goes
    -- to the owner and should rest on a human reading, not the model's. And
    -- every term ruled on: an unmapped term may be a tracked vaccine.
    SELECT count(*) FILTER (WHERE v.disposition = 'unmapped'),
           count(*) FILTER (WHERE v.disposition = 'tracked' AND v.unreviewed_record_fields > 0)
      INTO v_unmapped, v_unreviewed
      FROM v_extraction_line_item v WHERE v.extraction_id = p_extraction_id;
    IF v_unmapped > 0 OR v_unreviewed > 0 THEN
        RAISE EXCEPTION 'Review unfinished: % tracked line(s) with unchecked fields, % unfamiliar term(s)',
                        v_unreviewed, v_unmapped
            USING ERRCODE = 'GR016',
                  HINT = 'Check the vaccine name and dates on every highlighted line, and rule on any term the shop has not seen before.';
    END IF;

    -- GR018. Checked on every candidate before anything is written, so a bad
    -- date on line 7 does not leave lines 1 to 6 half-confirmed.
    SELECT v.n, v.administered_on, v.expires_on INTO v_bad_date
      FROM v_extraction_line_item v
     WHERE v.extraction_id = p_extraction_id AND v.record_candidate
       AND (iso_date_or_null(v.administered_on) IS NULL
         OR iso_date_or_null(v.expires_on)      IS NULL
         OR iso_date_or_null(v.administered_on) > CURRENT_DATE
         OR iso_date_or_null(v.expires_on) <= iso_date_or_null(v.administered_on))
     ORDER BY v.n LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'Line %: given % / expires % cannot go on a vaccination record',
                        v_bad_date.n, v_bad_date.administered_on, v_bad_date.expires_on
            USING ERRCODE = 'GR018',
                  HINT = 'Correct the date to what the page prints, as year-month-day. A shot cannot be given in the future or expire before it was given.';
    END IF;

    SELECT d.owner_id INTO v_owner_id FROM dog d WHERE d.id = p_dog_id;
    SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_confirmed_by;

    INSERT INTO extraction_confirmation (extraction_id, dog_id, confirmed_by)
    VALUES (p_extraction_id, p_dog_id, p_confirmed_by);

    -- Pass 1: the lines that can become records. First, so pass 2 can tell
    -- whether a date missing on one line was supplied by another.
    FOR li IN
        SELECT v.* FROM v_extraction_line_item v
         WHERE v.extraction_id = p_extraction_id AND v.can_create_record
         ORDER BY v.n
    LOOP
        v_adm := iso_date_or_null(li.administered_on);
        v_exp := iso_date_or_null(li.expires_on);
        SELECT vt.id INTO v_vaccine_id FROM vaccine_type vt WHERE vt.code = li.vaccine_code;

        -- The same shot: same vaccine, given within the window. An exact
        -- match first, so a shot printed twice on one page finds the record
        -- the first printing made; then the nearest date.
        SELECT vr.id,
               CASE WHEN vr.administered_on = v_adm AND vr.expires_on = v_exp
                    THEN 'already_on_file'
                    ELSE 'conflicts_with_record' END::line_outcome
          INTO v_record_id, v_outcome
          FROM vaccination_record vr
         WHERE vr.dog_id = p_dog_id
           AND vr.vaccine_type_id = v_vaccine_id
           AND vr.administered_on BETWEEN v_adm - duplicate_shot_window_days()
                                      AND v_adm + duplicate_shot_window_days()
         ORDER BY (vr.administered_on = v_adm AND vr.expires_on = v_exp) DESC,
                  abs(vr.administered_on - v_adm), vr.created_at
         LIMIT 1;

        IF NOT FOUND THEN
            INSERT INTO vaccination_record
                (dog_id, vaccine_type_id, document_id, administered_on, expires_on,
                 vaccine_manufacturer, lot_serial_number, veterinarian_name,
                 veterinarian_license_no, veterinarian_phone,
                 entry_method, verification_status, verified_by, verified_at)
            VALUES (p_dog_id, v_vaccine_id, v_document_id, v_adm, v_exp,
                    li.vaccine_manufacturer, li.lot_serial_number, li.veterinarian_name,
                    li.veterinarian_license_no, li.veterinarian_phone,
                    'extracted', 'verified', p_confirmed_by, now())
            RETURNING id INTO v_record_id;
            v_outcome := 'record_created';

            INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
            VALUES (p_confirmed_by, v_actor, 'create', 'vaccination_record', v_record_id,
                    jsonb_build_object('document_id', v_document_id, 'extraction_id', p_extraction_id,
                                       'line', li.n, 'term', li.term,
                                       'administered_on', v_adm, 'expires_on', v_exp));

            -- A current record answers any outstanding request for it. An old
            -- certificate does not: it proves the shot was given, not that it
            -- still covers the dog.
            IF v_exp >= CURRENT_DATE THEN
                UPDATE record_request rr
                   SET status = 'resolved', resolved_at = now(),
                       resolved_by_document_id = v_document_id, next_reminder_on = NULL
                 WHERE rr.dog_id = p_dog_id AND rr.vaccine_type_id = v_vaccine_id
                   AND rr.status IN ('queued', 'sent', 'responded', 'insufficient');
            END IF;
        END IF;

        INSERT INTO line_item_outcome (line_item_id, extraction_id, outcome, vaccine_type_id, vaccination_record_id)
        VALUES (li.line_item_id, p_extraction_id, v_outcome, v_vaccine_id, v_record_id);
    END LOOP;

    -- Pass 2: everything else.
    FOR li IN
        SELECT v.* FROM v_extraction_line_item v
         WHERE v.extraction_id = p_extraction_id AND NOT COALESCE(v.can_create_record, false)
         ORDER BY v.n
    LOOP
        v_request_id := NULL;
        SELECT vt.id INTO v_vaccine_id FROM vaccine_type vt WHERE vt.code = li.vaccine_code;

        IF li.term IS NULL THEN
            v_outcome := 'no_term';
        ELSIF li.disposition <> 'tracked' THEN
            v_outcome := 'not_tracked';
        ELSE
            v_outcome := 'missing_date';

            -- Ask the owner only if the dog is actually short of a record. The
            -- Doc Side invoice prints a shot twice, once without its expiry; if
            -- the other printing made a current record, there is nothing to ask.
            IF NOT EXISTS (SELECT 1 FROM vaccination_record vr
                            WHERE vr.dog_id = p_dog_id AND vr.vaccine_type_id = v_vaccine_id
                              AND vr.expires_on >= CURRENT_DATE) THEN
                -- An open request is answered — insufficiently. Otherwise reuse
                -- an earlier 'insufficient' one, so a second bad page does not
                -- stack a second request. Otherwise open one.
                UPDATE record_request rr SET status = 'insufficient'
                 WHERE rr.dog_id = p_dog_id AND rr.vaccine_type_id = v_vaccine_id
                   AND rr.status IN ('queued', 'sent', 'responded')
                RETURNING rr.id INTO v_request_id;

                IF v_request_id IS NULL THEN
                    SELECT rr.id INTO v_request_id FROM record_request rr
                     WHERE rr.dog_id = p_dog_id AND rr.vaccine_type_id = v_vaccine_id
                       AND rr.status = 'insufficient'
                     ORDER BY rr.created_at DESC LIMIT 1;
                END IF;

                IF v_request_id IS NULL THEN
                    -- Status 'insufficient', not 'queued': this records what
                    -- the owner handed over, and sending anything is a separate
                    -- decision. The channel is where to reach them: email
                    -- unless they opted out, then text, then the counter.
                    INSERT INTO record_request (dog_id, owner_id, vaccine_type_id, channel,
                                                recipient_address, status, unsubscribe_token, created_by)
                    SELECT p_dog_id, o.id, v_vaccine_id, c.channel,
                           CASE c.channel WHEN 'email' THEN o.email WHEN 'sms' THEN o.phone END,
                           'insufficient',
                           CASE WHEN c.channel = 'email' THEN gen_random_uuid()::text END,
                           p_confirmed_by
                      FROM owner o
                     CROSS JOIN LATERAL (SELECT CASE
                               WHEN o.email IS NOT NULL AND NOT o.email_opted_out THEN 'email'
                               WHEN o.phone IS NOT NULL                           THEN 'sms'
                               ELSE                                                    'verbal_at_counter'
                             END::request_channel AS channel) c
                     WHERE o.id = v_owner_id
                    RETURNING id INTO v_request_id;

                    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
                    VALUES (p_confirmed_by, v_actor, 'create', 'record_request', v_request_id,
                            jsonb_build_object('document_id', v_document_id, 'extraction_id', p_extraction_id,
                                               'line', li.n, 'term', li.term, 'reason', 'missing_date'));
                END IF;
            END IF;
        END IF;

        INSERT INTO line_item_outcome (line_item_id, extraction_id, outcome, vaccine_type_id, record_request_id)
        VALUES (li.line_item_id, p_extraction_id, v_outcome,
                CASE WHEN v_outcome = 'missing_date' THEN v_vaccine_id END, v_request_id);
    END LOOP;

    UPDATE extraction SET status = 'accepted' WHERE id = p_extraction_id;

    INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
    VALUES (p_confirmed_by, v_actor, 'update', 'extraction', p_extraction_id,
            jsonb_build_object('status', jsonb_build_object('old', 'needs_review', 'new', 'accepted'),
                               'dog_id', p_dog_id));

    RETURN QUERY
        SELECT li2.n, v.term, vt.code, o.outcome, o.vaccination_record_id, o.record_request_id
          FROM line_item_outcome o
          JOIN extraction_line_item li2 ON li2.id = o.line_item_id
          JOIN v_extraction_line_item v  ON v.line_item_id = o.line_item_id
          LEFT JOIN vaccine_type vt      ON vt.id = o.vaccine_type_id
         WHERE o.extraction_id = p_extraction_id
         ORDER BY li2.n;
END $$;

COMMENT ON FUNCTION confirm_extraction(uuid, uuid, uuid) IS
  'Layer 3. Refuses an unfinished review (GR015-GR018); otherwise writes a '
  'verified vaccination_record for exactly the lines where can_create_record '
  'is true and the dog has no record of that shot within '
  'duplicate_shot_window_days, records every line''s '
  'outcome, and opens a record_request for a tracked vaccine the page names '
  'without the dates a record needs. All or nothing: one transaction.';

ALTER FUNCTION duplicate_shot_window_days()          SET search_path = groom, public;
ALTER FUNCTION iso_date_or_null(text)                SET search_path = groom, public;
ALTER FUNCTION confirm_extraction(uuid, uuid, uuid)  SET search_path = groom, public;
