-- =============================================================================
-- Dog Grooming Platform — Schema DDL
-- Target: PostgreSQL 15+  (UNIQUE ... NULLS NOT DISTINCT is required)
--         PostgreSQL 18+ optional: replace gen_random_uuid() with uuidv7()
--         for better index locality on the append-heavy tables.
--
-- Normative references:
--   resolution_precedence.md  — cut spec + compliance state precedence, invariants
--   style_tier_mapping.md     — seed data shape for style_template_zone_spec
--
-- Design rules this file follows:
--   1. Configuration is live; history is a snapshot. Anything that records what
--      was DONE stores its own resolved values and does not silently change when
--      reference data is edited.
--   2. Derived-in-row      -> GENERATED ALWAYS AS ... STORED
--      Derived-cross-table -> trigger, or a view. Never a lie in a column.
--   3. Every trigger-enforced invariant is numbered to match section 3 of
--      resolution_precedence.md so the doc and the DDL stay in sync.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS groom;
SET search_path = groom, public;

-- -----------------------------------------------------------------------------
-- 0. Enumerated vocabularies
--
-- Rule applied: ENUM when the value is a closed set carrying no attributes.
-- Lookup TABLE when the value has attributes the business reads (service_type,
-- vaccine_type, compliance_state_meta). Mixing the two deliberately.
-- -----------------------------------------------------------------------------

CREATE TYPE dog_sex              AS ENUM ('male', 'female', 'unknown');
CREATE TYPE groomer_role         AS ENUM ('groomer', 'manager');
CREATE TYPE cutting_tool         AS ENUM ('clipper', 'scissors', 'hand_strip');
CREATE TYPE allergy_source       AS ENUM ('owner_reported', 'observed', 'vet_documented');
CREATE TYPE photo_rendition      AS ENUM ('original', 'display', 'thumb');
CREATE TYPE entry_method         AS ENUM ('extracted', 'manual', 'migrated');
CREATE TYPE verification_status  AS ENUM ('unverified', 'verified', 'disputed');
CREATE TYPE extraction_status    AS ENUM ('pending', 'needs_review', 'accepted', 'rejected');

-- 'removed' is the hallucination case: the model produced a value the document
-- does not contain, and the human deleted it. Collapsing that into 'not
-- corrected' would hide false positives from any later error analysis.
CREATE TYPE correction_action   AS ENUM ('unreviewed', 'confirmed', 'edited', 'removed');
CREATE TYPE document_class       AS ENUM ('form51', 'vet_invoice', 'handwritten_note',
                                          'rabies_certificate', 'unknown');
CREATE TYPE document_source      AS ENUM ('upload', 'email_reply', 'scan');
CREATE TYPE request_channel      AS ENUM ('email', 'sms', 'verbal_at_counter');

-- 'insufficient' added: the owner responded with a document that does not
-- contain enough to create a record. See note on expires_on below.
CREATE TYPE request_status       AS ENUM ('queued', 'sent', 'bounced', 'responded',
                                          'insufficient', 'resolved', 'abandoned');

CREATE TYPE request_event_type   AS ENUM ('sent', 'delivered', 'bounced', 'opened',
                                          'replied', 'attachment_received', 'unsubscribed');

-- 'disputed_record' is not in resolution_precedence.md §2. It is added because
-- verification_status allows 'disputed' and the six-state ladder has nowhere to
-- put it — a disputed record would otherwise resolve to 'current'. See notes.
-- 'not_yet_due': the dog is legally too young for this vaccine. Maryland
-- requires rabies by 16 weeks; a 10-week-old puppy is not non-compliant, and
-- chasing its owner is a false alarm. Age-dependent, so it is computed in the
-- view rather than stored.
CREATE TYPE compliance_state     AS ENUM ('no_record', 'not_yet_due', 'requested_pending',
                                          'received_unverified', 'disputed_record',
                                          'current', 'expiring_soon', 'expired');

CREATE TYPE audit_action         AS ENUM ('view', 'create', 'update', 'delete',
                                          'export', 'send_request');
CREATE TYPE retention_action     AS ENUM ('purge', 'archive', 'retain_forever');

-- -----------------------------------------------------------------------------
-- 1. Configuration constants
--
-- The 30-day warning window lives in exactly one place so the view, the
-- dashboard and the tests cannot drift apart.
-- -----------------------------------------------------------------------------

CREATE FUNCTION expiry_warning_days() RETURNS integer
  LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT 30 $$;

CREATE FUNCTION remedial_coat_ordinal() RETURNS integer
  LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT 4 $$;

-- Shop policy, not law and not style identity: the age below which a dog does
-- not get a haircut without an explicit, approved reason.
CREATE FUNCTION min_groom_age_weeks() RETURNS integer
  LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT 16 $$;

-- -----------------------------------------------------------------------------
-- 2. Reference tables (configuration — live, editable, RESTRICT on delete)
-- -----------------------------------------------------------------------------

CREATE TABLE coat_type (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code         text NOT NULL UNIQUE
                 CHECK (code IN ('curly','wiry','smooth','double','silky')),
    name         text NOT NULL,
    description  text
);

CREATE TABLE breed (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name                 text NOT NULL UNIQUE,
    default_coat_type_id uuid NOT NULL REFERENCES coat_type(id) ON DELETE RESTRICT,
    is_mixed             boolean NOT NULL DEFAULT false
);
COMMENT ON COLUMN breed.default_coat_type_id IS
  'Seeds dog.coat_type_id at creation. Never read after that — the dog''s own '
  'coat_type_id is what drives recommendations, because the label lies.';

CREATE TABLE body_zone (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    parent_zone_id        uuid REFERENCES body_zone(id) ON DELETE RESTRICT,
    code                  text NOT NULL UNIQUE,
    plain_language_label  text NOT NULL,
    display_order         integer NOT NULL,
    CONSTRAINT body_zone_not_own_parent CHECK (parent_zone_id IS DISTINCT FROM id)
);

CREATE TABLE blade (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    number                integer NOT NULL CHECK (number BETWEEN 1 AND 50),
    is_finish             boolean NOT NULL DEFAULT false,
    length_in             numeric(8,6) NOT NULL CHECK (length_in > 0),
    plain_language_label  text NOT NULL,
    UNIQUE (number, is_finish)
);
COMMENT ON TABLE blade IS
  'Blade NUMBER is inversely related to LENGTH (#30 is shortest, #3 longest). '
  'Never order or compare by number. Always compare length_in.';

CREATE TABLE comb (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    length_in  numeric(8,6) NOT NULL UNIQUE CHECK (length_in > 0),
    label      text NOT NULL
);

CREATE TABLE length_tier (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code        text NOT NULL UNIQUE CHECK (code IN ('short','medium','long')),
    sort_order  integer NOT NULL UNIQUE
);

CREATE TABLE service_type (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code              text NOT NULL UNIQUE,
    name              text NOT NULL,
    carries_cut_spec  boolean NOT NULL DEFAULT false,
    display_order     integer NOT NULL
);

CREATE TABLE allergen (
    id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name      text NOT NULL UNIQUE,
    category  text NOT NULL
              CHECK (category IN ('shampoo','conditioner','topical','fragrance','other'))
);

CREATE TABLE vaccine_type (
    id                            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                          text NOT NULL UNIQUE,
    name                          text NOT NULL,
    -- Law says so (drives Form 51 and the health department).
    regulatory_required           boolean NOT NULL DEFAULT false,
    -- The shop says so. Maryland does not require Bordetella; Riane might.
    -- A vaccine that is neither is recorded but never sets compliance state.
    required_by_policy            boolean NOT NULL DEFAULT false,
    -- Age below which this vaccine is not yet due. NULL means always due.
    min_age_weeks                 integer CHECK (min_age_weeks > 0),
    authority                     text,
    plausible_validity_min_months integer NOT NULL CHECK (plausible_validity_min_months > 0),
    plausible_validity_max_months integer NOT NULL,
    blocks_service_if_expired     boolean NOT NULL DEFAULT false,
    CONSTRAINT vaccine_validity_range_sane
      CHECK (plausible_validity_max_months >= plausible_validity_min_months)
);

-- Attribute carrier for the compliance_state enum. Enum gives the ladder a
-- stable identity the resolution logic can reference without a join; this table
-- gives the dashboard its labels and urgency ranking.
CREATE TABLE compliance_state_meta (
    state                 compliance_state PRIMARY KEY,
    sort_order            integer NOT NULL UNIQUE,
    plain_language_label  text NOT NULL,
    blocks_service        boolean NOT NULL,
    actionable            boolean NOT NULL
);

CREATE TABLE style_template (
    id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                      text NOT NULL UNIQUE,
    name                      text NOT NULL,
    plain_language_description text,
    is_remedial               boolean NOT NULL DEFAULT false,
    supports_tiers            boolean NOT NULL DEFAULT true,
    requires_uniform_length   boolean NOT NULL DEFAULT false,
    min_coat_ordinal_required integer CHECK (min_coat_ordinal_required BETWEEN 1 AND 5),
    -- A remedial template is keyed by coat severity, not by tier, and must
    -- declare the threshold that gates it.
    CONSTRAINT remedial_shape CHECK (
        (is_remedial AND NOT supports_tiers AND min_coat_ordinal_required IS NOT NULL)
     OR (NOT is_remedial AND supports_tiers AND min_coat_ordinal_required IS NULL)
    )
);
-- =============================================================================
-- 3. Parties and subjects
-- =============================================================================

CREATE TABLE owner (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    first_name       text NOT NULL,
    last_name        text NOT NULL,
    phone            text,
    email            text,
    address_line1    text,
    city             text,
    state            char(2),
    postal_code      text,
    email_opted_out  boolean NOT NULL DEFAULT false,
    purge_requested  boolean NOT NULL DEFAULT false,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    last_activity_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT owner_contactable CHECK (phone IS NOT NULL OR email IS NOT NULL)
);
-- Case-insensitive uniqueness without depending on the citext extension.
CREATE UNIQUE INDEX owner_email_lower_key ON owner (lower(email)) WHERE email IS NOT NULL;
CREATE INDEX owner_last_activity_idx ON owner (last_activity_at);
COMMENT ON COLUMN owner.last_activity_at IS
  'Retention anchor for owner/dog/visit data. Touched by application on any '
  'visit, request or document event — deliberately not a trigger, so a purge '
  'sweep cannot be reset by its own housekeeping writes.';

CREATE TABLE groomer (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    display_name  text NOT NULL,
    email         text NOT NULL,
    role          groomer_role NOT NULL DEFAULT 'groomer',
    is_active     boolean NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX groomer_email_lower_key ON groomer (lower(email));

CREATE TABLE dog (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id       uuid NOT NULL REFERENCES owner(id) ON DELETE RESTRICT,
    name           text NOT NULL,
    breed_id       uuid REFERENCES breed(id) ON DELETE RESTRICT,
    coat_type_id   uuid NOT NULL REFERENCES coat_type(id) ON DELETE RESTRICT,
    date_of_birth  date CHECK (date_of_birth <= CURRENT_DATE),
    sex            dog_sex NOT NULL DEFAULT 'unknown',
    is_altered     boolean,
    vet_practice   text,
    vet_phone      text,
    is_active      boolean NOT NULL DEFAULT true,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX dog_owner_idx  ON dog (owner_id);
CREATE INDEX dog_active_idx ON dog (is_active) WHERE is_active;
COMMENT ON COLUMN dog.breed_id IS 'Label only. Nullable — "some kind of terrier" is a real answer.';
COMMENT ON COLUMN dog.coat_type_id IS 'Drives recommendations. Required, because the work depends on it.';

CREATE TABLE dog_photo (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    dog_id         uuid NOT NULL REFERENCES dog(id) ON DELETE RESTRICT,
    -- Groups the three renditions produced from one upload.
    photo_group_id uuid NOT NULL,
    object_key     text NOT NULL UNIQUE,
    rendition      photo_rendition NOT NULL,
    width_px       integer NOT NULL CHECK (width_px > 0),
    height_px      integer NOT NULL CHECK (height_px > 0),
    exif_stripped  boolean NOT NULL DEFAULT false,
    uploaded_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (photo_group_id, rendition)
);
CREATE INDEX dog_photo_dog_idx ON dog_photo (dog_id, uploaded_at DESC);

CREATE TABLE allergy (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    dog_id            uuid NOT NULL REFERENCES dog(id) ON DELETE RESTRICT,
    allergen_id       uuid NOT NULL REFERENCES allergen(id) ON DELETE RESTRICT,
    severity_ordinal  smallint NOT NULL CHECK (severity_ordinal BETWEEN 1 AND 4),
    source            allergy_source NOT NULL,
    note              text,
    recorded_at       timestamptz NOT NULL DEFAULT now(),
    recorded_by       uuid REFERENCES groomer(id) ON DELETE RESTRICT,
    UNIQUE (dog_id, allergen_id)
);

CREATE TABLE visit (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    dog_id        uuid NOT NULL REFERENCES dog(id) ON DELETE RESTRICT,
    performed_by  uuid NOT NULL REFERENCES groomer(id) ON DELETE RESTRICT,
    visit_date    date NOT NULL,
    check_in      time,
    check_out     time,
    overall_note  text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT visit_times_ordered CHECK (check_out IS NULL OR check_in IS NULL
                                          OR check_out >= check_in)
);
CREATE INDEX visit_dog_date_idx ON visit (dog_id, visit_date DESC);
CREATE INDEX visit_groomer_idx  ON visit (performed_by);
CREATE INDEX visit_date_idx     ON visit (visit_date);

CREATE TABLE visit_service (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    visit_id          uuid NOT NULL REFERENCES visit(id) ON DELETE CASCADE,
    service_type_id   uuid NOT NULL REFERENCES service_type(id) ON DELETE RESTRICT,
    completed         boolean NOT NULL DEFAULT true,
    incomplete_reason text,
    note              text,
    recorded_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (visit_id, service_type_id),
    CONSTRAINT incomplete_needs_reason
      CHECK (completed OR incomplete_reason IS NOT NULL)
);
COMMENT ON CONSTRAINT incomplete_needs_reason ON visit_service IS
  '"We did not finish the nails" is only useful with the because.';

CREATE TABLE behavior_note (
    id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    dog_id                      uuid NOT NULL REFERENCES dog(id) ON DELETE RESTRICT,
    visit_id                    uuid REFERENCES visit(id) ON DELETE SET NULL,
    handling_difficulty_ordinal smallint NOT NULL CHECK (handling_difficulty_ordinal BETWEEN 1 AND 5),
    body_zone_id                uuid REFERENCES body_zone(id) ON DELETE RESTRICT,
    trigger_kind                text CHECK (trigger_kind IN
                                  ('dryer','clippers','nail_grinder','restraint','water','other')),
    note                        text,
    observed_at                 timestamptz NOT NULL DEFAULT now(),
    observed_by                 uuid REFERENCES groomer(id) ON DELETE RESTRICT
);
CREATE INDEX behavior_note_dog_idx   ON behavior_note (dog_id, observed_at DESC);
CREATE INDEX behavior_note_visit_idx ON behavior_note (visit_id) WHERE visit_id IS NOT NULL;

CREATE TABLE coat_assessment (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    dog_id            uuid NOT NULL REFERENCES dog(id) ON DELETE RESTRICT,
    visit_id          uuid NOT NULL REFERENCES visit(id) ON DELETE CASCADE,
    condition_ordinal smallint NOT NULL CHECK (condition_ordinal BETWEEN 1 AND 5),
    density_ordinal   smallint NOT NULL CHECK (density_ordinal BETWEEN 1 AND 5),
    note              text,
    assessed_at       timestamptz NOT NULL DEFAULT now(),
    assessed_by       uuid REFERENCES groomer(id) ON DELETE RESTRICT,
    UNIQUE (visit_id)
);
CREATE INDEX coat_assessment_dog_idx ON coat_assessment (dog_id);
COMMENT ON TABLE coat_assessment IS
  'One assessment per visit. This is the row that decides whether a shave-down '
  'is defensible, so it must be unambiguous which one applied.';
-- =============================================================================
-- 4. Styling configuration
-- =============================================================================

-- INVARIANT 3.3 (tool/blade coherence) is genuinely row-local, so it is a real
-- CHECK. It is repeated verbatim on all three tables that carry a tool triple.

CREATE TABLE style_template_zone_spec (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    style_template_id  uuid NOT NULL REFERENCES style_template(id) ON DELETE CASCADE,
    -- Exactly one axis. Tiered templates key on tier; remedial templates key on
    -- the coat severity that triggers them (Shaved L4 -> #7F, L5 -> #10).
    length_tier_id     uuid REFERENCES length_tier(id) ON DELETE RESTRICT,
    min_coat_ordinal   smallint CHECK (min_coat_ordinal BETWEEN 1 AND 5),
    body_zone_id       uuid NOT NULL REFERENCES body_zone(id) ON DELETE RESTRICT,
    tool               cutting_tool NOT NULL,
    blade_id           uuid REFERENCES blade(id) ON DELETE RESTRICT,
    comb_id            uuid REFERENCES comb(id) ON DELETE RESTRICT,
    CONSTRAINT spec_one_axis CHECK (
        (length_tier_id IS NOT NULL AND min_coat_ordinal IS NULL)
     OR (length_tier_id IS NULL     AND min_coat_ordinal IS NOT NULL)
    ),
    CONSTRAINT spec_tool_coherent CHECK (
        (tool = 'clipper'   AND blade_id IS NOT NULL)
     OR (tool IN ('scissors','hand_strip') AND blade_id IS NULL AND comb_id IS NULL)
    ),
    CONSTRAINT spec_comb_needs_blade CHECK (comb_id IS NULL OR blade_id IS NOT NULL)
);
-- NULLS NOT DISTINCT (PG15+) so a remedial template cannot get two rows for the
-- same (template, coat level, zone) just because length_tier_id is NULL on both.
CREATE UNIQUE INDEX style_template_zone_spec_key
  ON style_template_zone_spec (style_template_id, length_tier_id, min_coat_ordinal, body_zone_id)
  NULLS NOT DISTINCT;

-- Clamps are a property of (template, zone), NOT (template, tier, zone) — the
-- whole point is that they survive the tier shift. Storing them as columns on
-- the per-tier spec would let the three tiers disagree about the clamp.
--
-- Expressed in INCHES, not blade numbers, for two reasons: blade numbers run
-- backwards, and a comb has no blade number at all, so a blade-number clamp
-- cannot constrain "#30 under a 1-inch comb" — which is exactly the case that
-- would sneak a fluffy face onto a Poodle at the Long tier.
CREATE TABLE style_template_zone_clamp (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    style_template_id     uuid NOT NULL REFERENCES style_template(id) ON DELETE CASCADE,
    body_zone_id          uuid NOT NULL REFERENCES body_zone(id) ON DELETE RESTRICT,
    min_effective_length_in numeric(8,6) CHECK (min_effective_length_in > 0),
    max_effective_length_in numeric(8,6) CHECK (max_effective_length_in > 0),
    rationale             text NOT NULL,
    UNIQUE (style_template_id, body_zone_id),
    CONSTRAINT clamp_has_a_bound CHECK (
        min_effective_length_in IS NOT NULL OR max_effective_length_in IS NOT NULL),
    CONSTRAINT clamp_bounds_ordered CHECK (
        min_effective_length_in IS NULL OR max_effective_length_in IS NULL
        OR min_effective_length_in <= max_effective_length_in)
);

-- Precedence level 3: the hygiene invariant. One per zone, hence UNIQUE.
CREATE TABLE zone_default (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    body_zone_id  uuid NOT NULL UNIQUE REFERENCES body_zone(id) ON DELETE RESTRICT,
    blade_id      uuid NOT NULL REFERENCES blade(id) ON DELETE RESTRICT,
    rationale     text NOT NULL
);
COMMENT ON TABLE zone_default IS
  'Always clipper. A hygiene cut is not a style choice, which is why there is no '
  'tool column here.';

CREATE TABLE breed_standard (
    id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    breed_id                  uuid NOT NULL REFERENCES breed(id) ON DELETE CASCADE,
    body_zone_id              uuid NOT NULL REFERENCES body_zone(id) ON DELETE RESTRICT,
    trim_context              text NOT NULL
                              CHECK (trim_context IN ('matted','puppy','short','natural')),
    recommended_blade_numbers integer[] NOT NULL,
    tool_hint                 text,
    source                    text NOT NULL,
    UNIQUE (breed_id, body_zone_id, trim_context)
);
COMMENT ON TABLE breed_standard IS
  'Advisory reference range. Nothing in the resolution ladder reads this table — '
  'it informs the human, it does not constrain the cut.';

-- =============================================================================
-- 5. Per-dog styling
-- =============================================================================

CREATE TABLE dog_style_profile (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    dog_id             uuid NOT NULL REFERENCES dog(id) ON DELETE RESTRICT,
    profile_name       text NOT NULL,
    style_template_id  uuid NOT NULL REFERENCES style_template(id) ON DELETE RESTRICT,
    length_tier_id     uuid REFERENCES length_tier(id) ON DELETE RESTRICT,
    is_default         boolean NOT NULL DEFAULT false,
    is_active          boolean NOT NULL DEFAULT true,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid REFERENCES groomer(id) ON DELETE RESTRICT,
    UNIQUE (dog_id, profile_name)
);
CREATE UNIQUE INDEX dog_style_profile_one_default
  ON dog_style_profile (dog_id) WHERE is_default AND is_active;

-- Precedence level 1. Sparse by design: only zones that deviate.
CREATE TABLE profile_zone_override (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    dog_style_profile_id  uuid NOT NULL REFERENCES dog_style_profile(id) ON DELETE CASCADE,
    body_zone_id          uuid NOT NULL REFERENCES body_zone(id) ON DELETE RESTRICT,
    tool                  cutting_tool NOT NULL,
    blade_id              uuid REFERENCES blade(id) ON DELETE RESTRICT,
    comb_id               uuid REFERENCES comb(id) ON DELETE RESTRICT,
    reason                text,
    UNIQUE (dog_style_profile_id, body_zone_id),
    CONSTRAINT override_tool_coherent CHECK (
        (tool = 'clipper'   AND blade_id IS NOT NULL)
     OR (tool IN ('scissors','hand_strip') AND blade_id IS NULL AND comb_id IS NULL)
    ),
    CONSTRAINT override_comb_needs_blade CHECK (comb_id IS NULL OR blade_id IS NOT NULL)
);

-- =============================================================================
-- 6. Cut specifications (history — snapshotted, not recomputed)
-- =============================================================================

CREATE TABLE cut_specification (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- 0..1 per visit, per the ERD cardinality.
    visit_id                uuid NOT NULL UNIQUE REFERENCES visit(id) ON DELETE CASCADE,
    dog_style_profile_id    uuid REFERENCES dog_style_profile(id) ON DELETE SET NULL,
    style_template_id       uuid NOT NULL REFERENCES style_template(id) ON DELETE RESTRICT,
    length_tier_id          uuid REFERENCES length_tier(id) ON DELETE RESTRICT,
    coat_ordinal_applied    smallint CHECK (coat_ordinal_applied BETWEEN 1 AND 5),
    deviated_from_profile   boolean NOT NULL DEFAULT false,
    deviation_reason        text,
    -- Invariant 3.1 escape hatch. Present on the record, not in a log, because
    -- this is the row that gets read back in the difficult conversation.
    remedial_override_reason text,
    -- Shop policy: puppies under min_groom_age_weeks() do not get a haircut
    -- without a stated, approved reason. A soft block — the visit still gets
    -- recorded, because a past-visit log that refuses history is useless.
    under_age_override_reason text,
    approved_by             uuid REFERENCES groomer(id) ON DELETE RESTRICT,
    approved_at             timestamptz,
    created_at              timestamptz NOT NULL DEFAULT now(),
    created_by              uuid REFERENCES groomer(id) ON DELETE RESTRICT,
    CONSTRAINT deviation_needs_reason
      CHECK (NOT deviated_from_profile OR deviation_reason IS NOT NULL),
    CONSTRAINT override_needs_approval
      CHECK (((remedial_override_reason IS NOT NULL
               OR under_age_override_reason IS NOT NULL) = (approved_by IS NOT NULL))
             AND (approved_by IS NULL) = (approved_at IS NULL))
);
CREATE INDEX cut_specification_template_idx ON cut_specification (style_template_id);

CREATE TABLE cut_spec_zone (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cut_specification_id  uuid NOT NULL REFERENCES cut_specification(id) ON DELETE CASCADE,
    body_zone_id          uuid NOT NULL REFERENCES body_zone(id) ON DELETE RESTRICT,
    tool                  cutting_tool NOT NULL,
    blade_id              uuid REFERENCES blade(id) ON DELETE RESTRICT,
    comb_id               uuid REFERENCES comb(id) ON DELETE RESTRICT,
    -- SNAPSHOT. Derived at insert from (tool, blade, comb) and then frozen.
    -- Editing blade.length_in must not silently rewrite what happened in March.
    effective_length_in   numeric(8,6),
    resolved_label        text NOT NULL,
    resolved_from         text NOT NULL
                          CHECK (resolved_from IN ('profile_override','template','zone_default','ad_hoc')),
    was_override          boolean NOT NULL DEFAULT false,
    clamp_violated        boolean NOT NULL DEFAULT false,
    note                  text,
    UNIQUE (cut_specification_id, body_zone_id),
    CONSTRAINT zone_tool_coherent CHECK (
        (tool = 'clipper'   AND blade_id IS NOT NULL)
     OR (tool IN ('scissors','hand_strip') AND blade_id IS NULL AND comb_id IS NULL)
    ),
    CONSTRAINT zone_comb_needs_blade CHECK (comb_id IS NULL OR blade_id IS NOT NULL),
    -- Scissors do not specify a length; anything else must resolve to one.
    CONSTRAINT zone_length_present CHECK (
        (tool IN ('scissors','hand_strip') AND effective_length_in IS NULL)
     OR (tool = 'clipper' AND effective_length_in IS NOT NULL)
    )
);
CREATE INDEX cut_spec_zone_spec_idx ON cut_spec_zone (cut_specification_id);
COMMENT ON COLUMN cut_spec_zone.clamp_violated IS
  'A profile override may violate a template clamp. She is the professional. '
  'Record it, flag it, do not block it.';
-- =============================================================================
-- 7. Document ingestion
-- =============================================================================

-- Scoped to the OWNER, not the dog. One vet invoice routinely covers a whole
-- household — the uploaded Doc Side invoice is addressed to the owner and would
-- cover both Shih Tzus if they were seen together. A dog_id column here would
-- force either a duplicate row (breaking the sha256 dedupe branch in the
-- ingestion flow) or an arbitrary choice of which dog "owns" the file.
CREATE TABLE document (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id       uuid NOT NULL REFERENCES owner(id) ON DELETE RESTRICT,
    object_key     text NOT NULL UNIQUE,
    mime_type      text NOT NULL
                   CHECK (mime_type IN ('application/pdf','image/jpeg','image/png','image/heic')),
    byte_size      bigint NOT NULL CHECK (byte_size > 0),
    sha256         text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    doc_class      document_class NOT NULL DEFAULT 'unknown',
    source         document_source NOT NULL,
    page_count     integer CHECK (page_count > 0),
    exif_stripped  boolean NOT NULL DEFAULT false,
    redacted       boolean NOT NULL DEFAULT false,
    uploaded_at    timestamptz NOT NULL DEFAULT now(),
    uploaded_by    uuid REFERENCES groomer(id) ON DELETE RESTRICT,
    UNIQUE (owner_id, sha256)
);
CREATE INDEX document_sha_idx    ON document (sha256);
CREATE INDEX document_owner_idx  ON document (owner_id, uploaded_at DESC);
COMMENT ON CONSTRAINT document_owner_id_sha256_key ON document IS
  'Dedupe is per owner, not global. Two owners legitimately holding the same '
  'blank-ish scan should not be collapsed into one another''s file.';

CREATE TABLE document_dog (
    document_id  uuid NOT NULL REFERENCES document(id) ON DELETE CASCADE,
    dog_id       uuid NOT NULL REFERENCES dog(id) ON DELETE RESTRICT,
    PRIMARY KEY (document_id, dog_id)
);
CREATE INDEX document_dog_dog_idx ON document_dog (dog_id);

CREATE TABLE document_page (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id        uuid NOT NULL REFERENCES document(id) ON DELETE CASCADE,
    page_number        integer NOT NULL CHECK (page_number >= 1),
    render_object_key  text NOT NULL UNIQUE,
    UNIQUE (document_id, page_number)
);

CREATE TABLE extraction (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id        uuid NOT NULL REFERENCES document(id) ON DELETE CASCADE,
    model_name         text NOT NULL,
    model_version      text NOT NULL,
    prompt_version     text NOT NULL,
    raw_response       jsonb NOT NULL,
    overall_confidence numeric(4,3) CHECK (overall_confidence BETWEEN 0 AND 1),
    status             extraction_status NOT NULL DEFAULT 'pending',
    extracted_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX extraction_document_idx ON extraction (document_id, extracted_at DESC);
COMMENT ON COLUMN extraction.raw_response IS
  'Stored unmodified. When the model is swapped, the old runs stay replayable '
  'and comparable — that is the whole reason model_version and prompt_version '
  'are columns rather than a note in a README.';

CREATE TABLE extraction_field (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    extraction_id   uuid NOT NULL REFERENCES extraction(id) ON DELETE CASCADE,
    field_name      text NOT NULL,
    extracted_value text,
    confidence      numeric(4,3) CHECK (confidence BETWEEN 0 AND 1),
    corrected_value text,
    correction_action correction_action NOT NULL DEFAULT 'unreviewed',
    was_corrected   boolean GENERATED ALWAYS AS (correction_action IN ('edited','removed')) STORED,
    page_number     integer CHECK (page_number >= 1),
    bounding_box    jsonb,
    UNIQUE (extraction_id, field_name),
    CONSTRAINT correction_coherent CHECK (
        (correction_action IN ('unreviewed','confirmed') AND corrected_value IS NULL)
     OR (correction_action = 'edited'    AND corrected_value IS NOT NULL
                                         AND corrected_value IS DISTINCT FROM extracted_value)
     OR (correction_action = 'removed'   AND corrected_value IS NULL
                                         AND extracted_value IS NOT NULL)
    )
);
COMMENT ON COLUMN extraction_field.correction_action IS
  'unreviewed = nobody has looked at this field yet, and it is the default at '
  'insert. confirmed = a human agreed. edited = the model was wrong. removed = '
  'the model produced a value that is not on the document. Separating '
  'unreviewed from confirmed is what lets an accuracy denominator be the fields '
  'a human actually checked; the removed case is the error class an accuracy '
  'claim is most tempted to lose.';

-- =============================================================================
-- 8. Vaccination and compliance
-- =============================================================================

CREATE TABLE vaccination_record (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    dog_id                  uuid NOT NULL REFERENCES dog(id) ON DELETE RESTRICT,
    vaccine_type_id         uuid NOT NULL REFERENCES vaccine_type(id) ON DELETE RESTRICT,
    document_id             uuid REFERENCES document(id) ON DELETE RESTRICT,
    administered_on         date NOT NULL CHECK (administered_on <= CURRENT_DATE),
    -- NOT NULL and NEVER DERIVED. A record whose expiry is unknown cannot be
    -- evaluated against anything, so it does not become a record: the document
    -- and its extraction stay as evidence, and the dog stays non-compliant.
    expires_on              date NOT NULL,
    implied_validity_months integer
        GENERATED ALWAYS AS (round((expires_on - administered_on) / 30.4375)::integer) STORED,
    validity_implausible    boolean NOT NULL DEFAULT false,
    vaccine_manufacturer    text,
    lot_serial_number       text,
    veterinarian_name       text,
    veterinarian_license_no text,
    veterinarian_phone      text,
    entry_method            entry_method NOT NULL,
    verification_status     verification_status NOT NULL DEFAULT 'unverified',
    verified_by             uuid REFERENCES groomer(id) ON DELETE RESTRICT,
    verified_at             timestamptz,
    created_at              timestamptz NOT NULL DEFAULT now(),
    updated_at              timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT expiry_after_administration CHECK (expires_on > administered_on),
    CONSTRAINT verification_coherent CHECK (
        (verification_status = 'unverified' AND verified_by IS NULL AND verified_at IS NULL)
     OR (verification_status <> 'unverified' AND verified_by IS NOT NULL AND verified_at IS NOT NULL)
    ),
    CONSTRAINT extracted_needs_document
      CHECK (entry_method <> 'extracted' OR document_id IS NOT NULL)
);
CREATE INDEX vaccination_record_dog_idx
  ON vaccination_record (dog_id, vaccine_type_id, expires_on DESC);
CREATE INDEX vaccination_record_expiry_idx ON vaccination_record (expires_on);
CREATE INDEX vaccination_record_doc_idx    ON vaccination_record (document_id) WHERE document_id IS NOT NULL;
COMMENT ON COLUMN vaccination_record.implied_validity_months IS
  'Approximate (30.4375-day months). It exists only to trip the plausibility '
  'flag; nothing legal or operational reads it.';

CREATE TABLE record_request (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    dog_id                  uuid NOT NULL REFERENCES dog(id) ON DELETE RESTRICT,
    owner_id                uuid NOT NULL REFERENCES owner(id) ON DELETE RESTRICT,
    vaccine_type_id         uuid NOT NULL REFERENCES vaccine_type(id) ON DELETE RESTRICT,
    channel                 request_channel NOT NULL,
    recipient_address       text,
    status                  request_status NOT NULL DEFAULT 'queued',
    reminder_count          integer NOT NULL DEFAULT 0 CHECK (reminder_count >= 0),
    max_reminders           integer NOT NULL DEFAULT 3 CHECK (max_reminders >= 0),
    next_reminder_on        date,
    resolved_by_document_id uuid REFERENCES document(id) ON DELETE SET NULL,
    unsubscribe_token       text UNIQUE,
    created_at              timestamptz NOT NULL DEFAULT now(),
    created_by              uuid REFERENCES groomer(id) ON DELETE RESTRICT,
    updated_at              timestamptz NOT NULL DEFAULT now(),
    resolved_at             timestamptz,
    -- INVARIANT 3.6, first clause. The opt-out clause is cross-table and lives
    -- in a trigger.
    CONSTRAINT reminder_cap CHECK (reminder_count <= max_reminders),
    CONSTRAINT terminal_has_no_next_reminder
      CHECK (status NOT IN ('resolved','abandoned') OR next_reminder_on IS NULL),
    CONSTRAINT resolved_has_timestamp
      CHECK ((status = 'resolved') = (resolved_at IS NOT NULL)),
    CONSTRAINT email_request_has_token
      CHECK (channel <> 'email' OR unsubscribe_token IS NOT NULL)
);
-- One open request per dog per vaccine, so "the open request" is well defined
-- and dog_compliance_status.open_request_id cannot be ambiguous.
CREATE UNIQUE INDEX record_request_one_open
  ON record_request (dog_id, vaccine_type_id)
  WHERE status IN ('queued','sent');
CREATE INDEX record_request_owner_idx ON record_request (owner_id);
CREATE INDEX record_request_due_idx
  ON record_request (next_reminder_on) WHERE next_reminder_on IS NOT NULL;

CREATE TABLE record_request_event (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    record_request_id   uuid NOT NULL REFERENCES record_request(id) ON DELETE CASCADE,
    event_type          request_event_type NOT NULL,
    provider_message_id text,
    provider_payload    jsonb,
    occurred_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX record_request_event_req_idx
  ON record_request_event (record_request_id, occurred_at);

-- Maintained projection, now one row per (dog, tracked vaccine). Holds only
-- DATE-INDEPENDENT facts; the state ladder is computed at read time by
-- v_dog_vaccine_compliance. A vaccine is "tracked" when it is required by law
-- or by shop policy.
--
-- Age is deliberately NOT stored here. A puppy crossing 16 weeks is a function
-- of today, exactly like an expiry date, and the two-layer split exists so the
-- calendar can never make this table stale.
CREATE TABLE dog_vaccine_compliance (
    dog_id                 uuid NOT NULL REFERENCES dog(id) ON DELETE CASCADE,
    vaccine_type_id        uuid NOT NULL REFERENCES vaccine_type(id) ON DELETE CASCADE,
    -- Deliberately NOT foreign keys. This is a projection, rebuilt from source
    -- on every write. An ON DELETE SET NULL firing alongside the refresh trigger
    -- would race it and could null one half of a paired fact.
    latest_record_id       uuid,
    expires_on             date,
    record_verification    verification_status,
    open_request_id        uuid,
    request_count          integer NOT NULL DEFAULT 0,
    last_refreshed_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (dog_id, vaccine_type_id),
    CONSTRAINT record_facts_together
      CHECK ((latest_record_id IS NULL) = (expires_on IS NULL)
         AND (latest_record_id IS NULL) = (record_verification IS NULL))
);
CREATE INDEX dog_vaccine_compliance_expiry_idx ON dog_vaccine_compliance (expires_on);
CREATE INDEX dog_vaccine_compliance_vaccine_idx ON dog_vaccine_compliance (vaccine_type_id);

CREATE TABLE compliance_packet (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    requested_by        text NOT NULL,
    coverage_start      date NOT NULL,
    coverage_end        date NOT NULL,
    dog_count           integer NOT NULL CHECK (dog_count >= 0),
    dogs_missing_records integer NOT NULL CHECK (dogs_missing_records >= 0),
    object_key          text NOT NULL UNIQUE,
    generated_by        uuid REFERENCES groomer(id) ON DELETE RESTRICT,
    generated_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT coverage_ordered CHECK (coverage_end >= coverage_start),
    CONSTRAINT missing_within_total CHECK (dogs_missing_records <= dog_count)
);
COMMENT ON COLUMN compliance_packet.dogs_missing_records IS
  'The honest number. A packet that silently omits the dogs with no paperwork '
  'is worse than no packet, because it reads as an all-clear.';

-- =============================================================================
-- 9. Governance
-- =============================================================================

-- No FK on actor_id: the audit trail must survive the deletion of the actor,
-- and a snapshot of who they were is more useful than a dangling pointer.
CREATE TABLE audit_log (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id       uuid,
    actor_label    text NOT NULL,
    action         audit_action NOT NULL,
    entity_type    text NOT NULL,
    entity_id      uuid,
    changed_fields jsonb,
    ip_address     inet,
    occurred_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_log_entity_idx ON audit_log (entity_type, entity_id, occurred_at DESC);
CREATE INDEX audit_log_actor_idx  ON audit_log (actor_id, occurred_at DESC);

CREATE TABLE retention_rule (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_type   text NOT NULL,
    retain_months integer NOT NULL CHECK (retain_months >= 0),
    anchor_field  text NOT NULL CHECK (anchor_field IN ('last_activity_at','expires_on','uploaded_at','occurred_at')),
    action        retention_action NOT NULL,
    is_active     boolean NOT NULL DEFAULT true,
    UNIQUE (entity_type, anchor_field)
);

CREATE TABLE retention_run (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    retention_rule_id uuid NOT NULL REFERENCES retention_rule(id) ON DELETE RESTRICT,
    rows_affected     integer NOT NULL CHECK (rows_affected >= 0),
    outcome           text NOT NULL,
    executed_at       timestamptz NOT NULL DEFAULT now()
);
-- =============================================================================
-- 10. Derivation helpers
-- =============================================================================

-- The comb always wins. A #30 under a 1" comb cuts at 1"; the blade number is
-- an implementation detail of how combs work.
CREATE FUNCTION derive_effective_length(p_tool cutting_tool, p_blade_id uuid, p_comb_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN p_tool <> 'clipper'    THEN NULL
        WHEN p_comb_id IS NOT NULL  THEN (SELECT c.length_in FROM comb  c WHERE c.id = p_comb_id)
        ELSE                             (SELECT b.length_in FROM blade b WHERE b.id = p_blade_id)
    END
$$;

CREATE FUNCTION describe_tooling(p_tool cutting_tool, p_blade_id uuid, p_comb_id uuid)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN p_tool = 'scissors'   THEN 'Scissors'
        WHEN p_tool = 'hand_strip' THEN 'Hand strip'
        ELSE (SELECT '#' || b.number || CASE WHEN b.is_finish THEN 'F' ELSE '' END
              FROM blade b WHERE b.id = p_blade_id)
             || COALESCE(' + ' || (SELECT c.label FROM comb c WHERE c.id = p_comb_id), '')
    END
$$;

CREATE FUNCTION touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$;

CREATE TRIGGER owner_touch  BEFORE UPDATE ON owner
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER dog_touch    BEFORE UPDATE ON dog
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER profile_touch BEFORE UPDATE ON dog_style_profile
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER vacc_touch   BEFORE UPDATE ON vaccination_record
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER request_touch BEFORE UPDATE ON record_request
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- Snapshot the effective length and label whenever the tooling is written.
-- Recomputed on a genuine correction to this row; never recomputed because the
-- blade table changed.
CREATE FUNCTION snapshot_cut_spec_zone() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.effective_length_in := derive_effective_length(NEW.tool, NEW.blade_id, NEW.comb_id);
    NEW.resolved_label      := describe_tooling(NEW.tool, NEW.blade_id, NEW.comb_id);
    RETURN NEW;
END $$;

CREATE TRIGGER cut_spec_zone_snapshot
    BEFORE INSERT OR UPDATE OF tool, blade_id, comb_id ON cut_spec_zone
    FOR EACH ROW EXECUTE FUNCTION snapshot_cut_spec_zone();

-- =============================================================================
-- Error code registry. Each invariant raises its own SQLSTATE so tests assert
-- on a stable identifier rather than on prose, and the API layer maps codes to
-- user-facing messages without matching strings.
--
--   GR001  remedial cut without a qualifying coat assessment
--   GR002  approved remedial override with no coat level stated
--   GR003  uniform-length template resolved to more than one length
--   GR004  cut specification on a visit with no groom service
--   GR005  email reminder to an owner who opted out
--   GR006  template zone spec configured outside its clamp
--   GR007  unknown style template
--   GR008  remedial template saved as a standing style profile
--   GR009  tiered template with no length tier
--   GR010  length tier supplied to a non-tiered template
--   GR011  haircut on a dog under the minimum grooming age, no approved reason
-- =============================================================================

-- =============================================================================
-- 11. Trigger-enforced invariants
--     Numbering matches resolution_precedence.md §3.
-- =============================================================================

-- 3.1 — A remedial template requires a qualifying coat assessment on the same
--       visit, or an explicitly approved override. The refusal is the feature.
CREATE FUNCTION enforce_remedial_requires_assessment() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_required smallint;
    v_actual   smallint;
BEGIN
    SELECT t.min_coat_ordinal_required INTO v_required
    FROM style_template t WHERE t.id = NEW.style_template_id AND t.is_remedial;

    IF v_required IS NULL THEN
        RETURN NEW;                              -- not a remedial template
    END IF;

    IF NEW.remedial_override_reason IS NOT NULL THEN
        -- Approval is enforced by CHECK, but the expansion still keys remedial
        -- template rows on coat_ordinal_applied. Without it the approved
        -- shave-down expands to hygiene zones only: a record of nothing.
        IF NEW.coat_ordinal_applied IS NULL THEN
            RAISE EXCEPTION
                'An approved remedial override must still state the coat level applied'
                USING ERRCODE = 'GR002',
                      HINT = 'Set coat_ordinal_applied (1-5) to the level the groomer judged.';
        END IF;
        RETURN NEW;
    END IF;

    SELECT ca.condition_ordinal INTO v_actual
    FROM coat_assessment ca WHERE ca.visit_id = NEW.visit_id;

    -- The remedial axis IS the coat level, so carry it onto the spec. Without
    -- this the expansion has nothing to key style_template_zone_spec on.
    NEW.coat_ordinal_applied := COALESCE(NEW.coat_ordinal_applied, v_actual);

    IF v_actual IS NULL THEN
        RAISE EXCEPTION
            'Remedial template requires a coat assessment on visit %', NEW.visit_id
            USING ERRCODE = 'GR001',
                  HINT = 'Record the coat assessment first, or supply remedial_override_reason with a manager approval.';
    END IF;

    IF v_actual < v_required THEN
        RAISE EXCEPTION
            'Coat assessment level % does not justify a remedial cut (requires %)',
            v_actual, v_required
            USING ERRCODE = 'GR001';
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER cut_spec_remedial_guard
    BEFORE INSERT OR UPDATE ON cut_specification
    FOR EACH ROW EXECUTE FUNCTION enforce_remedial_requires_assessment();

-- 3.2 — Uniform-length templates must resolve uniformly. Deferred so the full
--       set of zone rows is visible at commit.
CREATE FUNCTION enforce_uniform_length() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_uniform  boolean;
    v_distinct integer;
BEGIN
    SELECT t.requires_uniform_length INTO v_uniform
    FROM cut_specification cs
    JOIN style_template t ON t.id = cs.style_template_id
    WHERE cs.id = NEW.cut_specification_id;

    IF NOT COALESCE(v_uniform, false) THEN
        RETURN NULL;
    END IF;

    -- Only template-resolved zones are counted. A profile override or a
    -- visit-time edit deviating from uniformity is the groomer's call, and the
    -- same reasoning that flags rather than blocks a clamp violation applies
    -- here: seed time is where uniformity is enforced, haircut time is where it
    -- is recorded.
    SELECT count(DISTINCT z.effective_length_in) INTO v_distinct
    FROM cut_spec_zone z
    WHERE z.cut_specification_id = NEW.cut_specification_id
      AND z.resolved_from = 'template'
      AND z.effective_length_in IS NOT NULL;

    IF v_distinct > 1 THEN
        RAISE EXCEPTION
            'Cut specification % uses a uniform-length template but resolved to % distinct lengths',
            NEW.cut_specification_id, v_distinct
            USING ERRCODE = 'GR003';
    END IF;

    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER cut_spec_zone_uniform_guard
    AFTER INSERT OR UPDATE ON cut_spec_zone
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION enforce_uniform_length();

-- 3.4 — A cut specification requires a visit service that carries one.
--       Deferred, because the spec and the service rows arrive in one
--       transaction and the order is the application's business.
CREATE FUNCTION enforce_cut_spec_requires_groom() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM visit_service vs
        JOIN service_type st ON st.id = vs.service_type_id
        WHERE vs.visit_id = NEW.visit_id AND st.carries_cut_spec
    ) THEN
        RAISE EXCEPTION
            'Visit % has no service that carries a cut specification', NEW.visit_id
            USING ERRCODE = 'GR004',
                  HINT = 'A bath-only visit does not get a haircut record.';
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER cut_spec_service_guard
    AFTER INSERT OR UPDATE ON cut_specification
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION enforce_cut_spec_requires_groom();

-- 3.5 — Plausibility is a flag, never a block, and expires_on is never derived.
CREATE FUNCTION flag_validity_plausibility() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_min integer;
    v_max integer;
BEGIN
    SELECT vt.plausible_validity_min_months, vt.plausible_validity_max_months
      INTO v_min, v_max
    FROM vaccine_type vt WHERE vt.id = NEW.vaccine_type_id;

    -- Recomputed inline, NOT read from implied_validity_months: generated
    -- columns are not populated in NEW until after BEFORE triggers have run.
    NEW.validity_implausible := round(
        (NEW.expires_on - NEW.administered_on) / 30.4375)::integer NOT BETWEEN v_min AND v_max;
    RETURN NEW;
END $$;

CREATE TRIGGER vaccination_plausibility
    BEFORE INSERT OR UPDATE ON vaccination_record
    FOR EACH ROW EXECUTE FUNCTION flag_validity_plausibility();

-- 3.6 — Opt-out clause. The cap itself is a CHECK on record_request.
CREATE FUNCTION enforce_opt_out() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.channel = 'email' AND NEW.status = 'sent'
       AND EXISTS (SELECT 1 FROM owner o WHERE o.id = NEW.owner_id AND o.email_opted_out)
    THEN
        RAISE EXCEPTION 'Owner % has opted out of email', NEW.owner_id
            USING ERRCODE = 'GR005',
                  HINT = 'Switch the channel to verbal_at_counter or sms.';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER record_request_opt_out_guard
    BEFORE INSERT OR UPDATE ON record_request
    FOR EACH ROW EXECUTE FUNCTION enforce_opt_out();

-- Clamp validation lives on the SEED data, not on the haircut. A clamp says
-- "this template may not be configured that way"; it does not silently rewrite
-- what the groomer chose.
CREATE FUNCTION enforce_template_clamp() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_len numeric;
    v_c   style_template_zone_clamp;
BEGIN
    SELECT * INTO v_c FROM style_template_zone_clamp c
    WHERE c.style_template_id = NEW.style_template_id
      AND c.body_zone_id = NEW.body_zone_id;

    IF NOT FOUND THEN RETURN NEW; END IF;

    v_len := derive_effective_length(NEW.tool, NEW.blade_id, NEW.comb_id);
    IF v_len IS NULL THEN RETURN NEW; END IF;

    IF (v_c.max_effective_length_in IS NOT NULL AND v_len > v_c.max_effective_length_in)
    OR (v_c.min_effective_length_in IS NOT NULL AND v_len < v_c.min_effective_length_in) THEN
        RAISE EXCEPTION
            'Template zone spec violates clamp (%): % is outside [%, %]',
            v_c.rationale, v_len, v_c.min_effective_length_in, v_c.max_effective_length_in
            USING ERRCODE = 'GR006';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER template_zone_spec_clamp_guard
    BEFORE INSERT OR UPDATE ON style_template_zone_spec
    FOR EACH ROW EXECUTE FUNCTION enforce_template_clamp();

-- 3.8 — Minimum grooming age.
-- Flag, not a hard block: the reason is required, but the visit is still
-- recorded. A hard age block belongs in customer-facing booking software; a
-- system of record that refuses to record what happened is worse than useless.
-- An unknown birth date is not treated as under age.
CREATE FUNCTION enforce_min_groom_age() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_dob      date;
    v_weeks    integer;
BEGIN
    IF NEW.under_age_override_reason IS NOT NULL THEN
        RETURN NEW;                      -- approval already enforced by CHECK
    END IF;

    SELECT d.date_of_birth INTO v_dob
    FROM visit v JOIN dog d ON d.id = v.dog_id
    WHERE v.id = NEW.visit_id;

    IF v_dob IS NULL THEN
        RETURN NEW;                      -- rescue dogs get no presumption
    END IF;

    v_weeks := ((SELECT v.visit_date FROM visit v WHERE v.id = NEW.visit_id) - v_dob) / 7;

    IF v_weeks < min_groom_age_weeks() THEN
        RAISE EXCEPTION
            'Dog was % weeks old at this visit; minimum grooming age is %',
            v_weeks, min_groom_age_weeks()
            USING ERRCODE = 'GR011',
                  HINT = 'Record why the haircut went ahead and get a manager to approve it.';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER cut_spec_min_age_guard
    BEFORE INSERT OR UPDATE ON cut_specification
    FOR EACH ROW EXECUTE FUNCTION enforce_min_groom_age();

-- 3.7 — Tier shape coherence.
-- A tiered template expands against (template, tier, zone). With no tier, the
-- expansion matches no template rows and the visit records hygiene zones only:
-- a structurally empty haircut, the same failure 3.1's override clause closes
-- on the remedial side. The mirror case — a tier supplied to a template that
-- keys on coat severity — is equally meaningless. Both tables carrying the
-- (template, tier) pair are guarded by the same function.
CREATE FUNCTION enforce_tier_shape() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_supports_tiers boolean;
    v_is_remedial    boolean;
BEGIN
    SELECT t.supports_tiers, t.is_remedial
      INTO v_supports_tiers, v_is_remedial
    FROM style_template t WHERE t.id = NEW.style_template_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown style template %', NEW.style_template_id
            USING ERRCODE = 'GR007';
    END IF;

    IF TG_ARGV[0] = 'profile' AND v_is_remedial THEN
        RAISE EXCEPTION 'A remedial template cannot be saved as a style profile'
            USING ERRCODE = 'GR008',
                  HINT = 'Shaved is a response to coat condition, not a standing preference.';
    END IF;

    IF v_supports_tiers AND NEW.length_tier_id IS NULL THEN
        RAISE EXCEPTION 'Template % requires a length tier', NEW.style_template_id
            USING ERRCODE = 'GR009',
                  HINT = 'Without a tier the expansion resolves nothing but hygiene zones.';
    ELSIF NOT v_supports_tiers AND NEW.length_tier_id IS NOT NULL THEN
        RAISE EXCEPTION 'Template % does not support length tiers', NEW.style_template_id
            USING ERRCODE = 'GR010',
                  HINT = 'Remedial templates key on coat severity, not tier.';
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER cut_spec_tier_shape_guard
    BEFORE INSERT OR UPDATE ON cut_specification
    FOR EACH ROW EXECUTE FUNCTION enforce_tier_shape('cut_spec');

CREATE TRIGGER profile_tier_shape_guard
    BEFORE INSERT OR UPDATE ON dog_style_profile
    FOR EACH ROW EXECUTE FUNCTION enforce_tier_shape('profile');

-- Append-only audit log.
CREATE FUNCTION reject_audit_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'audit_log is append-only';
END $$;

CREATE TRIGGER audit_log_immutable
    BEFORE UPDATE OR DELETE ON audit_log
    FOR EACH STATEMENT EXECUTE FUNCTION reject_audit_mutation();

-- =============================================================================
-- 12. Cut specification expansion — implements §1 precedence exactly
-- =============================================================================

CREATE FUNCTION resolve_cut_spec_zones(p_cut_specification_id uuid)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_spec     cut_specification;
    v_inserted integer;
BEGIN
    SELECT * INTO STRICT v_spec FROM cut_specification WHERE id = p_cut_specification_id;

    -- Ad hoc, visit-time edits sit above all four levels and survive re-expansion.
    DELETE FROM cut_spec_zone
    WHERE cut_specification_id = p_cut_specification_id AND resolved_from <> 'ad_hoc';

    WITH tmpl AS (
        -- Level 2. DISTINCT ON handles remedial templates, which key on coat
        -- severity rather than tier: take the most severe threshold met.
        SELECT DISTINCT ON (s.body_zone_id)
               s.body_zone_id, s.tool, s.blade_id, s.comb_id
        FROM style_template_zone_spec s
        WHERE s.style_template_id = v_spec.style_template_id
          AND (s.length_tier_id = v_spec.length_tier_id
               OR (s.min_coat_ordinal IS NOT NULL
                   AND s.min_coat_ordinal <= v_spec.coat_ordinal_applied))
        ORDER BY s.body_zone_id, s.min_coat_ordinal DESC NULLS LAST
    ),
    ovr AS (                                            -- Level 1
        SELECT o.body_zone_id, o.tool, o.blade_id, o.comb_id
        FROM profile_zone_override o
        WHERE o.dog_style_profile_id = v_spec.dog_style_profile_id
    ),
    dflt AS (                                           -- Level 3
        SELECT d.body_zone_id, 'clipper'::cutting_tool AS tool,
               d.blade_id, NULL::uuid AS comb_id
        FROM zone_default d
    ),
    zones AS (
        SELECT body_zone_id FROM ovr
        UNION SELECT body_zone_id FROM tmpl
        UNION SELECT body_zone_id FROM dflt
    ),
    resolved AS (
        SELECT z.body_zone_id,
               COALESCE(o.tool, t.tool, d.tool)             AS tool,
               CASE WHEN o.body_zone_id IS NOT NULL THEN o.blade_id
                    WHEN t.body_zone_id IS NOT NULL THEN t.blade_id
                    ELSE d.blade_id END                     AS blade_id,
               CASE WHEN o.body_zone_id IS NOT NULL THEN o.comb_id
                    WHEN t.body_zone_id IS NOT NULL THEN t.comb_id
                    ELSE d.comb_id END                      AS comb_id,
               CASE WHEN o.body_zone_id IS NOT NULL THEN 'profile_override'
                    WHEN t.body_zone_id IS NOT NULL THEN 'template'
                    ELSE 'zone_default' END                 AS resolved_from
        FROM zones z
        LEFT JOIN ovr  o ON o.body_zone_id = z.body_zone_id
        LEFT JOIN tmpl t ON t.body_zone_id = z.body_zone_id
        LEFT JOIN dflt d ON d.body_zone_id = z.body_zone_id
    )
    INSERT INTO cut_spec_zone (
        cut_specification_id, body_zone_id, tool, blade_id, comb_id,
        effective_length_in, resolved_label, resolved_from, was_override, clamp_violated)
    SELECT p_cut_specification_id, r.body_zone_id, r.tool, r.blade_id, r.comb_id,
           NULL, '', r.resolved_from,
           r.resolved_from = 'profile_override',
           COALESCE(derive_effective_length(r.tool, r.blade_id, r.comb_id)
                      > c.max_effective_length_in, false)
        OR COALESCE(derive_effective_length(r.tool, r.blade_id, r.comb_id)
                      < c.min_effective_length_in, false)
    FROM resolved r
    LEFT JOIN style_template_zone_clamp c
           ON c.style_template_id = v_spec.style_template_id
          AND c.body_zone_id = r.body_zone_id
    WHERE NOT EXISTS (
        SELECT 1 FROM cut_spec_zone x
        WHERE x.cut_specification_id = p_cut_specification_id
          AND x.body_zone_id = r.body_zone_id);

    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    RETURN v_inserted;
END $$;
COMMENT ON FUNCTION resolve_cut_spec_zones(uuid) IS
  'effective_length_in and resolved_label are written as placeholders and filled '
  'by the cut_spec_zone_snapshot BEFORE trigger, so there is exactly one code '
  'path that derives them.';

-- =============================================================================
-- 13. Compliance projection
-- =============================================================================

CREATE FUNCTION refresh_dog_vaccine_compliance(p_dog_id uuid) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM dog_vaccine_compliance WHERE dog_id = p_dog_id;

    INSERT INTO dog_vaccine_compliance
        (dog_id, vaccine_type_id, latest_record_id, expires_on,
         record_verification, open_request_id, request_count, last_refreshed_at)
    SELECT p_dog_id, vt.id, r.id, r.expires_on, r.verification_status,
           q.id, COALESCE(q.reminder_count, 0), now()
    FROM vaccine_type vt
    LEFT JOIN LATERAL (
        SELECT vr.id, vr.expires_on, vr.verification_status
        FROM vaccination_record vr
        WHERE vr.dog_id = p_dog_id AND vr.vaccine_type_id = vt.id
        ORDER BY vr.expires_on DESC, vr.created_at DESC
        LIMIT 1
    ) r ON true
    LEFT JOIN LATERAL (
        SELECT rr.id, rr.reminder_count
        FROM record_request rr
        WHERE rr.dog_id = p_dog_id AND rr.vaccine_type_id = vt.id
          AND rr.status IN ('queued','sent')
        LIMIT 1
    ) q ON true
    WHERE vt.regulatory_required OR vt.required_by_policy;
END $$;
COMMENT ON FUNCTION refresh_dog_vaccine_compliance(uuid) IS
  'Superseded records are retained. "Latest" means latest expires_on, not '
  'latest created_at — a backfilled old certificate must not displace a current '
  'one. Only vaccines required by law or by shop policy get a row; the rest are '
  'recorded but advisory.';

-- Call after changing which vaccines are tracked. Every dog needs a row per
-- tracked vaccine, and flipping required_by_policy changes that set.
CREATE FUNCTION refresh_all_compliance() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_n integer := 0; d record;
BEGIN
    FOR d IN SELECT id FROM dog LOOP
        PERFORM refresh_dog_vaccine_compliance(d.id);
        v_n := v_n + 1;
    END LOOP;
    RETURN v_n;
END $$;

CREATE FUNCTION trg_refresh_compliance() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM refresh_dog_vaccine_compliance(
        CASE WHEN TG_OP = 'DELETE' THEN OLD.dog_id ELSE NEW.dog_id END);
    RETURN NULL;
END $$;

CREATE TRIGGER vaccination_record_compliance
    AFTER INSERT OR UPDATE OR DELETE ON vaccination_record
    FOR EACH ROW EXECUTE FUNCTION trg_refresh_compliance();

CREATE TRIGGER record_request_compliance
    AFTER INSERT OR UPDATE OR DELETE ON record_request
    FOR EACH ROW EXECUTE FUNCTION trg_refresh_compliance();

CREATE FUNCTION trg_seed_compliance() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM refresh_dog_vaccine_compliance(NEW.id);
    RETURN NULL;
END $$;

CREATE TRIGGER dog_seed_compliance AFTER INSERT ON dog
    FOR EACH ROW EXECUTE FUNCTION trg_seed_compliance();

-- Per dog, per vaccine. Driving FROM dog CROSS JOIN tracked vaccines makes
-- "every active dog is evaluated against every tracked vaccine" structural
-- rather than a promise the refresh job has to keep.
CREATE VIEW v_dog_vaccine_compliance AS
SELECT
    d.id                AS dog_id,
    d.name              AS dog_name,
    d.owner_id,
    vt.id               AS vaccine_type_id,
    vt.code             AS vaccine_code,
    vt.regulatory_required,
    vt.blocks_service_if_expired,
    s.latest_record_id,
    s.expires_on,
    COALESCE(s.request_count, 0) AS request_count,
    s.open_request_id,
    (s.expires_on - CURRENT_DATE) AS days_until_expiry,
    CASE
        -- A contested record's expiry date is not something to schedule against.
        WHEN s.record_verification = 'disputed'                    THEN 'disputed_record'
        WHEN s.expires_on IS NOT NULL
             AND s.expires_on < CURRENT_DATE                       THEN 'expired'
        WHEN s.expires_on IS NOT NULL
             AND s.expires_on <= CURRENT_DATE + expiry_warning_days()
                                                                   THEN 'expiring_soon'
        WHEN s.record_verification = 'unverified'                  THEN 'received_unverified'
        WHEN s.latest_record_id IS NOT NULL                        THEN 'current'
        -- No record yet. Is the dog even old enough to have had it?
        -- An unknown birth date gets no grace period.
        WHEN vt.min_age_weeks IS NOT NULL
             AND d.date_of_birth IS NOT NULL
             AND d.date_of_birth > CURRENT_DATE - (vt.min_age_weeks * 7)
                                                                   THEN 'not_yet_due'
        WHEN s.open_request_id IS NOT NULL                         THEN 'requested_pending'
        ELSE 'no_record'
    END::compliance_state AS state
FROM dog d
CROSS JOIN vaccine_type vt
LEFT JOIN dog_vaccine_compliance s
       ON s.dog_id = d.id AND s.vaccine_type_id = vt.id
WHERE d.is_active
  AND (vt.regulatory_required OR vt.required_by_policy);

-- Per dog rollup: worst state wins. Rabies current but Bordetella missing is
-- not a compliant dog.
--
-- Note the two aggregations are different. `state` is the worst state across
-- every tracked vaccine. `blocks_service` additionally requires the vaccine
-- itself to be service-blocking — an expired Bordetella can show red on the
-- dashboard without cancelling the appointment, and that is per-vaccine
-- configuration rather than a global policy choice.
CREATE VIEW v_dog_compliance_status AS
SELECT
    v.dog_id,
    v.dog_name,
    v.owner_id,
    (SELECT w.state FROM v_dog_vaccine_compliance w
      JOIN compliance_state_meta m2 ON m2.state = w.state
     WHERE w.dog_id = v.dog_id
     ORDER BY m2.sort_order LIMIT 1)          AS state,
    bool_or(m.blocks_service AND v.blocks_service_if_expired) AS blocks_service,
    count(*) FILTER (WHERE m.actionable)      AS actionable_vaccine_count,
    min(v.days_until_expiry)                  AS days_until_next_expiry
FROM v_dog_vaccine_compliance v
JOIN compliance_state_meta m ON m.state = v.state
GROUP BY v.dog_id, v.dog_name, v.owner_id;

CREATE VIEW v_compliance_dashboard AS
SELECT c.*, m.plain_language_label, m.actionable, m.sort_order
FROM v_dog_compliance_status c
JOIN compliance_state_meta m ON m.state = c.state
ORDER BY m.sort_order, c.days_until_next_expiry NULLS LAST;

-- Live, join-only recomputation. The test suite asserts this equals the
-- maintained table; any divergence is a bug in the refresh triggers.
CREATE VIEW v_dog_vaccine_compliance_recompute AS
SELECT d.id AS dog_id, vt.id AS vaccine_type_id,
       r.id AS latest_record_id, r.expires_on,
       r.verification_status AS record_verification,
       q.id AS open_request_id, COALESCE(q.reminder_count, 0) AS request_count
FROM dog d
CROSS JOIN vaccine_type vt
LEFT JOIN LATERAL (
    SELECT vr.id, vr.expires_on, vr.verification_status
    FROM vaccination_record vr
    WHERE vr.dog_id = d.id AND vr.vaccine_type_id = vt.id
    ORDER BY vr.expires_on DESC, vr.created_at DESC LIMIT 1
) r ON true
LEFT JOIN LATERAL (
    SELECT rr.id, rr.reminder_count FROM record_request rr
    WHERE rr.dog_id = d.id AND rr.vaccine_type_id = vt.id
      AND rr.status IN ('queued','sent') LIMIT 1
) q ON true
WHERE vt.regulatory_required OR vt.required_by_policy;

-- Config is live: template lengths are derived at read time, never stored.
CREATE VIEW v_style_template_zone_spec AS
SELECT s.id, t.code AS template_code, lt.code AS tier_code, s.min_coat_ordinal,
       bz.code AS zone_code, s.tool, s.blade_id, s.comb_id,
       derive_effective_length(s.tool, s.blade_id, s.comb_id) AS effective_length_in,
       describe_tooling(s.tool, s.blade_id, s.comb_id)        AS label
FROM style_template_zone_spec s
JOIN style_template t   ON t.id  = s.style_template_id
JOIN body_zone bz       ON bz.id = s.body_zone_id
LEFT JOIN length_tier lt ON lt.id = s.length_tier_id;
-- =============================================================================
-- 14. Reference seed data
--     Vocabulary only. The per-template zone mappings from style_tier_mapping.md
--     are ~150 rows and belong in their own migration.
-- =============================================================================

INSERT INTO coat_type (code, name, description) VALUES
  ('curly',  'Curly',  'Continuously growing; mats readily. Poodle, Bichon, Shih Tzu crosses.'),
  ('wiry',   'Wiry',   'Harsh outer coat; candidate for hand-stripping.'),
  ('smooth', 'Smooth', 'Short, close-lying. Bathing and deshedding, rarely cutting.'),
  ('double', 'Double', 'Undercoat plus guard hair. Clipping is usually the wrong answer.'),
  ('silky',  'Silky',  'Fine, straight, continuously growing. Shih Tzu, Yorkshire Terrier.');

INSERT INTO length_tier (code, sort_order) VALUES ('short',1), ('medium',2), ('long',3);

INSERT INTO blade (number, is_finish, length_in, plain_language_label) VALUES
  ( 3, false, 0.500000, '#3 (1/2 inch)'),
  ( 3, true,  0.500000, '#3F (1/2 inch, finish)'),
  ( 4, false, 0.375000, '#4 (3/8 inch)'),
  ( 4, true,  0.375000, '#4F (3/8 inch, finish)'),
  ( 5, false, 0.250000, '#5 (1/4 inch)'),
  ( 5, true,  0.250000, '#5F (1/4 inch, finish)'),
  ( 7, false, 0.125000, '#7 (1/8 inch)'),
  ( 7, true,  0.125000, '#7F (1/8 inch, finish)'),
  ( 9, false, 0.078125, '#9 (5/64 inch)'),
  (10, false, 0.062500, '#10 (1/16 inch)'),
  (15, false, 0.046875, '#15 (3/64 inch)'),
  (30, false, 0.020000, '#30 (1/50 inch)');

INSERT INTO comb (length_in, label) VALUES
  (0.750000, '3/4 inch comb'),
  (1.000000, '1 inch comb'),
  (1.250000, '1 1/4 inch comb');

INSERT INTO body_zone (code, plain_language_label, display_order) VALUES
  ('body',                'Body',                 10),
  ('neck',                'Neck',                 20),
  ('legs',                'Legs',                 30),
  ('head_skull',          'Head / skull',         40),
  ('tail',                'Tail',                 70),
  ('stomach_underbody',   'Stomach / underbody',  90),
  ('ears',                'Ears',                100),
  ('sanitary',            'Sanitary',            200),
  ('feet_pads',           'Feet & pads',         210),
  ('inside_ears',         'Inside ears',         220);

INSERT INTO body_zone (code, plain_language_label, display_order, parent_zone_id) VALUES
  ('face',      'Face',            50, (SELECT id FROM body_zone WHERE code='head_skull')),
  ('top_knot',  'Top knot',        60, (SELECT id FROM body_zone WHERE code='head_skull')),
  ('ear_tips',  'Ear tips',       110, (SELECT id FROM body_zone WHERE code='ears')),
  ('tail_pom',  'Tail pom',        80, (SELECT id FROM body_zone WHERE code='tail')),
  ('base_of_tail','Base of tail',  85, (SELECT id FROM body_zone WHERE code='tail'));

INSERT INTO body_zone (code, plain_language_label, display_order, parent_zone_id) VALUES
  ('muzzle_beard', 'Muzzle / beard', 55, (SELECT id FROM body_zone WHERE code='face'));

-- Precedence level 3. Hygiene cuts, invariant across every template and tier.
INSERT INTO zone_default (body_zone_id, blade_id, rationale) VALUES
  ((SELECT id FROM body_zone WHERE code='sanitary'),
   (SELECT id FROM blade WHERE number=10 AND NOT is_finish), 'Hygiene cut'),
  ((SELECT id FROM body_zone WHERE code='feet_pads'),
   (SELECT id FROM blade WHERE number=15 AND NOT is_finish), 'Hygiene cut; pads must be clear'),
  ((SELECT id FROM body_zone WHERE code='inside_ears'),
   (SELECT id FROM blade WHERE number=10 AND NOT is_finish), 'Hygiene cut; airflow');

INSERT INTO service_type (code, name, carries_cut_spec, display_order) VALUES
  ('bath',       'Bath',        false, 10),
  ('nail_trim',  'Nail trim',   false, 20),
  ('ear_clean',  'Ear clean',   false, 30),
  ('teeth',      'Teeth',       false, 40),
  ('deshed',     'Deshed',      false, 50),
  ('full_groom', 'Full groom',  true,  60);

-- regulatory_required = the law says so.  required_by_policy = the shop says so.
-- min_age_weeks = below this age the vaccine is not yet due, so the dog is not
-- non-compliant and its owner should not be chased.
INSERT INTO vaccine_type
  (code, name, regulatory_required, required_by_policy, min_age_weeks, authority,
   plausible_validity_min_months, plausible_validity_max_months, blocks_service_if_expired)
VALUES
  ('rabies',        'Rabies',        true,  true,  16, 'COMAR 10.06.02',  12, 36, true),
  ('dhpp',          'DHPP',          false, true,   8, 'facility policy', 12, 36, false),
  ('bordetella',    'Bordetella',    false, true,   8, 'facility policy',  6, 12, false),
  -- Recorded if a document mentions it, but never sets compliance state.
  ('leptospirosis', 'Leptospirosis', false, false, 12, 'facility policy', 12, 12, false);

INSERT INTO compliance_state_meta
  (state, sort_order, plain_language_label, blocks_service, actionable) VALUES
  ('disputed_record',     1, 'Disputed — needs review',       true,  true),
  ('expired',             2, 'Expired',                       true,  true),
  ('no_record',           3, 'No record on file',             true,  true),
  ('expiring_soon',       4, 'Expiring within 30 days',       false, true),
  ('received_unverified', 5, 'Received, awaiting verification', false, true),
  ('requested_pending',   6, 'Requested, awaiting response',  true,  false),
  -- Too young to have had it. Not compliant, not a problem, not chaseable.
  ('not_yet_due',         7, 'Not yet due (puppy)',           false, false),
  ('current',             8, 'Current',                       false, false);

INSERT INTO style_template
  (code, name, plain_language_description, is_remedial, supports_tiers,
   requires_uniform_length, min_coat_ordinal_required)
VALUES
  ('teddy_bear',   'Teddy Bear',
   'Face left longer than the body; rounded, soft silhouette.',
   false, true, false, NULL),
  ('poodle_kennel','Poodle (Kennel Trim)',
   'Clean-shaved face, feet and tail base; short body; fuller neck and top knot.',
   false, true, false, NULL),
  ('lamb',         'Lamb',
   'Body shorter than legs. The contrast is vertical, not front-to-back.',
   false, true, false, NULL),
  ('kennel_puppy', 'Kennel / Puppy',
   'One length everywhere. The absence of a differential is the style.',
   false, true, true,  NULL),
  ('shaved',       'Shaved (remedial)',
   'Not a style. A response to coat condition.',
   true,  false, false, 4);

-- The one clamp that exists today. Expressed in inches so it also catches a
-- comb, which has no blade number to compare against.
INSERT INTO style_template_zone_clamp
  (style_template_id, body_zone_id, max_effective_length_in, rationale)
SELECT t.id, z.id, 0.062500,
       'A fluffy-faced Poodle trim is not a Poodle trim; face may not exceed #10.'
FROM style_template t
CROSS JOIN body_zone z
WHERE t.code = 'poodle_kennel' AND z.code IN ('face','muzzle_beard');

INSERT INTO retention_rule (entity_type, retain_months, anchor_field, action) VALUES
  ('vaccination_record', 36, 'expires_on',       'archive'),
  ('document',           36, 'uploaded_at',      'archive'),
  ('owner',              84, 'last_activity_at', 'purge'),
  ('audit_log',           0, 'occurred_at',      'retain_forever');

-- Pin search_path per function: trigger and helper functions otherwise
-- inherit the caller's, and every table reference here is unqualified.
ALTER FUNCTION expiry_warning_days() SET search_path = groom, public;
ALTER FUNCTION remedial_coat_ordinal() SET search_path = groom, public;
ALTER FUNCTION min_groom_age_weeks() SET search_path = groom, public;
ALTER FUNCTION derive_effective_length(cutting_tool, uuid, uuid) SET search_path = groom, public;
ALTER FUNCTION describe_tooling(cutting_tool, uuid, uuid) SET search_path = groom, public;
ALTER FUNCTION touch_updated_at() SET search_path = groom, public;
ALTER FUNCTION snapshot_cut_spec_zone() SET search_path = groom, public;
ALTER FUNCTION enforce_remedial_requires_assessment() SET search_path = groom, public;
ALTER FUNCTION enforce_uniform_length() SET search_path = groom, public;
ALTER FUNCTION enforce_cut_spec_requires_groom() SET search_path = groom, public;
ALTER FUNCTION flag_validity_plausibility() SET search_path = groom, public;
ALTER FUNCTION enforce_opt_out() SET search_path = groom, public;
ALTER FUNCTION enforce_template_clamp() SET search_path = groom, public;
ALTER FUNCTION enforce_min_groom_age() SET search_path = groom, public;
ALTER FUNCTION enforce_tier_shape() SET search_path = groom, public;
ALTER FUNCTION reject_audit_mutation() SET search_path = groom, public;
ALTER FUNCTION resolve_cut_spec_zones(uuid) SET search_path = groom, public;
ALTER FUNCTION refresh_dog_vaccine_compliance(uuid) SET search_path = groom, public;
ALTER FUNCTION refresh_all_compliance() SET search_path = groom, public;
ALTER FUNCTION trg_refresh_compliance() SET search_path = groom, public;
ALTER FUNCTION trg_seed_compliance() SET search_path = groom, public;