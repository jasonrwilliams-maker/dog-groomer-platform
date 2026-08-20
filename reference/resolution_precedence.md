# Resolution Precedence and Enforced Invariants

This document is normative. The DDL header references it, and the expansion
function implements it exactly.

---

## 1. Cut specification resolution

Applying a style to a dog produces a full set of `cut_spec_zone` rows. Every zone is
resolved independently, and the first rule that matches wins.

**Precedence, highest to lowest:**

1. **`profile_zone_override`** — a saved, dog-specific deviation.
   *"Luna's ears are always scissored."*
2. **`style_template_zone_spec`** — the `(template, tier, zone)` row for tiered
   templates, or the `(template, min_coat_ordinal, zone)` row for remedial ones
   (most severe threshold met wins).
   *"Teddy Bear Medium puts a #4F on the body."*
3. **`zone_default`** — the hygiene invariant.
   *"Sanitary is always a #10, regardless of style."*
4. **Unresolved** — zone omitted from the cut spec. Not an error; not every style
   touches every zone. **Absence is not a gap**: a template with no `face` row
   means the head pass covers the face, not that the face is unspecified. Zones
   in the hierarchy do not inherit from their parents — a child zone that needs
   its own instruction gets its own row (ears vs. ear tips).

A **visit-time ad hoc edit** sits above all four. It writes directly to
`cut_spec_zone` with `resolved_from = 'ad_hoc'` and survives re-expansion; it does
not modify the profile. Distinguishing "this once" from "from now on" is a
deliberate UI decision — the app should ask, and offer to promote the edit into
the profile.

### Vocabulary

- **Short form (configuration)** — how a haircut is *stored*: a shop-wide template,
  a tier, and a sparse set of dog-specific overrides. Two or three rows.
- **Long form (history)** — how a haircut is *recorded*: one fully resolved row per
  zone, lengths frozen.
- **Expansion** — `resolve_cut_spec_zones()`, the step that turns short form into
  long form by walking the ladder above. Runs one direction only.
- **Seed time** — configuring a template. Shop-wide, dog-agnostic.
- **Expansion time** — recording a haircut. Where invariants needing the complete
  resolved set are evaluated.

### Template clamps

Some templates constrain a zone regardless of tier, because the constraint *is* the
style. Poodle's face may not exceed `#10` even at Long — a fluffy-faced Poodle trim is
not a Poodle trim.

Clamps live in `style_template_zone_clamp`, keyed on `(template, zone)` — not on
the per-tier spec row, because a clamp exists precisely to survive the tier
shift, and per-tier storage would let the three tiers disagree about it. Bounds
are expressed in **inches of effective length, not blade numbers**: blade numbers
run backwards, and a comb has no blade number at all, so a blade-number clamp
cannot see `#30 + 1" comb` — exactly the configuration that would sneak a fluffy
face onto a Poodle at the Long tier.

Enforcement is split by when the data is written:

- **Seed time (template configuration): block.** A trigger on
  `style_template_zone_spec` rejects a template row that violates its own clamp
  (`GR006`). A template may not be configured out of its identity.
- **Haircut time (profile overrides, ad hoc edits): flag.** A profile override
  *may* violate a clamp — she is the professional, and the system records what
  she did rather than refusing it. The expansion sets
  `cut_spec_zone.clamp_violated = true`; the UI surfaces it; nothing blocks and
  nothing is silently rewritten.

### Effective length

`effective_length_in` is derived, never entered:

```
if tool in ('scissors','hand_strip') -> NULL   (length is not specified by tool)
elif comb_id IS NOT NULL             -> comb.length_in
else                                 -> blade.length_in
```

The comb always wins. A `#30` under a 1" comb cuts at 1", and the underlying blade
number is an implementation detail of how combs work.

On configuration rows (`style_template_zone_spec`) the length is a **view column**,
derived live. On history rows (`cut_spec_zone`) it is a **frozen snapshot**, written
at insert: correcting `blade.length_in` next year must not silently rewrite what
happened in March. Configuration is live; history is a snapshot.

A genuine correction to the haircut row itself — she used a `#7F`, not a `#4F` —
*does* recompute. The row is frozen against reference-data drift, not against
being fixed.

---

## 2. Compliance state resolution

### Which vaccines set state

A vaccine is **tracked** when `regulatory_required` (the law says so) or
`required_by_policy` (the shop says so) is true. Rabies is required by Maryland
law; DHPP and Bordetella are shop policy; leptospirosis is neither, and is
recorded if a document mentions it but never sets compliance state.

The two flags stay separate because they answer different questions. Only
`regulatory_required` belongs in a health-department packet; `required_by_policy`
is what the shop chases.

### Two layers, so the calendar can never make the data stale

- **`dog_vaccine_compliance`** (table), keyed `(dog_id, vaccine_type_id)`, is a
  maintained projection holding only **date-independent facts**: which record
  governs, when it expires, its verification status, whether a request is open.
  These change only on write, so write-triggered refresh keeps them exact. Its id
  columns are deliberately not foreign keys — a projection rebuilt from source on
  every write must not race its own refresh trigger via `ON DELETE SET NULL`.
- **`v_dog_vaccine_compliance`** (view) computes the state ladder **at read time**
  from those facts plus `CURRENT_DATE` and the dog's date of birth. There is no
  nightly rollover job because there is nothing to roll over: `expired`,
  `expiring_soon` and `not_yet_due` are all functions of today, evaluated today.

The detail view drives `FROM dog CROSS JOIN tracked vaccines`, so **every active
dog is evaluated against every tracked vaccine, including dogs with no records at
all** — that absence is the finding, not a null to be filtered out, and it is
structural rather than a promise a refresh job has to keep.
`v_dog_vaccine_compliance_recompute` recomputes the projection live from source;
the test suite asserts the two agree, so any refresh-trigger bug is a failing test
rather than a quietly wrong dashboard.

### Precedence, highest to lowest

Evaluated per dog **per tracked vaccine**:

1. **`disputed_record`** — the governing record has
   `verification_status = 'disputed'`. Outranks the date checks: if the record
   itself is contested, its expiry date is not something to schedule against.
2. **`expired`** — a record exists and `expires_on < today`
3. **`expiring_soon`** — `expires_on` within `expiry_warning_days()` (30)
4. **`received_unverified`** — a record exists, `verification_status = 'unverified'`
5. **`current`** — verified and unexpired
6. **`not_yet_due`** — no record, and the dog is younger than the vaccine's
   `min_age_weeks`. Maryland requires rabies by 16 weeks; a 10-week-old puppy is
   not non-compliant, and chasing its owner is a false alarm rather than
   diligence. **An unknown birth date gets no grace period** — a rescue with a
   blank date of birth is treated as needing the vaccine normally.
7. **`requested_pending`** — no record, but an open `record_request`
   (`status IN ('queued','sent')`)
8. **`no_record`** — no record and no open request

`expired` outranks `requested_pending`: a dog with a lapsed certificate and a
request already out is still expired today. The request is progress, not
compliance.

`min_age_weeks` is per vaccine, not a single constant. A ten-week-old puppy reads
`not_yet_due` for rabies (16 weeks) and `no_record` for DHPP (8 weeks) in the same
view at the same moment, and both are correct.

### Rolling up to the dog

`v_dog_compliance_status` gives one row per dog and performs **two different
aggregations**, which must not be collapsed into one:

- **`state`** — the worst state across every tracked vaccine, ranked by
  `compliance_state_meta.sort_order`. A dog whose rabies is current but whose
  Bordetella is missing is not a compliant dog.
- **`blocks_service`** — true only where the worst state is service-blocking *and*
  the vaccine itself carries `blocks_service_if_expired`. An expired Bordetella
  shows red on the dashboard without cancelling the appointment.

Whether a given vaccine can stop an appointment is therefore per-vaccine
configuration, not a global policy decision. Today only rabies carries it.

### Records and requests

Where multiple records exist for the same dog and vaccine, the one with the latest
`expires_on` governs — latest expiry, not latest `created_at`, so a backfilled old
certificate cannot displace a current one. Superseded records are retained; the
retention rule anchors on `expires_on` rather than record age.

A request answered with a document that cannot produce a record (no expiry on the
page) moves to `status = 'insufficient'` — the owner responded, so the request must
not auto-resolve, and must not keep reminding as if they hadn't.

At most one request may be open per `(dog, vaccine_type)`, enforced by a partial
unique index, so "the open request" is unambiguous.

**Outreach is batched at delivery, not at storage.** Three missing vaccines produce
three `record_request` rows — that granularity is needed to track which vaccine is
outstanding and how many times each has been asked about — but the send layer
groups them into one message per owner and writes the shared
`provider_message_id` onto each resulting `record_request_event`. The reverse
choice would make "asked twice about rabies, once about Bordetella"
unrepresentable.

---

## 3. Invariants that CANNOT be CHECK constraints

Postgres `CHECK` constraints are row-local. Each of these spans rows or tables and
needs a trigger, with tests. Numbering matches the trigger comments in the DDL;
each rule raises its own SQLSTATE so tests assert on a stable identifier rather
than on prose, and the API layer maps codes to user-facing messages without
matching strings.

| Code | Rule |
|---|---|
| `GR001` | Remedial cut requires a qualifying coat assessment |
| `GR002` | Approved remedial override must state the coat level |
| `GR003` | Uniform-length template must resolve to one length |
| `GR004` | Cut specification requires a groom service |
| `GR005` | No email reminder to an owner who opted out |
| `GR006` | Template zone spec may not violate its clamp |
| `GR007` | Unknown style template |
| `GR008` | Remedial template cannot be a standing profile |
| `GR009` | Tiered template requires a length tier |
| `GR010` | Non-tiered template must not have one |
| `GR011` | Haircut under the minimum grooming age without an approved reason |

Every `RAISE` carries a `HINT` written for a groomer rather than a developer. The
application should surface the hint, not the message.

### 3.1 Remedial shave requires a coat assessment — `GR001`, `GR002`

**Rule:** applying a template with `is_remedial = true` requires a `coat_assessment`
on the same visit with `condition_ordinal >= min_coat_ordinal_required` (4), OR a
non-null `remedial_override_reason` with manager approval (`approved_by`,
`approved_at` — coherence enforced by CHECK).

**The override must still state `coat_ordinal_applied`** (`GR002`). The expansion
keys remedial template rows on coat severity; an approved override without a coat
level would expand to hygiene zones only — a record of nothing, on exactly the
row that exists to be read back in the difficult conversation.

**Why not CHECK:** the assessment lives on a different table, keyed by visit.

**Why it matters:** this is the record that protects her in the "you shaved my
dog" conversation. The refusal is the feature.

### 3.2 Uniform-length templates resolve uniformly — `GR003`

**Rule:** for a template flagged `requires_uniform_length` (Kennel/Puppy), all
resolved `cut_spec_zone` rows **with `resolved_from = 'template'`** must share one
`effective_length_in`.

Zones from `zone_default` are excluded (hygiene cuts are not style), and so are
`profile_override` and `ad_hoc` rows: a groomer deviating from uniformity is the
groomer's call, recorded not blocked — the same reasoning that flags rather than
blocks a clamp violation. The invariant therefore means "the template
configuration must resolve uniform," which is what the style identity requires.

**Why not CHECK:** compares sibling rows within a set. The full set does not exist
until the expansion produces it, which is why this is checked at expansion time
and the clamp is checked at seed time — a clamp is answerable against a single
row.

**Enforcement:** deferred constraint trigger, so the full zone set is visible at
commit.

### 3.3 Tool and blade coherence

**Rule:** `tool = 'scissors'` or `'hand_strip'` implies `blade_id IS NULL AND
comb_id IS NULL`. `tool = 'clipper'` implies `blade_id IS NOT NULL`. A comb
requires a blade.

**This one genuinely is a CHECK** — single-row, no lookups — and it is repeated
verbatim on all three tables that carry a tool triple.

### 3.4 Cut spec requires a groom service — `GR004`

**Rule:** a `cut_specification` may exist only if its visit has a `visit_service`
whose `service_type.carries_cut_spec = true`.

**Why not CHECK:** cross-table. Deferred, because the spec and the service rows
arrive in one transaction and the order is the application's business.

This is the invariant the bath-only synthetic dogs exercise.

### 3.5 Vaccine validity plausibility

**Rule:** the implied validity (from `administered_on` to `expires_on`) falling
outside the vaccine type's plausible range sets `validity_implausible = true`.

**Not a constraint at all — a flag.** Both 1-year and 3-year rabies are legal, and
the clinic decides. The document is authoritative. If the certificate says
something unusual, the certificate is still what the health department will see,
so the system records it and flags it for a human. **Never derive `expires_on`** —
a record whose expiry is unknown does not become a record at all; the document
and its extraction stay as evidence and the dog stays non-compliant.

### 3.6 Reminder cap and opt-out — `GR005`

**Rule:** `reminder_count <= max_reminders` (CHECK), and no email send when
`owner.email_opted_out = true` (trigger — reads another table). Opting out is
about the channel, not the person: asking at the counter is still allowed.

### 3.7 Tier shape coherence — `GR009`, `GR010`, `GR008`

**Rule:** a `cut_specification` or `dog_style_profile` on a template with
`supports_tiers = true` must carry a `length_tier_id`; on a template with
`supports_tiers = false` it must not. A remedial template may not be saved as a
profile at all — Shaved is a response to coat condition, not a standing
preference.

**Why not CHECK:** reads `style_template`.

**Why it matters:** a tiered cut spec with no tier matches no template rows, so
the visit silently records hygiene zones only — the same structurally-empty-
haircut failure 3.1's override clause closes on the remedial side.

### 3.8 Minimum grooming age — `GR011`

**Rule:** a `cut_specification` for a dog younger than `min_groom_age_weeks()` (16)
at the visit date requires a non-null `under_age_override_reason` with manager
approval. A dog with an unknown date of birth is not treated as under age.

**A flag, not a hard block.** The reason is required, but the visit is still
recorded. A hard age block belongs in customer-facing booking software; a system
of record that refuses to record what actually happened is worse than useless.

**Scope:** cut specifications only. A bath for a ten-week-old puppy is unaffected,
because it is haircuts that are being restricted, not the dog's presence in the
shop.

**Why not CHECK:** the date of birth is two tables away, via `visit`.

Note this is the first rule that is neither law nor style identity but shop
policy, which is why the threshold lives in a function rather than a literal.

---

## 4. Testing note

Every invariant above needs a test that asserts the *rejection*, not just the happy
path. A trigger nobody has seen fire is an assumption. The test suite proving these
rules hold is a more convincing artifact than the schema itself, and it is the
natural place to point a reviewer who asks how the business rules are enforced.

Pair every rejection with the valid case. A rule that rejects *everything* also
passes a rejection test; `lives_ok` on the legitimate version is what proves the
rule discriminates rather than merely fires.

Two equivalence tests belong alongside the rejections: `dog_vaccine_compliance`
equals `v_dog_vaccine_compliance_recompute` after any write sequence, and
re-running `resolve_cut_spec_zones` is idempotent for non-ad-hoc rows.

Two of these invariants (3.2 and 3.4) are deferred constraint triggers that fire
at `COMMIT`. Since every test file rolls back, a test file must issue
`SET CONSTRAINTS ALL IMMEDIATE` or those rules will pass by never running — which
is worse than failing.

Current coverage: 11 files, 76 assertions, all passing.