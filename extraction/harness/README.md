# Extraction harness

Measures Layer 1 — the model's transcription — against the hand-labelled answer
keys in `../answer_keys/`. It does not classify anything and it does not write
a vaccination record; those are Layers 2 and 3, and the pgTAP suite covers them.

Four commands, one container:

```bash
docker compose run --rm harness selfcheck            # prove the scorer, no API call
docker compose run --rm harness run                  # send the corpus to the model, score it
docker compose run --rm harness score runs/<stamp>   # re-score an old run
docker compose run --rm harness load  runs/<stamp>   # load a run into the database
```

`run` needs `ANTHROPIC_API_KEY` and `EXTRACTION_MODEL` in `.env` (see
`.env.example`). The other three need nothing.

## What a run produces

`../runs/<UTC stamp>/<document_id>.json`, one per document: the raw response
text exactly as returned, the parsed JSON, the model that actually answered,
the prompt version, token usage. `score.json` lands beside them. The whole
`runs/` directory is gitignored because the responses contain what the pages
contain.

The prompt version is `p1-<hash>`: the file name plus a hash of its content,
so an edited prompt can never be mistaken for the old one in the
`extraction` table. Edit `prompt_v1.md` freely while iterating; copy it to
`prompt_v2.md` when you want to compare two prompts side by side
(`run --prompt prompt_v2.md`).

## What the score means

```
docside_invoice_2025-04-04   rows 13/13 fields 183  correct 175  wrong 1  missed 5  spurious 2  traps hit 1/6
```

| Column | Meaning |
|---|---|
| `rows` | line items produced / line items on the page |
| `fields` | slots scored — every slot in the canonical shape, including the nulls |
| `correct` | key and model agree, after whitespace cleanup only. Case and punctuation are the page's |
| `wrong` | both have a value and they differ |
| `missed` | the page has a value, the model emitted null |
| `spurious` | the page has nothing, the model emitted something — **the hallucination class** |
| `traps hit` | `must_not_produce` entries the model fell into, out of those scorable at Layer 1 |

Below the table, every non-correct field is listed with what was expected and
what came back, so a run's failures can be read against the page. `absent`
violations are listed separately by category (`labeled_but_blank`,
`unfilled_form_fields`, `not_present`), because inventing a value for a field
the clinic left blank is a different mistake from inventing one the format
does not carry.

Two things are deliberately **not** scored:

- `source_region`. Every format names its regions differently and there is no
  verbatim answer to hold the model to. It is emitted for the reviewer.
- Traps tagged `layer: resolution`. A trap like "two DHPP records from lines 2
  and 7" is about what the database does with a correct transcription. The
  count of skipped traps is reported so they are not forgotten.

## The self-check

`selfcheck` runs before any API call is worth making. It scores each key
against its own `expected` (must be perfect — otherwise the scorer is
measuring the key, not the model) and then scores a deliberately damaged copy
of the invoice key and asserts that exactly the planted failures appear: the
invented 28th on the rabies reminder, a fax number the page does not carry, a
missed age, a mangled city, a dropped row. If the scorer cannot see a planted
hallucination it cannot see a real one.

The first time it ran, it caught two labelling errors in the invoice key:
traps whose row index pointed at a row whose expected value was already the
"wrong" value. Both are corrected and annotated in the key.

## Loading a run

`load` writes the run into the database in the shape sections 7, 15 and 16
define: one `document` per (owner, sha256) — the second load of the same file
reuses the row, which is the ingestion flow's dedupe branch — one `extraction`
per run, document-level fields as `extraction_field` rows with dotted names,
and one `extraction_line_item` per printed row with its fields beside it.
Every field lands `unreviewed`. The two views then show the result:

```sql
SELECT * FROM groom.v_unmapped_terms;          -- what a human has to rule on
SELECT * FROM groom.v_extraction_line_item;    -- every row, resolved, with can_create_record
```

`corpus.json` maps each key to its file in `private/` and to the fixture
household it belongs to.

## Adding a document

1. Put the file in `private/`.
2. Write its key per `../answer_key_contract.md` (copy the `expected`
   skeleton verbatim; `null` is the assertion).
3. Add an entry to `../corpus.json`.
4. `selfcheck` — the new key must score perfectly against itself.
