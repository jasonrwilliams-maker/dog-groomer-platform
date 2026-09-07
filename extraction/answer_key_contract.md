# Answer Key Contract — v3

Shared contract for every hand-labelled extraction answer key. Read this before
writing a new key; keys are only comparable to each other if they agree on this.

---

## The one rule

**`expected` is canonical and is compared. Everything else is documentation.**

Every key emits an identical `expected` shape — same keys, same nesting, `null`
where the page carries nothing. The harness diffs a model run against `expected`
and needs no per-document code. If `expected` drifts between keys, you have
re-invented the per-clinic parser, one level up.

Any key beginning with `_` is a human annotation and is never compared.

---

## Three layers, and who owns each

    Layer 1  EXTRACTION    the model transcribes what is printed
    Layer 2  RESOLUTION    the database interprets it
    Layer 3  CONFIRMATION  a human accepts it, and rows are written

The model transcribes; the database interprets. That split is the whole design,
and it is why `expected` contains no `vaccine_code` anywhere.

**The model must never classify.** It emits the term exactly as printed —
`"Bi-annual bordetella Vaccine"`, `"Distemper/Parvo Vaccine Adult (3 yr)"` — and
stops. Mapping that term to `bordetella` or `dhpp` is a lookup against
`document_term`, which is data a human maintains. The moment a prompt starts
enumerating synonyms, the prompt has become the parser you were avoiding.

The same applies to compound tokens. `"Spayed Female"` is one string on the page
and two columns in the schema (`dog.sex`, `dog.is_altered`). The model emits
`sex_raw: "Spayed Female"`. Splitting it is Layer 2.

A key therefore asserts on all three layers but **grades the model only on
Layer 1**. `resolution` and `schema_outcome` record what should happen next; they
are not the model's score.

---

## Scope: which vaccines are tracked

    rabies        regulatory_required = true,  required_by_policy = true
    dhpp          regulatory_required = false, required_by_policy = true
    bordetella    regulatory_required = false, required_by_policy = true

Two criteria, and a tracked vaccine must pass both:

1. **Transmissible dog-to-dog in a shared facility.** Grooming is a room full of
   strangers' dogs, wet surfaces and dryers moving air. Parvo persists on
   surfaces, bordetella is airborne, and rabies carries the legal weight.
2. **Documented at the moment of administration, by the party administering it.**
   This is what makes a record verifiable at all.

Applying the rule to everything else that shows up on these documents:

| Item | Criterion 1 | Criterion 2 | Disposition |
|---|---|---|---|
| Rabies | yes — plus statutory | yes | tracked |
| DHPP / DAPP | yes — parvo persists on surfaces | yes | tracked |
| Bordetella | yes — airborne, and dryers move air | yes | tracked |
| Leptospirosis | **borderline** — urine-borne, and floors get wet | yes | recognised, untracked |
| Lyme vaccine | no — tick-borne, not dog-to-dog | yes | not tracked |
| Heartworm prevention | no — mosquito-borne | no — sold, not administered | not tracked |
| Flea / tick prevention | n/a — not a vaccine | **no** | not tracked |
| Diagnostic tests, dewormers | n/a | n/a | not a vaccine |

Two notes on the edges, because they are where the rule earns its keep:

**Leptospirosis is the genuine borderline case**, and that is exactly why it stays
in `vaccine_type` with both flags false rather than being deleted. A shop that
decides wet floors matter flips `required_by_policy` to true — one `UPDATE`, no
migration. Deleting the row would make that a schema change. This is the
STRUCTURAL / LEGAL / PREFERENCE taxonomy doing its job.

**Flea and tick fail on criterion 2, not on self-administration.** Plenty of it is
prescription and appears on invoices. The problem is that a parasiticide is
documented at the moment of *sale*: a purchase in March says nothing about
whether the dog was dosed in July. The document proves acquisition, not
protection. A vaccine is documented at the moment of administration, which is why
one is verifiable and the other is not.

Fleas are still an operational reality — they are just not a paperwork problem.
A groomer who finds fleas at the bath stops and calls the owner, which is
`visit_service.completed = false` with an `incomplete_reason`. The schema already
holds it.

---

## The canonical `expected` shape

```jsonc
{
  "expected": {
    "document": {
      "as_of_date": "YYYY-MM-DD | null"   // a date the page states about ITSELF
    },
    "clinic": {
      "name": null, "phone": null, "fax": null, "email": null,
      "website": null, "address_raw": null
    },
    "owner": {
      "name": null, "clinic_client_id": null,
      "address_line1": null, "address_line2": null,
      "city": null, "state": null, "postal_code": null,
      "phone": null, "email": null
    },
    "patient": {
      "name": null, "clinic_patient_id": null,
      "species_raw": null,
      "breed_raw": null,          // verbatim: "Shih Tzu Mix" — do not split
      "sex_raw": null,            // verbatim: "Spayed Female" — do not split
      "date_of_birth": null,      // only if the page prints a DATE
      "age_raw": null,            // only if the page prints an AGE
      "weight_raw": null,
      "color": null,
      "microchip": null,
      "tag_number": null          // when printed in the patient block
    },
    "line_items": [               // ALWAYS an array, even for one vaccination
      {
        "n": 1,
        "term": "verbatim from the page",
        "administered_on": "YYYY-MM-DD | null",
        "expires_on": "YYYY-MM-DD | null",
        "lot_serial_number": null,
        "vaccine_manufacturer": null,
        "veterinarian_name": null,
        "veterinarian_license_no": null,
        "veterinarian_phone": null,
        "tag_number": null        // when printed alongside the vaccination
      }
    ]
  }
}
```

`tag_number` appears twice on purpose. A rabies tag sits in the vaccination block
on a certificate and in the patient header on a portal summary. The same fact
lives in different places in different formats, so the shape carries both slots
and each key fills whichever one its page uses. That is the general pattern for
canonicality: give the shape a slot for every place a fact is known to appear,
rather than forcing one layout's assumptions onto every other.

---

## The rest of a key

| Block | Compared? | Purpose |
|---|---|---|
| `meta` | no | provenance, format family, capture quality, PII substitutions |
| `expected` | **yes** | Layer 1. The canonical shape above |
| `absent` | **yes** | three categories of nothing — see below |
| `must_not_produce` | **yes** | specific wrong values, each tagged with its layer |
| `resolution` | yes, separately | Layer 2. term → `vaccine_type`, and compound-token splits |
| `schema_outcome` | yes, separately | Layer 3. rows that should exist once confirmed |
| `annotations` | no | anything a future reader needs and a diff does not |

### Three kinds of absence

- **`labeled_but_blank`** — the format prints the label and the clinic left it
  empty. Says something about the dog: they were asked and had no answer.
- **`unfilled_form_fields`** — a printed question nobody answered. Different from
  blank data, because a human was supposed to fill it in, and because the answer
  is sometimes inferable from elsewhere on the same page. That inferability is
  the trap, not a licence.
- **`not_present`** — the format does not carry the field at all. Says nothing
  about the dog, only about the layout.

### `must_not_produce`

Each entry carries `layer: "extraction"` or `layer: "resolution"`, so a failure is
attributed to the stage that owns it. Entries also record
`caught_by_plausibility_check`, because the honest answer is usually `false` and
that is the empirical argument for the human confirmation step.

---

## Writing a new key

1. Copy the `expected` skeleton above verbatim. Do not prune keys the page lacks —
   `null` is the assertion.
2. Transcribe every line on the page into `line_items`, including the ones that
   are obviously irrelevant. Seven of eleven rows on the Petly page produce
   nothing, and that ratio is the most useful thing that key measures.
3. Fill the three `absent` categories.
4. Write `must_not_produce` last, by asking what the *nearest wrong answer* is for
   each field — the value a careful reader could reach for and be wrong.
5. Anonymise as you go, and preserve the relationships you intend to test.
   Two households need two surnames.
