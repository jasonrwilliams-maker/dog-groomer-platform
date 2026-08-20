-- The Jaddi case. Her vet invoice names a rabies vaccination and the date it
-- was given, but carries no expiry date anywhere on the page.
--
-- Correct behaviour: the document and its extraction are retained as evidence,
-- no vaccination record is created, and she stays non-compliant. The system
-- does not invent a date the certificate never stated.

BEGIN;
SET search_path = groom, public;
SELECT plan(4);

INSERT INTO document (id, owner_id, object_key, mime_type, byte_size, sha256,
                      doc_class, source, page_count) VALUES
  ('00000000-0000-0000-0000-0000000f0001',
   '00000000-0000-0000-0000-00000000a001',
   'docs/jaddi_invoice.pdf', 'application/pdf', 53268,
   repeat('a', 64), 'vet_invoice', 'upload', 1);

INSERT INTO document_dog (document_id, dog_id) VALUES
  ('00000000-0000-0000-0000-0000000f0001',
   '00000000-0000-0000-0000-00000000d001');

INSERT INTO extraction (id, document_id, model_name, model_version,
                        prompt_version, raw_response, status) VALUES
  ('00000000-0000-0000-0000-0000000f0002',
   '00000000-0000-0000-0000-0000000f0001',
   'test-model', 'v0', 'p0',
   '{"rabies_administered_on":"2025-03-08","expires_on":null}'::jsonb,
   'accepted');

INSERT INTO extraction_field (extraction_id, field_name, extracted_value,
                              confidence, correction_action) VALUES
  ('00000000-0000-0000-0000-0000000f0002', 'rabies_administered_on',
   '2025-03-08', 0.910, 'confirmed'),
  ('00000000-0000-0000-0000-0000000f0002', 'expires_on', NULL, 0.000, 'confirmed');

SELECT is(
  (SELECT count(*) FROM document
    WHERE id = '00000000-0000-0000-0000-0000000f0001'),
  1::bigint,
  'The document is retained as evidence'
);

SELECT is(
  (SELECT count(*) FROM extraction_field
    WHERE extraction_id = '00000000-0000-0000-0000-0000000f0002'),
  2::bigint,
  'The extraction is retained, including the field that came back empty'
);

SELECT is(
  (SELECT count(*) FROM vaccination_record
    WHERE dog_id = '00000000-0000-0000-0000-00000000d001'),
  0::bigint,
  'No vaccination record is created without an expiry date'
);

SELECT is(
  (SELECT state::text FROM v_dog_compliance_status
    WHERE dog_id = '00000000-0000-0000-0000-00000000d001'),
  'no_record',
  'Jaddi remains non-compliant, which is the honest answer'
);

SELECT * FROM finish();
ROLLBACK;
