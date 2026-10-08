# Dog Grooming Platform

[![tests](https://github.com/jasonrwilliams-maker/dog-groomer-platform/actions/workflows/tests.yml/badge.svg)](https://github.com/jasonrwilliams-maker/dog-groomer-platform/actions/workflows/tests.yml)

A system of record for a small grooming practice, with the business rules
enforced **in the database** rather than in the application.

Thirty-two numbered rules, each with a dedicated error code, each proven by a test
that asserts the *refusal* — not the happy path. 440 assertions, all passing.
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

A real vet invoice for Jaddi, the dog whose grooming routine started this
project, names a rabies vaccination and the date it was given. It contains no
expiry date anywhere on the page.

The system ingests it, retains the document, retains the extraction — and creates
no vaccination record. The dog stays non-compliant. It does not infer a one-year
or three-year validity, because both are legal and the certificate is what the
health department will actually see.

A pipeline that correctly declines to invent a date is a better artifact than one
that extracts cleanly. Anyone can demo a clean extraction.

### What the model actually did

Every model run so far, re-scored against today's answer keys. One ruler for
every row (`r-5e0c74e1fcba`), so the rows can be compared with each other.
*Overconfident* means a character the page prints but no one can read, returned
as a clean, specific value: a smudged `Jan 2?, 2027` read back as `Jan 29, 2027`.

| Run | Prompt | Documents | Fields correct | Wrong | Missed | Invented | Overconfident |
|---|---|---|---|---|---|---|---|
| 2026-09-22 | v1 | 3 clean PDFs + 1 screenshot | 501 / 504 | 1 | 1 | 1 | 0 |
| 2026-09-22 | v2 | 3 clean PDFs + 1 screenshot | **492 / 492** | 0 | 0 | 0 | 0 |
| 2026-09-24 | v2 | phone photo, held out | 141 / 159 | 2 | 0 | 2 | 14 |
| 2026-09-25 | v2 | phone photo | 141 / 159 | 2 | 0 | 2 | 14 |
| 2026-09-25 | v3 | phone photo | 141 / 159 | 3 | 0 | 2 | 13 |

*Plus one 2026-09-24 photo run whose response did not parse, scored as nothing.*

On clean pages the model transcribes perfectly. On a phone photo of the same
kind of page it makes the same mistake every time, whatever the prompt:
**about fifteen confident dates the page does not support**, out of 159
fields. A third prompt did not fix it. (The photo's saved scores once read
16, then 6, then 2 invented values; that drop was the answer key learning to
mark partly readable characters, not the model improving. Scored by one
ruler, the runs are the same.)

That is why the database does not trust a date for being present. A line
becomes a vaccination record only after a person has checked every field it
carries, and a reviewer who can't read a date says so, which asks the owner
for a better copy instead of recording a guess.

---

## Status

| Component | State |
|---|---|
| Schema | Sections 0–14 stable, in one file; later sections appended as separate files (15–31) |
| Business rules | 32, codes `GR001`–`GR032` |
| Test suite | 27 files, 440 pgTAP assertions, passing; 26 API tests |
| Document vocabulary (§15) | 29 rulings seeded from the labelled corpus; `resolve_term()` fails closed |
| Extraction line items (§16) | One row per printed line; review views; the shape the harness loads |
| Confirmation — Layer 3 (§18) | `confirm_extraction()` turns a fully reviewed page into verified records, records every line's outcome, and asks the owner for what the page is missing |
| Confirm screen | The review tool's **Confirm** screen: a groomer checks each tracked field against the page (matches / says something else / made up / can't read it), rules on unfamiliar vaccine names, and confirms. Refusals show the database's own groomer-facing hint |
| Owner outreach (§19) | Opt-in consent per channel, kept as a history; one message per owner per dog naming every certificate needed; spaced, capped reminders; an outbox and a sender. **Test mode**: nothing is delivered yet — a real email or text provider plugs into `extraction/review/outreach.py` |
| Check-in (§20) | `start_visit()` opens a groom and refuses (GR020) while a service-blocking vaccine is expired, missing, disputed or still being chased. Past visits can still be recorded as history |
| Style templates (§21) | 148 rows from `reference/style_tier_mapping.md`: four styles at three lengths, plus the shave-down at coat levels 4 and 5. Tests check each style's identity (a Teddy Bear head stays longer than the body; a Poodle face stays shaved; Kennel is one length), not a copy of the rows. Every style edit is recorded in the audit log, before and after |
| Walk-ins (§22) | `add_client()`, `add_dog()` and `record_counter_shot()`: a new client and dog added at the counter, and the shots on their paper typed in as unverified records, which are fit to groom until a manager verifies them. No expiry on the paper, no record (GR021); a shot that disagrees with one on file is left for a manager (GR022). `update_client()` and `update_dog()` put a typo right and record each changed field before and after. A dog can be a mix: its main breed, and the other one if the owner knows it |
| Breed list (§23) | 199 breeds, each with the coat it usually has, in `sql/23_breed_seed.sql`, the one file to edit to change the list; safe to run again. A breed not on the list is refused with the nearest names ("Did you mean Shih Tzu?") unless the groomer says it is new (GR023) |
| Allergies and handling (§24) | Groomers add, change and take off a dog's allergies from the card, picked from a list grouped by what each changes for the groom (contact, flea, environmental, food), with "did you mean" (GR024). Anything that leaves the dog less protected, an allergy taken off or made less severe, needs a reason (GR025) and goes on the manager's list; only a manager clears it (GR026). An allergy taken off is kept, marked removed. Handling notes stay a dated history: new notes are added, typos corrected, and a note can say which side (front or back feet and paw pads, left or right ear) |
| Allergen list (§25) | 45 allergens in `sql/25_allergen_seed.sql`, the one file to edit to change the list; safe to run again |
| Paperwork at the counter (§26) | The owner's paperwork, as many photos and files as it takes (tablet camera or webcam, or the PDFs they emailed), is kept as one copy with numbered pages; a blurry page is removed or retaken before saving, and a saved copy nobody checked a shot against can lose a bad page or be removed outright (GR029 refuses once a record rests on it). Each photo is turned upright, stripped of the camera's details and GPS, downsized if large, saved under `private/counter/`, and kept with the dog (`receive_paperwork()`). Then the groomer checks it now or leaves it for later. Shots typed in while reading the photo (`record_checked_shot()`) are verified straight away and marked **checked by hand**; without a photo on file for that dog they are refused (GR027). Each groomer's hand check waits on the manager's list for a second look against its photo, which only a manager gives (GR028). Copies left for later wait on the manager's list under "Paperwork to check". A vaccine the paperwork doesn't show is marked "Not on their paperwork" (`ask_owner_at_counter()`): recorded as asked for at the counter, and followed up by the shop's reminders, so a walk-in can be saved with whatever they brought |
| AI suggestions (§27) | On the check screen, **Have the AI read it** sends the copy to the model the harness uses, with the harness's prompt, and fills the date form in; every date is labelled "AI filled this in", and one the page prints as less than a full date is flagged to check closely. A vaccine name the shop has never seen is asked about once ("which vaccine is this?") and joins the vocabulary. The person still checks and saves, so the record is checked by hand under their name. What they save grades the AI field by field (right, read wrong, missed, made up), in the same review columns the records tool writes, and the Admin view's **How the AI is doing** shows the score on the shop's own paperwork, PDFs and photos apart. Counter readings are not offered on the records tool's Confirm screen |
| Manager fixes (§28) | On the Admin view, a manager **verifies** a shot typed in with no photo (`verify_counter_shot()`), saying how they checked it (saw the owner's paper, called the vet), which is kept on the record; and when a hand-checked shot doesn't match its photo, **fixes** its dates (`correct_counter_shot()`), which counts as its second look; the card still names who checked it by hand, and now who fixed it. If the AI had read that copy, its grade for those dates is redone against the manager's, so a wrong date the groomer accepted counts against the AI. A shot verified some other way goes back to waiting when its dates change. Fixed dates keep the counter's rules (GR021, GR022); the groomer's dates stay in the audit log, before and after. Only a manager does either (GR030). A record read in the records tool is fixed there |
| Calendar (§29) | A **Calendar** tab for every groomer: a month of grooms that happened (who groomed, the note) and the day each dog's vaccines expire, the ones that stop a groom (rabies) in red (`v_calendar_event`). Show or hide grooms and expiries; focus it on one dog (a drop-down of every dog and owner, narrowed by typing) to list its dates and jump to any of them, starting at its last groom. A dog's card has **See on the calendar**. Bookings show too (see §30) |
| Booking ahead (§30) | Anyone books a groom from a dog's card (**Book a groom**) or the calendar: service, length (each service has a usual length, a full groom 1 hr 30 min; tick "Set a different length" for anything up to the whole day), day, groomer and one of their free start times, within the shop's hours (`shop_opens`, `shop_closes`). The form shows the dog's breed, age, coat, owner and phone. The dog's **usual groomer** (whoever groomed it last) is offered first, then whoever is signed in; booking a regular client with someone else asks why, and the reason is kept (GR032). Nobody is booked twice at once, groomer or dog (GR031, backed by an exclusion constraint). Vaccines that will be out of date by the day are a warning, not a refusal; check-in still decides on the day. The calendar shows bookings, and the day's timeline is the signed-in groomer's day first, the team below; a booking can be changed or cancelled (reason kept). A green check beside a dog's name, on the dog list, card, calendar and booking form, means every vaccine is current and verified (`vaccines_all_current()`): stricter than cleared to groom |
| Dog photos (§31) | Each dog can have one profile photo, added from its card (**Add photo**: take one with the tablet camera or webcam, or choose one), changed or removed. Turned upright, stripped of the camera's details and GPS, and kept in three sizes under `private/dogs/` (`set_dog_photo()`, `remove_dog_photo()`); a new photo replaces the old and its files are deleted. Shown on the card, the booking form, the dog list and the dog pickers; a drawn placeholder until one is added |
| Groomer interface | `web/` (Next.js + Tailwind, shadcn-style components) on a thin FastAPI backend (`api/`), on its own demo database, `grooming_demo`. Three tabs. **Check-in**: pick who's grooming, find a dog by its name or its owner's (photo, green check when every vaccine is current), see whether today's groom can start and why not, allergies and handling notes; start the groom; book one; sign up a walk-in and photograph the paperwork they brought, then check it now (with **Have the AI read it**) or leave it for a manager; add the dog's photo; put right a typo. **Calendar** (everyone): grooms, bookings and vaccine expiries by month, a day's timeline by groomer, focus on one dog, book, change or cancel. **Admin** (managers): an overview of count cards, each opening its own screen: dogs on the books, cleared to groom, can't groom, expired, no paperwork, expiring soon; and the to-do list in the shop's amber: shots waiting to be verified, paperwork to check, shots checked by hand to look over, allergy changes to review. Also how the AI is doing, and the way into the records tool |
| Extraction harness | Built — scores a model run against the answer keys; self-check passing |
| Photo preparation | Built — a photo is turned upright, stripped of EXIF and GPS, and downscaled before it is sent |
| Labelling & review tool | Built — Streamlit; writes answer keys from a form, and reconciles a run against its key |
| Model runs | Six: two of the four-document corpus (2026-09-22) and four of the held-out phone photo (2026-09-24 to 25). Results under *What the model actually did*, above |

---

## Running it

Requires Docker Desktop, and a `.env` copied from `.env.example`.

```bash
docker compose up -d --build --wait
```

That starts the database and three apps, all on this machine only:

| | |
|---|---|
| **http://localhost:3000** | The groomer interface: the check-in screen, and (for managers) Admin and the records tool |
| http://localhost:8000/docs | Its backend's endpoints |
| http://localhost:8501 | The labelling and review tool |

The groomer interface runs on its own database, `grooming_demo`: the schema and
eleven demo dogs (`sql/seed/demo.sql`), built on first start. Jaddi is the real
one. The pgTAP suite never sees it.

The labelling and review tool has everything else on one page:

- **Instructions** — the whole workflow, step by step.
- **Documents** — what is in `private/`, and where each one stands.
- **Label** — write a document's answer key from a form beside the page.
- **Review** — a model run against its key, one disagreement at a time.
- **Confirm** — what a groomer does in production: check the model's reading
  against the page, then turn the page into the dog's vaccination records.
- **Outreach** — record whether an owner agreed to email or texts, send what
  is due, read the outbox, and see who needs a person instead.
- **Run & test** — set up or reset the database, run the pgTAP suite, send
  documents to the model, re-score a run, load a run into the database.

On a fresh database, open **Run & test → Database → Set up the database**
first. The tool listens on this machine only, because it shows the real pages.

### The same thing from a terminal

```bash
docker compose exec db sh -c 'for f in sql/grooming_platform_schema.sql $(ls sql/[0-9][0-9]_*.sql | sort); do psql -U postgres -d grooming_test -v ON_ERROR_STOP=1 -q -f "$f" || exit 1; done'
docker compose exec db psql -U postgres -d grooming_test -f sql/seed/fixture.sql
docker compose exec db pg_prove -U postgres -d grooming_test tests/*.sql
```

Expected: `Files=27, Tests=440, Result: PASS`. The backend's tests build their own copy of the demo database:

```bash
docker compose exec -w /repo/api api python -m pytest -q
```

The SQL loads in section order. `grooming_platform_schema.sql` is sections 0–14;
each later section is its own numbered file, and a file's header carries the
same number. Tests are numbered independently, one file per rule family.

The extraction harness also runs as its own container, on demand:

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

Five subsystems, loosely coupled on purpose — a haircut record should not depend
on whether someone answered an email.

**Core** — owners, dogs (and their profile photos), groomers, visits, services,
coat assessments, allergies and handling notes.

**Styling** — how a haircut is described and recorded. A style is stored in *short
form* (a shop-wide template, a length tier, and a sparse set of dog-specific
overrides) and recorded in *long form* (one fully resolved row per body zone, with
lengths frozen at the moment of the cut). The step between them walks a four-level
precedence ladder.

**Compliance** — documents, LLM extractions and their line items, the document
vocabulary that resolves a printed term to a vaccine, vaccination records, record
requests, paperwork taken at the counter, owner consent and outreach, and a
per-dog-per-vaccine projection of compliance state.

**Scheduling** — appointments: a dog, a groomer, a start time and a length,
within the shop's hours, with the dog's usual groomer offered first.

**Governance** — an append-only audit log, retention rules, and the manager's
list of changes to review.

Entity-relationship diagrams are in [`reference/`](reference/): three for the
original schema (sections 0–14), and
[`erd_later_sections.mermaid`](reference/erd_later_sections.mermaid) for what
sections 15–31 added. The normative
specification is [`reference/resolution_precedence.md`](reference/resolution_precedence.md).
The extraction subsystem — its ingestion flow, the answer-key contract that
governs its labelled evaluation set, the four keys, and the harness that scores a
model run against them — is in [`extraction/`](extraction/).

### Changing a style

The styles are data, not code. Everything about a style (its name, its rules,
and its cut for every zone at every length) is in one file,
[`sql/21_style_template_seed.sql`](sql/21_style_template_seed.sql), written the way
a groomer would say it: `('teddy_bear', 'short', 'body', '#7F')`,
`'#30 + 3/4"'`, `'Scissors'`. Change the file, then run it again:

```bash
docker compose exec db psql -U postgres -d grooming_test -v ON_ERROR_STOP=1 -f sql/21_style_template_seed.sql
```

Use `-d grooming_demo` for the demo database. Each run replaces the styles in
the file as a whole, in one transaction. A typo stops it with a message naming
the line and what to fix, and the old version stays. Past haircuts never change;
each keeps its own copy of what was cut.

Every change is recorded in the audit log with the cut before and after, so
"why was Biscuit's cut different this month?" has an answer. Only real changes
are written, so a re-run with no edits records nothing. To record why, add
`-v reason='Shorter Teddy Bear body for summer'` to the command.

| To… | Do this |
|---|---|
| Change a cut | Edit its line in the seed file and re-run it |
| Add a style | Add it to the style list at the top of the seed file, then a block of cuts (one per zone, per length tier) |
| Add a comb or blade | Add a row to `comb` or `blade` in section 14 of the schema; the seed finds a comb by the length it leaves |
| Add a zone | Add a row to `body_zone` in section 14; the shave-down picks it up on the next seed run |
| Add a length tier | Add a row to `length_tier` in section 14, then cuts for it in every tiered style |
| Keep a zone within a length | Add a clamp in the seed file (the Poodle face is the example) |

[`tests/19_style_seed.sql`](tests/19_style_seed.sql) checks the result. A new style
gets the general checks automatically: every length covers the same zones, the
hygiene zones are left alone, combs sit on a #30, and a haircut can be recorded
at every length. A rule that is specific to the new style (say, a Schnauzer's
beard stays long) is one more query in that file, next to the Teddy Bear and
Lamb ones.

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
| `GR015` | A page is confirmed once, and only while it is awaiting review |
| `GR016` | A page is not confirmed until every tracked vaccine line is checked and every unfamiliar term is ruled on |
| `GR017` | A page becomes paperwork only for a dog it is filed under |
| `GR018` | A date goes on a record only if it is a real date, not in the future, and the expiry follows the shot |
| `GR019` | No automated message to an owner who has not agreed to that channel — checked when it is queued and again when it is sent |
| `GR020` | A groom does not start while a vaccine that blocks service is expired, missing, disputed or still being chased — but a past visit can still be recorded |
| `GR021` | A shot typed in at the counter needs both dates off the paper, and the expiry after the shot: no expiry printed, no record |
| `GR022` | A shot typed in at the counter that disagrees with one on file is not saved over it; a manager compares them |
| `GR023` | A breed that is not on the list is not added by accident: a misspelling gets the nearest names, and a new breed has to be said to be new |
| `GR024` | The same for an allergen, which also has to say which group it belongs to |
| `GR025` | An allergy is not taken off, or made less severe, without a reason — and the change waits for a manager |
| `GR026` | Only a manager clears a change from the manager's list |
| `GR027` | A shot counts as verified at the counter only if a photo of the paperwork is on file for that dog |
| `GR028` | Only a manager gives a hand-checked shot its second look |
| `GR029` | A copy of paperwork a shot was checked against is not removed: it is that record's evidence |
| `GR030` | Only a manager verifies a shot typed in with no photo, or fixes a shot's dates |
| `GR031` | Nobody is booked twice at once: a groomer, or a dog |
| `GR032` | A regular client is booked with their usual groomer, or the booking says why not |

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
| `14` | A line item is a row and its fields stay fields; the review queue empties itself; a corrected term is looked up by its correction; a tracked vaccine with one date still creates nothing; two dates create nothing either until a human has reviewed every field the record carries; a reviewer can mark a date unreadable instead of confirming a guess |
| `15` | The review work order names why each field needs a look; nothing is ready before review; evaluation results that contradict the scorer are refused |
| `16` | Layer 3: four refusals that write nothing; a shot printed twice is one record; a struck invented expiry asks the owner instead; an expired certificate does not close a request; a re-read that disagrees with the record on file — including a day misread by a few days — is flagged, not written; an unreadable date asks for a better copy and is not counted as a hallucination; an unreadable vaccine name asks for every tracked vaccine the dog is short of, and only those; confirmed evidence cannot be deleted |
| `17` | Outreach: no answer is a no and an email opt-out beats a yes; nothing queued without consent; one message per dog; sending schedules a reminder and the dashboard reads "requested"; reminders wait, are capped, then go to a person; a failed send changes nothing; a STOP after queueing stops the send |
| `18` | Check-in: no rabies record, or an expired one, refuses the groom by name and writes nothing; a non-blocking lapse does not, and making it block is a setting; a puppy too young for rabies is fine; one visit per dog per day, dated in the shop's time zone; history is still recordable |
| `19` | The style seed keeps each style's identity: a Teddy Bear head stays longer than the body, a Poodle face stays shaved, Kennel is one length; every length covers the same zones and can be recorded |
| `20` | Walk-ins: a new client and dog; no expiry, no record (GR021); a shot that disagrees with one on file is left for a manager (GR022); a misspelt breed gets the nearest names (GR023); a typo put right, before and after |
| `21` | Allergies and handling: "did you mean" for allergens (GR024); taking one off or lowering it needs a reason (GR025) and waits for a manager, who alone clears it (GR026); handling notes keep their history and their side |
| `22` | Paperwork at the counter: a copy and its pages; a hand check needs the photo on file (GR027) and waits for a manager's second look (GR028); asking the owner at the counter; a copy a record rests on stays (GR029) |
| `23` | AI suggestions: a counter reading stored like a corpus run, one suggestion per vaccine, unfamiliar names ruled once, and what is saved grades the AI field by field |
| `24` | A manager's fixes: verifying a typed-in shot says how (GR030); fixing a misread date keeps who checked it, regrades the AI, and re-opens a shot verified some other way; the counter's date rules still hold |
| `25` | The calendar: grooms on their day, each vaccine's current expiry only, rabies marked as stopping grooms, dogs off the books left out |
| `26` | Booking: a full groom is 90 minutes; nobody in two places at once (GR031); shop hours and the past; a regular client's usual groomer, or a reason (GR032); free times; vaccines warn, never refuse; a dog in good standing only when every vaccine is current and verified; moving and cancelling |
| `27` | Dog photos: kept in three sizes, replaced, removed, all or nothing |

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

**A present date is not a checked date.** On the held-out photo, every smudged
expiry came back from the model as a clean, confident date. Nothing in the
value distinguishes that from a printed one, so a line becomes a record only
when a human has reviewed every field the record carries — and confirmation
refuses the whole page (`GR016`) while any tracked line is unchecked. Each
line's fate is then a row in `line_item_outcome`, so "which printed line
produced this record?" has an answer, and a second copy of the same page
points at the record it duplicated instead of creating another.

**Two readings of one shot are one shot.** Duplicates are matched on a window,
not an exact date: the photo gives DHPP as given Oct 19 where the screenshot of
the same page says Oct 15, and exact matching would sign two verified records
for one injection. A shot within `duplicate_shot_window_days` (a `shop_policy`
row, default 7 — under the shortest real booster interval) of one on file is a
conflict for a human. And a reviewer who cannot read a date marks it
`unreadable`: no record, a request for a better copy, and no charge against
the model's hallucination rate for what was a camera problem. "Verified" is
never signed on a date nobody read.

---

## Roadmap

Done:

1. ~~The held-out photo.~~ Labelled 2026-09-24 before any model run on it,
   then run and reconciled. It is no longer unseen: the next new document is
   the one to hold out.
2. ~~Layer 3 — the confirmation step.~~ Section 18, with a **Confirm** screen
   in the review tool.
3. ~~Groomer interface.~~ The check-in screen and its backend (section 20,
   `api/`, `web/`, `sql/seed/demo.sql`), then walk-ins, breeds, allergies and
   handling (22–25), paperwork at the counter and the AI's suggestions (26–27),
   a manager's fixes and the Admin view (28), the calendar (29), booking ahead
   (30) and dog photos (31).
4. ~~Seed migration.~~ The template × tier × zone mapping, section 21.

Next:

5. **Record the haircut** — the screen that uses the style templates. When it
   allows editing a style it asks for a short reason (`groom.change_reason`);
   the shave-down's level-4 warning and level-5 acknowledgment are screen
   behaviour still to build. The Feet row in
   [`reference/style_tier_mapping.md`](reference/style_tier_mapping.md) is a
   best guess, waiting for a groomer's review.
6. Groomers' working days and hours, so booking only offers real
   availability; and linking a booking to the groom when it starts.
7. Reminder consent asked at walk-in sign-up, so a new client's missing
   paperwork is chased by the reminders and not only at the counter.
8. Graded counter readings exported as answer keys, so the harness's test
   bench grows from the shop's own paperwork.
9. Duplicate-upload warning — a near-duplicate image check before the model is
   called (a resized or re-saved copy of a page already on file). Exact copies
   are already refused per owner; a re-read of a shot already on file is
   already caught at confirmation (`already_on_file`).
10. Polish: a second held-out photo.

**Possible extension, not planned:** real delivery for owner outreach. The
rules, consent, outbox and sender are built and tested in test mode; going live
means an email service and a text provider behind `OUTREACH_PROVIDER`, a
scheduled run of `outreach.py`, STOP replies and unsubscribe links recorded as
consent entries, and a US business texting registration. That is a step toward
a product rather than toward this project's point.

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

This project started with my own dog, Jaddi, and his grooming routine, and the
two of us appear by name: the test fixture's first owner and dog are us, three
of the labelled documents are Jaddi's, and his name is in their file names and
notes. Everyone else is anonymised.

The real documents contain personal information and are excluded from version
control: they live in `private/`, which is gitignored as a directory rather
than by file extension. Model runs on them are gitignored for the same reason,
since a raw response repeats what the page says.

The answer keys in `extraction/answer_keys/` are anonymised at labelling time.
Everyone else's names, addresses and phone numbers, their pets' names, clinic
account numbers, microchip and tag numbers, and the veterinarians' names and
licence numbers are substituted in every field (Jaddi's household appears as
the Webbs, and he as Nutmeg), while clinical facts (dates, lot numbers,
product names) are kept verbatim so a key can still be checked against its
page. Household structure is preserved: two households have two surnames.
Clinic names and phone numbers are kept, since they are businesses and already
public. The other owners, dogs, groomers
and visits in the test fixture are invented.

---

## Built with

PostgreSQL 16 · pgTAP · FastAPI · Next.js · Tailwind · Claude (vision) · Docker