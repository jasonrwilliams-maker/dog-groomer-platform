# Dog Grooming Platform

A system of record for a small grooming practice, with the business rules
enforced **in the database** rather than in the application.

Fourteen numbered rules, each with a dedicated error code, each proven by a test
that asserts the *refusal* — not the happy path. 135 assertions, all passing.
How strictly each groom-time rule is enforced (block, warn, or off) is itself a
row of data, changed by `UPDATE` and recorded in the audit log — not a migration.

---

## Why this is not a reporting project

Most analytics work describes data that some other system produced. If a row is
wrong, that is upstream's problem.

This system is first in the chain. Nothing upstream will catch a bad row, so every
rule a human would otherwise apply by judgment has to be written down as something
the database will refuse:

- A shave-down cannot be recorded without a coat assessment that justifies it
- A haircut cannot be recorded on a bath-only visit
- A reminder email cannot be sent to an owner who opted out
- A vaccination record cannot be created from a document that does not state an
  expiry date

That last one is the design decision the rest of the project is organized around.

### The document that proves the point

A real vet invoice for one of the dogs names a rabies vaccination and the date it
was given. It contains no expiry date anywhere on the page.

The system ingests it, retains the document, retains the extraction — and creates
no vaccination record. The dog stays non-compliant. It does not infer a one-year
or three-year validity, because both are legal and the certificate is what the
health department will actually see.

A pipeline that correctly declines to invent a date is a better artifact than one
that extracts cleanly. Anyone can demo a clean extraction.

---

## Status

| Component | State |
|---|---|
| Schema | Frozen — sections 0–14 in one file; sections 15–16 follow as separate files |
| Business rules | 14, codes `GR001`–`GR014` |
| Test suite | 14 files, 135 pgTAP assertions, passing |
| Document vocabulary (§15) | 29 rulings seeded from the labelled corpus; `resolve_term()` fails closed |
| Extraction line items (§16) | One row per printed line; review views; the shape the harness loads |
| Extraction harness | Built — scores a model run against the answer keys; self-check passing |
| First model run | Not yet made — needs an API key in `.env` |
| Seed migration | Not started — ~150 template × tier × zone rows |
| API / frontend | Not started |

---

## Running it

Requires Docker Desktop.

```bash
docker compose up -d --build --wait
docker compose exec db psql -U postgres -d grooming_test -v ON_ERROR_STOP=1 -f sql/grooming_platform_schema.sql
docker compose exec db psql -U postgres -d grooming_test -v ON_ERROR_STOP=1 -f sql/15_document_term.sql
docker compose exec db psql -U postgres -d grooming_test -v ON_ERROR_STOP=1 -f sql/16_extraction_line_item.sql
docker compose exec db psql -U postgres -d grooming_test -f sql/seed/fixture.sql
docker compose exec db pg_prove -U postgres -d grooming_test tests/*.sql
```

Expected: `Files=14, Tests=135, Result: PASS`.

The SQL loads in section order. `grooming_platform_schema.sql` is sections 0–14;
each later section is its own numbered file, and a file's header carries the
same number. Tests are numbered independently, one file per rule family.

The extraction harness runs as a second container, on demand:

```bash
docker compose run --rm harness selfcheck
```

See [`extraction/harness/README.md`](extraction/harness/README.md) for the
rest — a model run needs an API key in `.env`.

`--wait` blocks until Postgres reports healthy. Without it the schema load races
container startup.

To reset: `docker compose down -v` and start again. The `-v` removes the data
volume, which is what lets the pgTAP init script run on the next start.

---

## What the schema models

Four subsystems, loosely coupled on purpose — a haircut record should not depend
on whether someone answered an email.

**Core** — owners, dogs, groomers, visits, services, coat assessments.

**Styling** — how a haircut is described and recorded. A style is stored in *short
form* (a shop-wide template, a length tier, and a sparse set of dog-specific
overrides) and recorded in *long form* (one fully resolved row per body zone, with
lengths frozen at the moment of the cut). The step between them walks a four-level
precedence ladder.

**Compliance** — documents, LLM extractions and their line items, the document
vocabulary that resolves a printed term to a vaccine, vaccination records, record
requests, and a per-dog-per-vaccine projection of compliance state.

**Governance** — an append-only audit log and retention rules.

Entity-relationship diagrams are in [`reference/`](reference/); the normative
specification is [`reference/resolution_precedence.md`](reference/resolution_precedence.md).
The extraction subsystem — its ingestion flow, the answer-key contract that
governs its labelled evaluation set, the four keys, and the harness that scores a
model run against them — is in [`extraction/`](extraction/).

---

## Business rules

| Code | Rule |
|---|---|
| `GR001` | A remedial cut requires a coat assessment at level 4 or higher |
| `GR002` | An approved remedial override must still state the coat level applied |
| `GR003` | A uniform-length template must resolve to a single length |
| `GR004` | A cut specification requires a service that carries one |
| `GR005` | No email reminder to an owner who has opted out |
| `GR006` | A template zone spec may not violate its own clamp |
| `GR007` | Unknown style template |
| `GR008` | A remedial template cannot be saved as a standing style profile |
| `GR009` | A tiered template requires a length tier |
| `GR010` | A non-tiered template must not carry one |
| `GR011` | A haircut under the minimum grooming age needs an approved reason |
| `GR012` | A regulatory vaccine rule does not appear, change, or disappear without a stated reason |
| `GR013` | A missing or mistyped `shop_policy` key fails loudly, never as NULL |
| `GR014` | `shop_policy` rows are updated, never deleted |

Each raises its own SQLSTATE so tests assert on a stable identifier rather than on
error prose, and the API layer can map codes to user-facing messages without
string matching. Every raise carries a `HINT` written for a groomer rather than a
developer.

Whether a groom-time rule blocks, warns, or is off is a row in
`policy_enforcement`, keyed by error code. `warn` records the violation in the
audit log and lets the row land. Codes whose relaxation would corrupt the data
(the remedial and tier-shape rules, whose values feed the zone expansion) or
break the law (the email opt-out) are pinned to `block` by a CHECK constraint.

---

## Testing

A rule that works produces nothing to look at. There is no screen showing the
haircut that was correctly refused, so if a trigger silently stopped firing, every
dashboard would look identical and the problem would surface months later as bad
data.

The only way to know a rule works is to try to break it and confirm you were
stopped. Every rejection test is paired with the valid case — a rule that rejects
*everything* also passes a rejection test.

| File | Proves |
|---|---|
| `01` | Shave-down refused at coat level 2, accepted at level 5 |
| `02` | Tierless template refused; a remedial template cannot be a profile |
| `03` | Email to an opted-out owner refused; asking at the counter still works |
| `04` | A vet invoice with no expiry date produces no vaccination record |
| `05` | The four-level precedence ladder; a comb overrides its blade |
| `06` | Clamps block at configuration time, flag at haircut time |
| `07` | History frozen against reference drift, not against correction |
| `08` | The compliance projection equals a live recompute after every write |
| `09` | Eight compliance states and their precedence; worst state wins per dog |
| `10` | Remaining invariants, audit immutability, no expected trigger missing |
| `11` | Puppy rules — `not_yet_due` compliance and minimum grooming age |
| `12` | Policy is data: loud failure on a missing key, labels that track the live window, block/warn/off per rule, and the regulatory-change audit trail |
| `13` | The vocabulary fails closed: typography collapses, cadence words do not; NULL is a ruling; tracking is configuration, not vocabulary |
| `14` | A line item is a row and its fields stay fields; the review queue empties itself; a corrected term is looked up by its correction; a tracked vaccine with one date still creates nothing |

---

## Design decisions

**Configuration is live; history is a snapshot.** Template lengths are derived in a
view. Recorded haircuts freeze theirs at insert. Correcting a blade's length next
year must not silently rewrite what happened in March — but correcting the haircut
row itself *does* recompute. Frozen against drift, not against being fixed.

**Clamps are expressed in inches, not blade numbers.** Blade numbers run backwards
(a #30 is shorter than a #3) and a comb has no blade number at all, so a
blade-number clamp cannot constrain "#30 under a 1-inch comb" — exactly the
configuration that would put a fluffy face on a Poodle trim.

**Some rules block, others flag.** A template may not be *configured* outside its
own identity. A groomer overriding that on a specific dog is recorded and flagged,
never refused — she is the professional, and a system of record that refuses to
record what happened is worse than useless.

**Compliance state is computed at read time.** The projection stores only
date-independent facts; the view applies today's date. There is no nightly rollover
job because there is nothing to roll over, and therefore nothing that can go stale.

**Every active dog appears on the dashboard.** The view drives from `dog`, so a dog
with no paperwork is a finding rather than a missing row.

**`expires_on` is never derived.** See above.

**The model transcribes; the database classifies.** The vision model emits every
printed line verbatim and never sees the vocabulary. Mapping `DHPP 3YR W/ LEPTO`
to a vaccine is a lookup against `document_term`, a table a human maintains one
ruling at a time. A term with no row fails closed to a review queue; a term ruled
"not a vaccine" is a row with a NULL, which is a different fact from no row at all.
The alternative — a prompt that enumerates synonyms — is a parser that has to be
re-edited for every practice, with no audit trail.

**A line item is a row; its fields are still fields.** `extraction_line_item`
holds position and provenance; the values live in `extraction_field` keyed by
line item, so `correction_action` stays per field. The hallucination case on
this corpus is one invented `expires_on` on one row, and a per-row review state
would score that as a bad row and lose which field it was.

---

## Roadmap

1. **First model run.** Put an API key in `.env`, `docker compose run --rm
   harness run`, and read the score. The prompt is `extraction/harness/prompt_v1.md`;
   iterate on it against the four answer keys, not against vibes. Four
   documents is a small evaluation set — the next most valuable labelling
   work is a photographed page under bad light, which the corpus lacks.
2. Layer 3 — the confirmation step. A function that takes a reviewed extraction
   and writes `vaccination_record` rows for exactly the line items where
   `v_extraction_line_item.can_create_record` is true, and opens a
   `record_request` marked `insufficient` for a document that produced none.
3. Seed migration — the template × tier × zone mapping
4. FastAPI backend, with the review screen reading `v_extraction_line_item`
5. Next.js / React / Tailwind / shadcn frontend

The extraction schema is shaped for honest measurement: raw model responses
stored unmodified, model and prompt versions as columns, and a per-field
`correction_action` that distinguishes *unreviewed* from *confirmed* and carves out
*removed* for values the model produced that are not on the document. Without that
last state, false positives disappear from error analysis and quietly inflate
measured accuracy. The harness scores the same three ways the keys assert —
expected, absent, must-not-produce — and reports the hallucination class
(*spurious*) as its own column rather than folding it into accuracy.

---

## Disclosure

All owners, dogs, and visit data in this repository are synthetic. The real
documents used to develop and test the extraction logic contain personal
information and are deliberately excluded from version control: they live in
`private/`, which is gitignored as a directory rather than by file extension.

The answer keys in `extraction/answer_keys/` are anonymised at labelling time —
owner names, addresses, phone numbers, patient names, microchip and tag numbers
are substituted, while clinical facts (dates, lot numbers, product names) are
kept verbatim so a key can still be checked against its page. Household
structure is preserved: two households have two surnames.

---

## Built with

PostgreSQL 16 · pgTAP · Docker