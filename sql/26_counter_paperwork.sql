-- =============================================================================
-- 26. Paperwork at the counter: a photo, checked by hand
--
-- A walk-in pulls their dog's records up on their phone, or hands over a
-- printout. The groomer photographs it on the shop tablet (or picks the file
-- if it was emailed in), and the copy is kept with the dog. Then one of two
-- things happens:
--
--   * Check it now. The shop is quiet: the groomer reads the photo and types
--     the dates in beside it. With the photo on file, what they type counts as
--     verified straight away. The dog is groomed, and nobody has to come back
--     to it.
--   * Check it later. The shop is busy, or the paper needs a careful look (a
--     puppy on the edge of the age limit). The photo waits on the manager's
--     list until someone checks it.
--
-- Either way the copy is kept: receive_paperwork() files it against the owner
-- and the dog, as the records tool does with an upload, and lists it as
-- waiting to be checked until someone says they are done with it.
--
-- A record verified this way is marked as checked by hand. It is the shop
-- owner's protection: a busy groomer can misread a date, and the health
-- department does not care who was busy. Every record checked by hand at the
-- counter goes on the manager's list for a second look, beside the photo it
-- was checked against; a manager's own check needs none.
--
-- Typing shots in with no photo is still allowed (record_counter_shot(),
-- section 22). Those stay "awaiting verification": there is nothing on file to
-- have verified them against.
--
--   GR027  a shot checked by hand against a copy that is not on file for
--          this dog
--   GR028  a second look given by someone who is not a manager
-- =============================================================================

SET search_path = groom, public;

INSERT INTO policy_enforcement (error_code, level, relaxable, description) VALUES
  ('GR027', 'block', false, 'A shot checked by hand without a copy of the paperwork on file for the dog'),
  ('GR028', 'block', false, 'A second look at a hand-checked record given by someone who is not a manager');

-- -----------------------------------------------------------------------------
-- The copy, and whether anyone has checked it yet
-- -----------------------------------------------------------------------------

CREATE TABLE counter_paperwork (
    document_id  uuid NOT NULL REFERENCES document(id) ON DELETE CASCADE,
    dog_id       uuid NOT NULL REFERENCES dog(id) ON DELETE RESTRICT,
    received_by  uuid NOT NULL REFERENCES groomer(id) ON DELETE RESTRICT,
    received_at  timestamptz NOT NULL DEFAULT now(),
    checked_by   uuid REFERENCES groomer(id) ON DELETE RESTRICT,
    checked_at   timestamptz,
    PRIMARY KEY (document_id, dog_id),
    CONSTRAINT checked_coherent CHECK ((checked_by IS NULL) = (checked_at IS NULL))
);
CREATE INDEX counter_paperwork_waiting_idx ON counter_paperwork (received_at) WHERE checked_at IS NULL;
COMMENT ON TABLE counter_paperwork IS
  'A copy of a dog''s paperwork photographed or uploaded at the counter. Waiting '
  'to be checked until checked_at is set; the copy itself is the document row.';

-- -----------------------------------------------------------------------------
-- Checked by hand, and the manager's second look
-- -----------------------------------------------------------------------------

ALTER TABLE vaccination_record
    ADD COLUMN checked_by_hand  boolean NOT NULL DEFAULT false,
    ADD COLUMN second_look_by   uuid REFERENCES groomer(id) ON DELETE RESTRICT,
    ADD COLUMN second_look_at   timestamptz,
    ADD CONSTRAINT checked_by_hand_coherent CHECK (
        NOT checked_by_hand
     OR (entry_method = 'manual' AND verification_status <> 'unverified' AND document_id IS NOT NULL)),
    ADD CONSTRAINT second_look_coherent CHECK (
        (second_look_by IS NULL) = (second_look_at IS NULL)
     AND (second_look_by IS NULL OR checked_by_hand));
COMMENT ON COLUMN vaccination_record.checked_by_hand IS
  'Typed in by a person reading a photo of the paperwork, and verified on that '
  'basis, rather than read by the model and confirmed field by field. The photo '
  'is document_id. A manager can give it a second look (second_look_by/at).';

-- -----------------------------------------------------------------------------
-- Receiving the copy
--
-- The file is already saved (the API downsizes a photo and writes it under
-- private/); this records it. The same file twice for the same owner is the
-- same document, as in the records tool's ingestion: it is linked to this dog
-- and listed again, not stored twice.
-- -----------------------------------------------------------------------------

CREATE FUNCTION receive_paperwork(p_dog_id uuid, p_object_key text, p_mime_type text,
                                  p_byte_size bigint, p_sha256 text, p_page_count integer,
                                  p_exif_stripped boolean, p_received_by uuid)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_owner_id uuid;
    v_actor    text;
    v_doc_id   uuid;
BEGIN
    SELECT d.owner_id INTO v_owner_id FROM dog d WHERE d.id = p_dog_id AND d.is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Dog % is not an active client', p_dog_id;
    END IF;
    SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_received_by;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No such groomer: %', p_received_by USING ERRCODE = 'foreign_key_violation';
    END IF;

    SELECT doc.id INTO v_doc_id FROM document doc
     WHERE doc.owner_id = v_owner_id AND doc.sha256 = p_sha256;
    IF NOT FOUND THEN
        INSERT INTO document (owner_id, object_key, mime_type, byte_size, sha256, source,
                              page_count, exif_stripped, uploaded_by)
        VALUES (v_owner_id, p_object_key, p_mime_type, p_byte_size, p_sha256, 'upload',
                p_page_count, p_exif_stripped, p_received_by)
        RETURNING id INTO v_doc_id;
        INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
        VALUES (p_received_by, v_actor, 'create', 'document', v_doc_id,
                jsonb_build_object('source', 'counter', 'dog_id', p_dog_id, 'mime_type', p_mime_type));
    END IF;

    INSERT INTO document_dog (document_id, dog_id) VALUES (v_doc_id, p_dog_id)
    ON CONFLICT DO NOTHING;
    -- Received again: back on the list if it had been checked off.
    INSERT INTO counter_paperwork (document_id, dog_id, received_by)
    VALUES (v_doc_id, p_dog_id, p_received_by)
    ON CONFLICT (document_id, dog_id) DO UPDATE
       SET received_by = EXCLUDED.received_by, received_at = now(),
           checked_by = NULL, checked_at = NULL;
    RETURN v_doc_id;
END $$;

COMMENT ON FUNCTION receive_paperwork(uuid, text, text, bigint, text, integer, boolean, uuid) IS
  'A copy of the paperwork taken at the counter: filed against the owner and the '
  'dog (once per file per owner) and listed as waiting to be checked.';

-- -----------------------------------------------------------------------------
-- A shot checked by hand against the copy
--
-- The same rules as a shot typed in with no copy (no expiry, no record: GR021;
-- a disagreement with a record on file is a manager's: GR022), because it goes
-- through record_counter_shot(). What the copy adds is the verification: the
-- record is verified by whoever checked it, linked to the photo, and marked as
-- checked by hand. A record already verified some other way is left as it is.
-- -----------------------------------------------------------------------------

CREATE FUNCTION record_checked_shot(p_dog_id uuid, p_document_id uuid, p_vaccine_code text,
                                    p_administered_on date, p_expires_on date, p_checked_by uuid)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_id      uuid;
    v_actor   text;
    v_manager boolean;
BEGIN
    -- GR027
    IF p_document_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM document_dog dd WHERE dd.document_id = p_document_id AND dd.dog_id = p_dog_id) THEN
        RAISE EXCEPTION 'No copy of this dog''s paperwork on file to check the shot against'
            USING ERRCODE = 'GR027',
                  HINT = 'Take a photo of the paperwork first. Without one, type the shot in as awaiting verification.';
    END IF;

    v_id := record_counter_shot(p_dog_id, p_vaccine_code, p_administered_on, p_expires_on, p_checked_by);

    SELECT g.display_name, g.role = 'manager' INTO v_actor, v_manager FROM groomer g WHERE g.id = p_checked_by;
    UPDATE vaccination_record
       SET verification_status = 'verified', verified_by = p_checked_by, verified_at = now(),
           document_id = p_document_id, checked_by_hand = true,
           -- A manager checking it is the second look.
           second_look_by = CASE WHEN v_manager THEN p_checked_by END,
           second_look_at = CASE WHEN v_manager THEN now() END
     WHERE id = v_id AND verification_status = 'unverified' AND entry_method = 'manual';
    IF FOUND THEN
        INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
        VALUES (p_checked_by, v_actor, 'update', 'vaccination_record', v_id,
                jsonb_build_object('verification_status', 'verified', 'checked_by_hand', true,
                                   'document_id', p_document_id));
    END IF;
    RETURN v_id;
END $$;

COMMENT ON FUNCTION record_checked_shot(uuid, uuid, text, date, date, uuid) IS
  'A shot typed in while reading a photo of the paperwork: verified, linked to the '
  'photo and marked checked by hand. Needs the photo on file for the dog (GR027).';

-- Done with a copy: off the waiting list.
CREATE FUNCTION finish_paperwork_check(p_document_id uuid, p_dog_id uuid, p_checked_by uuid)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_actor text;
BEGIN
    SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_checked_by;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No such groomer: %', p_checked_by USING ERRCODE = 'foreign_key_violation';
    END IF;
    UPDATE counter_paperwork SET checked_by = p_checked_by, checked_at = now()
     WHERE document_id = p_document_id AND dog_id = p_dog_id AND checked_at IS NULL;
    IF FOUND THEN
        INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
        VALUES (p_checked_by, v_actor, 'update', 'counter_paperwork', p_document_id,
                jsonb_build_object('dog_id', p_dog_id, 'checked', true));
    END IF;
END $$;

-- A manager has looked at the photo and agrees.
CREATE FUNCTION give_second_look(p_record_id uuid, p_manager_id uuid)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_actor text;
BEGIN
    SELECT g.display_name INTO v_actor FROM groomer g WHERE g.id = p_manager_id AND g.role = 'manager';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Only a manager can give a hand-checked record its second look'
            USING ERRCODE = 'GR028',
                  HINT = 'The record stays on the manager''s list until a manager looks at it.';
    END IF;
    UPDATE vaccination_record SET second_look_by = p_manager_id, second_look_at = now()
     WHERE id = p_record_id AND checked_by_hand AND second_look_at IS NULL;
    IF FOUND THEN
        INSERT INTO audit_log (actor_id, actor_label, action, entity_type, entity_id, changed_fields)
        VALUES (p_manager_id, v_actor, 'update', 'vaccination_record', p_record_id,
                jsonb_build_object('second_look', true));
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- The manager's two lists
-- -----------------------------------------------------------------------------

CREATE VIEW v_paperwork_waiting AS
SELECT cp.document_id, cp.dog_id, d.name AS dog, o.first_name || ' ' || o.last_name AS owner,
       doc.mime_type, g.display_name AS received_by, cp.received_at
  FROM counter_paperwork cp
  JOIN document doc ON doc.id = cp.document_id
  JOIN dog d        ON d.id = cp.dog_id
  JOIN owner o      ON o.id = d.owner_id
  JOIN groomer g    ON g.id = cp.received_by
 WHERE cp.checked_at IS NULL AND d.is_active
 ORDER BY cp.received_at;

CREATE VIEW v_hand_checked_open AS
SELECT vr.id, vr.dog_id, d.name AS dog, o.first_name || ' ' || o.last_name AS owner,
       vt.name AS vaccine, vr.administered_on, vr.expires_on, vr.document_id,
       doc.mime_type, g.display_name AS checked_by, vr.verified_at AS checked_at
  FROM vaccination_record vr
  JOIN vaccine_type vt ON vt.id = vr.vaccine_type_id
  JOIN dog d           ON d.id = vr.dog_id
  JOIN owner o         ON o.id = d.owner_id
  JOIN document doc    ON doc.id = vr.document_id
  JOIN groomer g       ON g.id = vr.verified_by
 WHERE vr.checked_by_hand AND vr.second_look_at IS NULL AND d.is_active
 ORDER BY vr.verified_at;
