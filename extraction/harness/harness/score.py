"""Score one model output against one answer key.

Three assertions, straight from the contract:

  1. expected         — the model produced these values (Layer 1 only)
  2. absent           — the model did NOT invent values for these
  3. must_not_produce — the model did NOT produce these specific wrong values

`resolution` and `schema_outcome` are Layer 2 and 3. They are the database's
score, not the model's; the pgTAP suite covers them. Traps tagged with those
layers are kept in the result as `other_layer` so they are recorded, not lost.

Vocabulary for a field:
  correct   key and model agree (after whitespace cleanup only), or the model
            gave one of the key's also_accept values
  wrong     both have a value, and they differ
  missed    key has a value, model emitted null       — recall failure
  spurious  key is null, model emitted a value        — the hallucination class
  unscored  a slot the harness deliberately does not grade (source_region)

Before any of that, the model's output is passed through the PII map (see
pii.py), because the keys are anonymised and the pages are not.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from . import keys as K
from . import pii as P


@dataclass
class FieldResult:
    path: str
    outcome: str            # correct | wrong | missed | spurious | unscored
    expected: object
    got: object             # AFTER the PII map — what was actually compared
    pii_mapped: bool = False
    accepted_alternate: bool = False


@dataclass
class TrapResult:
    id: int
    field: str
    wrong_value: object
    outcome: str            # avoided | hit | not_scorable | other_layer
    got: object = None
    note: str = ""


@dataclass
class DocScore:
    document_id: str
    fields: list[FieldResult] = field(default_factory=list)
    absent_violations: list[FieldResult] = field(default_factory=list)
    traps: list[TrapResult] = field(default_factory=list)
    expected_items: int = 0
    got_items: int = 0
    parse_error: str | None = None

    def count(self, outcome: str) -> int:
        return sum(1 for f in self.fields if f.outcome == outcome)

    @property
    def scored(self) -> int:
        return sum(1 for f in self.fields if f.outcome != "unscored")

    @property
    def traps_hit(self) -> int:
        return sum(1 for t in self.traps if t.outcome == "hit")

    @property
    def traps_scorable(self) -> int:
        return sum(1 for t in self.traps if t.outcome in ("hit", "avoided"))

    @property
    def traps_other_layer(self) -> int:
        return sum(1 for t in self.traps if t.outcome == "other_layer")

    @property
    def pii_mapped_count(self) -> int:
        return sum(1 for f in self.fields if f.pii_mapped)

    def summary_line(self) -> str:
        if self.parse_error:
            return f"{self.document_id:<38} PARSE ERROR: {self.parse_error}"
        return (f"{self.document_id:<38} rows {self.got_items:>2}/{self.expected_items:<2} "
                f"fields {self.scored:>3}  correct {self.count('correct'):>3}  wrong {self.count('wrong'):>2}  "
                f"missed {self.count('missed'):>2}  spurious {self.count('spurious'):>2}  "
                f"traps hit {self.traps_hit}/{self.traps_scorable}")


def score_document(key: dict, output: dict | None, document_id: str,
                   parse_error: str | None = None, pii: P.PiiMap = P.EMPTY) -> DocScore:
    ds = DocScore(document_id=document_id, parse_error=parse_error)
    if output is None:
        return ds

    raw_flat = K.flatten(output)
    got_flat = K.flatten(pii.apply(output))
    exp_flat = K.flatten(key["expected"])
    also = {p: [K._clean(v) for v in vals]
            for p, vals in (K.strip_annotations(key.get("also_accept")) or {}).items()}
    ds.expected_items = K.line_item_count(key["expected"])
    ds.got_items = K.line_item_count(output)

    # --- 1. expected ------------------------------------------------------------
    paths = list(exp_flat) + [p for p in got_flat if p not in exp_flat]   # extra rows are spurious
    for p in paths:
        e, g = exp_flat.get(p), got_flat.get(p)
        mapped = raw_flat.get(p) != g
        _, fname = K.parse_path(p)
        if fname in K.UNSCORED_LINE_ITEM_FIELDS:
            ds.fields.append(FieldResult(p, "unscored", e, g, mapped))
            continue
        alt = False
        if e is None and g is None:
            outcome = "correct"
        elif e is None:
            outcome = "spurious"
        elif g is None:
            outcome = "missed"
        elif str(e) == str(g):
            outcome = "correct"
        elif str(g) in (str(a) for a in also.get(p, [])):
            outcome, alt = "correct", True
        else:
            outcome = "wrong"
        ds.fields.append(FieldResult(p, outcome, e, g, mapped, alt))

    # --- 2. absent ----------------------------------------------------------------
    absent = key.get("absent") or {}
    for category in ("labeled_but_blank", "unfilled_form_fields", "not_present"):
        for entry in absent.get(category) or []:
            path = entry.get("field")
            if not path:
                continue
            for p in K.expand_path(path, ds.got_items):
                if p not in got_flat and K.parse_path(p)[0] is None and p not in exp_flat:
                    continue   # outside the canonical shape: the model has no slot for it
                g = got_flat.get(p)
                if g is not None:
                    ds.absent_violations.append(FieldResult(p, category, None, g))

    # --- 3. must_not_produce ----------------------------------------------------------
    for trap in key.get("must_not_produce") or []:
        layer = trap.get("layer", "extraction")
        if layer != "extraction":
            ds.traps.append(TrapResult(trap.get("id", 0), trap["field"], trap.get("wrong_value"),
                                       "other_layer", note=f"layer: {layer} — the database's score, not the model's"))
            continue
        ds.traps.append(_check_trap(trap, got_flat, ds.got_items))

    return ds


def _check_trap(trap: dict, got_flat: dict, n_items: int) -> TrapResult:
    fpath = trap["field"]
    wrong = K._clean(trap.get("wrong_value"))
    tid = trap.get("id", 0)

    if fpath == "any date field":
        # Every date slot EXCEPT the document's own date: the trap is the page's
        # print/fetch date leaking into a vaccination or birth date, and
        # document.as_of_date is exactly where that date is supposed to go.
        candidates = [p for p in got_flat
                      if K.parse_path(p)[1].split(".")[-1] in K.DATE_FIELDS
                      and p != "document.as_of_date"]
    else:
        idx, _ = K.parse_path(fpath)
        if idx is None and fpath not in got_flat:
            return TrapResult(tid, fpath, wrong, "not_scorable",
                              note="field is outside the canonical shape; the model has no slot for it")
        candidates = K.expand_path(fpath, n_items)

    if wrong is None or (isinstance(wrong, str) and wrong.startswith("<")):
        return TrapResult(tid, fpath, wrong, "not_scorable", note="wrong_value is descriptive, not a literal")

    for p in candidates:
        g = got_flat.get(p)
        if g is not None and str(g) == str(wrong):
            return TrapResult(tid, fpath, wrong, "hit", got=f"{p} = {g!r}")
    return TrapResult(tid, fpath, wrong, "avoided")


# ---------------------------------------------------------------- reporting

def render(scores: list[DocScore], verbose: bool = False, header: str | None = None) -> str:
    out = []
    out.append("=" * 118)
    out.append("Layer 1 — extraction, scored against the answer keys")
    if header:
        out.append(header)
    out.append("=" * 118)
    for ds in scores:
        out.append(ds.summary_line())
    tot = totals(scores)
    out.append("-" * 118)
    out.append(f"{'TOTAL':<38} rows {tot['got_items']:>2}/{tot['expected_items']:<2} "
               f"fields {tot['scored']:>3}  correct {tot['correct']:>3}  wrong {tot['wrong']:>2}  "
               f"missed {tot['missed']:>2}  spurious {tot['spurious']:>2}  "
               f"traps hit {tot['traps_hit']}/{tot['traps_scorable']}")
    if tot["scored"]:
        out.append(f"{'':<38} field accuracy {tot['correct']/tot['scored']:.1%}   "
                   f"absent violations {tot['absent']}   PII-mapped fields {tot['pii_mapped']}   "
                   f"traps recorded as Layer 2/3: {tot['other_layer']}")
    out.append("")
    out.append("spurious = value where the page has none: the hallucination class. "
               "A trap hit is a specific wrong value the key predicted.")

    for ds in scores:
        problems = [f for f in ds.fields if f.outcome in ("wrong", "missed", "spurious")]
        hits = [t for t in ds.traps if t.outcome == "hit"]
        alts = [f for f in ds.fields if f.accepted_alternate]
        unsc = [t for t in ds.traps if t.outcome == "not_scorable"]
        if not (problems or hits or ds.absent_violations or (verbose and (unsc or alts))):
            continue
        out.append("")
        out.append(f"--- {ds.document_id}")
        for f in problems:
            tag = "  (after PII map)" if f.pii_mapped else ""
            out.append(f"  {f.outcome:<8} {f.path:<42} expected {f.expected!r:<32} got {f.got!r}{tag}")
        for a in ds.absent_violations:
            out.append(f"  absent   {a.path:<42} [{a.outcome}] got {a.got!r}")
        for t in hits:
            out.append(f"  TRAP {t.id:<3} {t.field:<42} produced the predicted wrong value: {t.got}")
        if verbose:
            for f in alts:
                out.append(f"  (accepted alternate for {f.path}: {f.got!r})")
            for t in unsc:
                out.append(f"  (trap {t.id} {t.field}: not scorable — {t.note})")
    return "\n".join(out)


def totals(scores: list[DocScore]) -> dict:
    t = dict(expected_items=0, got_items=0, scored=0, correct=0, wrong=0, missed=0,
             spurious=0, traps_hit=0, traps_scorable=0, absent=0, other_layer=0, pii_mapped=0)
    for ds in scores:
        t["expected_items"] += ds.expected_items
        t["got_items"] += ds.got_items
        t["scored"] += ds.scored
        for k in ("correct", "wrong", "missed", "spurious"):
            t[k] += ds.count(k)
        t["traps_hit"] += ds.traps_hit
        t["traps_scorable"] += ds.traps_scorable
        t["absent"] += len(ds.absent_violations)
        t["other_layer"] += ds.traps_other_layer
        t["pii_mapped"] += ds.pii_mapped_count
    return t


def to_json(scores: list[DocScore], ruler: str | None = None) -> dict:
    return {
        "ruler_version": ruler,
        "totals": totals(scores),
        "documents": [
            {
                "document_id": ds.document_id,
                "parse_error": ds.parse_error,
                "expected_items": ds.expected_items,
                "got_items": ds.got_items,
                "counts": {k: ds.count(k) for k in ("correct", "wrong", "missed", "spurious")},
                "fields": [vars(f) for f in ds.fields if f.outcome != "correct" or f.accepted_alternate],
                "absent_violations": [vars(a) for a in ds.absent_violations],
                "traps": [vars(t) for t in ds.traps],
            }
            for ds in scores
        ],
    }
