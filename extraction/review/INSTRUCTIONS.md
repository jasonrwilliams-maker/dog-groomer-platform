# How to use this tool

The tool has one job: make an **answer key** for each document — a record of
exactly what the page prints — so a model run can be scored against it. Then it
shows you where the model and the key disagree.

The order is always the same:

1. **Documents** — see what is waiting.
2. **Label** — write (or check) the answer key, looking at the page.
3. **Run & test** — send the document to the model.
4. **Review** — go through the disagreements.

---

## Starting up

1. Open Docker Desktop and wait for it to say it is running.
2. Start the stack: in Docker Desktop, press ▶ on **dog-groomer-platform** — or
   run `docker compose up -d` once from the project folder.
3. Open http://localhost:8501.

The first time on a fresh database, go to **Run & test → Database** and press
**Set up the database**.

---

## 1. Documents

A table of every file in `private/`:

| Colour | Means |
|---|---|
| 🔴 | No answer key yet |
| 🟡 | A draft is in progress |
| 🟢 | Published key |

An amber **to reconcile** number means a model run has disagreements you
haven't ruled on yet.

---

## 2. Label

Pick the document in the sidebar.

### Starting a key

- **A blank key** — for a new kind of document.
- **Parts of an existing key** — for the same clinic, or the same document in
  another form (a photo of a screenshot, a reprint). Choose the key, tick what
  to copy, check the preview, then **Start labelling**.

Every copied value is marked **🟠 to check** until you have looked at it on
*this* page. A draft saves itself as you go. **Close** keeps it;
**🗑 Discard** throws it away.

### The golden rule

Type what the page **prints**, not what you know. If a date is readable on
the screenshot but not in the photo, it is **illegible** in the photo's key.
A blank box means "nothing here", and that is a correct answer.

### ① Page header

Document date, clinic, owner, patient. Beside every box is a status:

| Status | Use when |
|---|---|
| as typed | You typed the value — or the page simply has nothing here |
| blank on page | The label is printed and left empty (`Color:` with nothing after it) |
| unfilled form question | A printed question nobody answered (unticked Yes/No boxes) |
| not on this format | This kind of document never has this field |
| illegible | Something is printed and you can't read it. Note what you *can* see: `03/1_/2025` |

### ② Rows

One row per line in any list on the page — vaccinations, services, reminders,
discounts — in page order. Headings and footers are not rows.

Each row has a priority badge:

| Badge | What it is | How it is checked |
|---|---|---|
| 🔴 tracked vaccine | Rabies, DHPP, bordetella | Each value on its own — these become vaccination records |
| 🟠 no ruling yet | A term the database has never ruled on | One button per row — it *might* be a vaccine |
| ⚪ lower priority | Tests, heartworm, dewormers, exams, untracked vaccines | One button for all of them |

Dates have two boxes. **printed** holds the date exactly as on the page
(`03-28`, `Oct 15, 2025`). The **ISO** box (`YYYY-MM-DD`) is filled only when
the printed form gives year, month *and* day — `03-28` is a month, so its ISO
box stays empty. The tool warns you if the two don't agree.

### ③ Traps

Optional, and worth it. A trap is the **nearest wrong answer** for a field —
the value a careful reader could reach for and be wrong: a date worked out
instead of read, a misspelling "corrected", a print date used as a vaccination
date. The score reports how many traps the model fell into.

### ④ Check & publish

- **About this document** — the document type, and **which household** it
  belongs to. If the household isn't in the test fixture, choose
  *not in the fixture yet*: the key can still be published, run and scored;
  only loading it into the database waits for the fixture.
- **Fix before publishing** — must be empty to publish.
- **Worth a second look** — questions, not blockers.
- **Publish the key** writes it to `extraction/answer_keys/`.

### More…

- **Also accept** — only when the page prints the *same* fact twice in two
  forms (a phone number in the header and differently in the footer).
- **PII map** — keys use made-up names; the pages have real ones. Each real
  value as printed needs a line here pointing to its made-up name, or the
  model's correct reading will score as wrong.

---

## 3. Run & test

| Section | What it does |
|---|---|
| Status | Is the API key set, is the database reachable and set up |
| Model | Sends documents to the model and scores the result. **This costs money** — tick the box to confirm |
| Scoring | Re-scores an old run, or loads it into the database |
| Checks | The harness self-check, and the database test suite |
| Database | Set up an empty database, or reset it |

---

## 4. Review

Pick a document and a run. The page is on the left; each disagreement is a card
on the right showing what the key says and what the model read. For each, look
at the page and choose:

- **The model is wrong** — the key stands. Recorded with the run.
- **The key is wrong** — the key is corrected to the model's reading, and the
  change is logged in the key with your reason.
- **Both are right** — the page prints this fact twice in two forms.

Rows are compared by number, so if the model skipped a row, everything after it
disagrees. Fix the first one and read the rest with that in mind.
