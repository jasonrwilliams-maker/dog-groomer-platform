# Corpus notes: Jaddi's timeline, and the record two documents make

Three of the labelled documents are Jaddi's (the Webb household and "Nutmeg" in
the keys' anonymised fields). Read one at a time, none of the Doc Side pages can
become a vaccination record. Read together, two of them make two complete
records. This note is the argument the keys point to.

## The documents

| Document | Date | What it gives |
|---|---|---|
| BetterVet rabies certificate | 2024-02-29 | Rabies given 2024-02-29, expires 2025-02-28. Both dates. **One record.** |
| Doc Side invoice | 2025-04-04 | Shots and the day each was given. The reminder column prints only a month (`03-28`), never a day. **No records.** |
| Doc Side vaccination email | 2026-06-09 | Each vaccine's expiry date. No dates given. **No records.** |

The invoice and the email are mirror images: one has every administration date
and no expiries, the other every expiry and no administration dates.
`vaccination_record` needs both, so each on its own produces nothing, which is
correct. Neither page states what it does not state.

## Together

| Vaccine | Given (invoice) | Expires (email) | Interval |
|---|---|---|---|
| Rabies | 2025-03-08 | 2028-03-07 | 3 years, matching "Rabies Vaccine 3 Yr Canine" |
| DHPP | 2025-04-04 | 2028-04-03 | 3 years, matching "DHPP 3YR" |

Each pair agrees with the product's own stated duration, to the day. These are
two complete, true records that only exist across two documents.

Bordetella does not pair. The invoice has it given 2025-03-08, and the email's
expiry, 2027-04-02, belongs to a later annual shot that neither page shows
being given. Pairing them would invent a record.

## The question this raises

**Combining is not inferring.** Taking a stated expiry from one page and a
stated administration date from another invents nothing; deriving an expiry
from a product name would. The system refuses the second and should allow the
first.

**It cannot yet say so honestly.** `vaccination_record.document_id` names one
source. A record built from the invoice and the email would have to cite one
and drop the other, and the dropped one is half the evidence. The honest shape
is a record that cites both documents, and which field came from which. That
belongs after extraction, visibly, never inside it: a model asked to "complete"
a record from two pages is a model asked to fill gaps.

Until then, Jaddi reads `expired` for rabies (the 2024 certificate is the
latest record a single page can make) and `no_record` for DHPP, despite two
documents that together prove both are current. That is the conservative
answer, and it is deliberately left in place rather than patched.
