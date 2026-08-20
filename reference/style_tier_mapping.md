# Style Template × Length Tier Mapping

Seed data for `style_template_zone_spec`. Each row expands into a zone spec when a
template + tier is applied to a visit.

## Blade reference

| Blade | Length | Blade | Length |
|---|---|---|---|
| #3 / #3F | 1/2" | #7 / #7F | 1/8" |
| #4 / #4F | 3/8" | #9 | 5/64" |
| #5 / #5F | 1/4" | #10 | 1/16" |
| | | #15 | 3/64" |
| | | #30 | 1/50" |

`F` = finish blade. Same cut length, smoother finish. Modeled as a boolean on the
blade, not a separate blade.

**Combs override the blade.** `#30 + 1" comb` yields a 1" cut. The underlying blade is
always the shortest available because the comb does the work. Effective length is
derived from `(blade, comb)`, never read off the blade alone.

## Fixed zones — invariant across all templates and tiers

These do not vary. They are hygiene cuts, not style cuts.

| Zone | Tool | Blade | Notes |
|---|---|---|---|
| Sanitary | Clipper | #10 | Always |
| Feet & pads | Clipper | #15 | Always |
| Inside ears | Clipper | #10 | Always |

Encoding these as template-independent defaults means a new template only has to
define the ~9 zones that actually carry style.

---

## 1. Teddy Bear

**Identity:** face is left longer than the body; rounded, soft silhouette. The
face-to-body length differential is what makes it a Teddy Bear.

| Zone | Short | Medium | Long |
|---|---|---|---|
| Body | #7F | #4F | #30 + 3/4" comb |
| Neck | #7F | #4F | #30 + 3/4" comb |
| Legs | #5F | #4 | #30 + 1" comb |
| Head / skull | #30 + 3/4" comb | #30 + 1" comb | #30 + 1 1/4" comb |
| Muzzle / beard | Scissors | Scissors | Scissors |
| Ears | #7F | #4F | Scissors |
| Ear tips | #10 | #10 | Scissors |
| Tail | Scissors | Scissors | Scissors |
| Stomach / underbody | #10 | #7F | #4F |

Differential holds at every tier: head is always at least two steps longer than body.

## 2. Poodle (Kennel Trim)

**Identity:** clean-shaved face, feet, and base of tail; short body; fuller neck and
top knot forming a mane.

| Zone | Short | Medium | Long |
|---|---|---|---|
| Body | #7F | #5 | #3 |
| Neck / mane | #5 | #4 | #30 + 3/4" comb |
| Legs | #7F | #4 | #30 + 3/4" comb |
| Face | #15 | #10 | #10 |
| Muzzle | #15 | #10 | #10 |
| Ears | Scissors | Scissors | Scissors |
| Top knot | Scissors | Scissors | Scissors |
| Base of tail | #15 | #10 | #10 |
| Tail pom | Scissors | Scissors | Scissors |
| Stomach / underbody | #10 | #10 | #7F |

Note the face does not lengthen past #10 — a shaved face is definitional here, so the
tier modifier is clamped. Good example of a per-template floor.

## 3. Lamb

**Identity:** body shorter than legs. Inverse of Teddy Bear's differential —
here the contrast is vertical, not front-to-back.

| Zone | Short | Medium | Long |
|---|---|---|---|
| Body | #7F | #5 | #4 |
| Neck | #7F | #5 | #4 |
| Legs | #30 + 3/4" comb | #30 + 1" comb | #30 + 1 1/4" comb |
| Head / skull | #30 + 3/4" comb | #30 + 1" comb | #30 + 1" comb |
| Face | #15 | #10 | #10 |
| Ears | Scissors | Scissors | Scissors |
| Top knot | Scissors | Scissors | Scissors |
| Tail | Scissors | Scissors | Scissors |
| Stomach / underbody | #10 | #10 | #7F |

## 4. Kennel / Puppy

**Identity:** one length everywhere. No differential — that *is* the style.

| Zone | Short | Medium | Long |
|---|---|---|---|
| Body | #7F | #4F | #30 + 1" comb |
| Neck | #7F | #4F | #30 + 1" comb |
| Legs | #7F | #4F | #30 + 1" comb |
| Head / skull | #7F | #4F | #30 + 1" comb |
| Muzzle | #7F | #4F | #30 + 1" comb |
| Ears | #7F | #4F | #30 + 1" comb |
| Tail | #7F | #4F | #30 + 1" comb |
| Stomach / underbody | #7F | #4F | #30 + 1" comb |

Uniformity is a useful validation case: a template where every zone must resolve to
the same effective length. Worth a check constraint or a test.

## 5. Shaved — remedial, no tiers

**Identity:** not a style. A response to coat condition.

| Coat assessment | Blade | Trigger |
|---|---|---|
| Level 4 — widespread matting | #7F | Warning shown, groomer may proceed |
| Level 5 — pelted | #10 | Acknowledgment required before saving |

`is_remedial = true`. Applying this template requires a linked `coat_assessment` at
level 4 or higher. The system should refuse to record a shave-down with a level 1–3
assessment, or require an explicit override reason — that refusal is the record that
protects her in the "you shaved my dog" conversation.

---

## Tier semantics

Tier is **not** a uniform global offset. Each template defines its own per-zone
mapping, because the zone relationships that define a style must survive the shift:

- Teddy Bear Long keeps the head longer than the body.
- Poodle Long keeps the face shaved.
- Lamb Long keeps the legs longer than the body.

A global "+2 blade steps" would collapse all three into the same haircut at the long
end. Storing the mapping per template is more rows and less clever, and it is correct.

## Custom profiles

`dog_style_profile` stores `(template, tier)` plus a sparse set of zone overrides —
not a full expansion. Luna's profile might be `Teddy Bear / Medium` with two
overrides: ears to scissors, stomach to #10.

Benefits of storing deltas rather than the expanded set:
- Rebooking is one row lookup plus an expansion
- Template changes propagate to profiles that did not override that zone
- The diff between two visits is readable, so "what did we change last time" is a
  query rather than a memory exercise
