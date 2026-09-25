"""The extraction evaluation harness.

    python -m harness selfcheck            prove the scorer itself, no API call
    python -m harness run [--doc ID ...]   send the corpus to the model, write a run
    python -m harness score RUN_DIR        score a run against the answer keys (no side effects)
    python -m harness load  RUN_DIR        load a run into the database and record its score

Run from extraction/harness/ (the Dockerfile's working directory).
"""
from __future__ import annotations

import argparse
import copy
import json
import sys
from pathlib import Path

from . import keys as K
from . import pii as P
from . import score as S


def _corpus_and_keys():
    corpus = {d.document_id: d for d in K.load_corpus()}
    keys = {d.document_id: K.load_key(d.key_path) for d in corpus.values()}
    return corpus, keys


def _check(results: dict[str, bool]) -> bool:
    ok = True
    for name, passed in results.items():
        print(f"   {'ok ' if passed else 'FAIL'} {name}")
        ok &= passed
    return ok


# ------------------------------------------------------------------ selfcheck

def cmd_selfcheck(args) -> int:
    """Five checks, all offline, none of which read private/.

    1. Every key scored against its own `expected` must be perfect. If it is
       not, the shape has drifted and the scorer is measuring the key, not
       the model.
    2. A deliberately damaged copy of the invoice key must produce exactly the
       failures planted. If the scorer cannot see a planted hallucination, it
       cannot see a real one.
    3. The PII map, with a made-up map: it must undo a substitution, apply
       longest-first, and must NOT hide an error that survives the undo.
    4. also_accept: a listed alternate is correct; an unlisted one is wrong.
    5. The ruler version moves when a compared block or the map moves, and
       does not move when only an annotation does.
    6. The labelling tool: every key survives a pass through every editor
       byte for byte; a moved row takes its traps and absences with it; an
       invented day next to a printed month is flagged; an illegible slot
       with a model value is a violation.
    """
    corpus, keys = _corpus_and_keys()
    ok = True

    print("1. Each key against itself")
    for doc_id, key in keys.items():
        ds = S.score_document(key, K.strip_annotations(key["expected"]), doc_id)
        perfect = (ds.count("wrong") == ds.count("missed") == ds.count("spurious") == 0
                   and ds.traps_hit == 0 and not ds.absent_violations
                   and ds.got_items == ds.expected_items)
        print(f"   {'ok ' if perfect else 'FAIL'} {ds.summary_line()}")
        ok &= perfect

    print("2. A damaged copy of the invoice key")
    inv = keys["docside_invoice_2025-04-04"]
    inv_exp = K.strip_annotations(inv["expected"])
    bad = copy.deepcopy(inv_exp)
    bad["line_items"][7]["expires_on"] = "2028-03-28"      # trap 1: row 8, the rabies reminder, with an invented day
    bad["clinic"]["fax"] = "410-555-0000"                   # spurious: the page has no fax
    bad["patient"]["age_raw"] = None                        # missed
    bad["owner"]["city"] = "Baltimore, MD"                  # wrong
    bad["line_items"].pop()                                 # one row short
    damaged = S.score_document(inv, bad, "docside_invoice (damaged)")
    dropped_row_values = sum(1 for f in K.LINE_ITEM_FIELDS
                             if f not in K.UNSCORED_LINE_ITEM_FIELDS and inv_exp["line_items"][12].get(f) is not None)
    ok &= _check({
        "trap 1 hit (the invented 28th)":            any(t.id == 1 and t.outcome == "hit" for t in damaged.traps),
        "2 spurious (clinic.fax + invented expiry)": damaged.count("spurious") == 2,
        "1 wrong (owner.city)":                      damaged.count("wrong") == 1,
        f"missed = 1 (age_raw) + {dropped_row_values} (dropped row)":
                                                     damaged.count("missed") == 1 + dropped_row_values,
        "row count 12/13":                           (damaged.got_items, damaged.expected_items) == (12, 13),
        "absent violation on line_items[8].expires_on":
                                                     any(a.path == "line_items[8].expires_on" for a in damaged.absent_violations),
    })

    print("3. The PII map (a made-up one — selfcheck never reads private/)")
    fake = P.PiiMap({"Jane Real": "Marcus Webb", "1 Real St": "88 Chesterfield Row",
                     "Rex": "Nutmeg", "Real": "WRONG-ORDER"})
    page = copy.deepcopy(inv_exp)
    page["owner"]["name"] = "Mr. Jane Real"
    page["owner"]["address_line1"] = "1 Real St"
    page["patient"]["name"] = "Rex"
    without = S.score_document(inv, page, "invoice as the real page, no map")
    with_map = S.score_document(inv, page, "invoice as the real page, mapped", pii=fake)
    unit_on_street = copy.deepcopy(page)
    unit_on_street["owner"]["address_line1"] = "1 Real St #511"
    unit_on_street["owner"]["address_line2"] = None
    still_wrong = S.score_document(inv, unit_on_street, "unit left on the street line", pii=fake)
    ok &= _check({
        "without the map, three correct reads score wrong":  without.count("wrong") == 3,
        "with it, none do, and all three are marked mapped": with_map.count("wrong") == 0 and with_map.pii_mapped_count == 3,
        "longest first: 'Jane Real' is not pre-empted by 'Real'":
            not any("WRONG-ORDER" in str(f.got) for f in with_map.fields),
        "the map undoes the name, not the mistake: '#511' on the street line still fails":
            still_wrong.count("wrong") == 1 and still_wrong.count("missed") == 1,
    })

    print("4. also_accept")
    bv = keys["bettervet_rabies_2024-02-29"]
    alt = copy.deepcopy(K.strip_annotations(bv["expected"]))
    alt["clinic"]["phone"] = "(888) 788-1165"
    alt_ds = S.score_document(bv, alt, "bettervet, header phone")
    alt["clinic"]["phone"] = "888.788.1165"
    unlisted = S.score_document(bv, alt, "bettervet, unprinted form")
    ok &= _check({
        "the header's printed form is correct, and marked as an alternate":
            alt_ds.count("wrong") == 0 and sum(f.accepted_alternate for f in alt_ds.fields) == 1,
        "a form the page never prints is still wrong":
            unlisted.count("wrong") == 1,
    })

    print("5. The ruler version")
    base = K.ruler_version(keys, "map-a")
    noted = copy.deepcopy(keys)
    noted["bettervet_rabies_2024-02-29"]["expected"]["clinic"]["_note"] = "an annotation"
    noted["bettervet_rabies_2024-02-29"]["annotations"] = {"anything": "at all"}
    moved = copy.deepcopy(keys)
    moved["bettervet_rabies_2024-02-29"]["also_accept"]["clinic.phone"].append("888 788 1165")
    ok &= _check({
        "a different PII map is a different ruler":          base != K.ruler_version(keys, "map-b"),
        "a changed compared block is a different ruler":     base != K.ruler_version(moved, "map-a"),
        "an edited annotation is the same ruler":            base == K.ruler_version(noted, "map-a"),
    })

    print("6. The labelling tool (keyform)")
    from . import keyform as F
    for doc_id, key in keys.items():
        original = F.dumps(key)
        k = copy.deepcopy(key)
        for path in F.DOC_PATHS + [f"line_items[{r['n']}].{f}" for r in F.rows(k) for f in K.LINE_ITEM_FIELDS]:
            F.set_value(k, path, F.get(k, path))
            F.set_absence(k, path, F.absence_of(k, path)[0])
        F.set_row_rules(k, F.row_rules(k))
        F.set_traps(k, F.trap_table(k))
        F.set_also_accept(k, F.also_accept_table(k))
        errs, _ = F.validate(k)
        ok &= _check({f"{doc_id}: unchanged through every editor, and valid": F.dumps(k) == original and not errs})
    k = copy.deepcopy(inv)
    term8 = F.get(k, "line_items[8].term")
    F.move_row(k, 8, -1)
    term7_after_move = F.get(k, "line_items[7].term")
    moved_trap_field = next(t for t in k["must_not_produce"] if t["id"] == 1)["field"]
    F.move_row(k, 7, +1)
    k2 = copy.deepcopy(inv)
    F.insert_row(k2, 3)
    F.set_value(k2, "line_items[4].term", "a new printed line")
    ill = copy.deepcopy(inv)
    F.set_absence(ill, "patient.weight_raw", "illegible")
    ill_ds = S.score_document(ill, inv_exp, "invoice, weight marked illegible")
    vocab = F.load_vocabulary()
    ok &= _check({
        "moving row 8 up carries its term and trap 1 to row 7":
            term7_after_move == term8 and moved_trap_field == "line_items[7].expires_on",
        "moving it back restores the key byte for byte":   F.dumps(k) == F.dumps(inv),
        "inserting a row renumbers the traps below it":
            next(t for t in k2["must_not_produce"] if t["id"] == 1)["field"] == "line_items[9].expires_on",
        "'03-28' does not support 2028-03-28 (an invented day)": F.raw_supports_iso("03-28", "2028-03-28") is False,
        "'04-04-25' supports 2025-04-04":                         F.raw_supports_iso("04-04-25", "2025-04-04") is True,
        "'Oct 15, 2025' supports 2025-10-15":                     F.raw_supports_iso("Oct 15, 2025", "2025-10-15") is True,
        "an illegible slot the model filled is an absent violation":
            any(a.path == "patient.weight_raw" and a.outcome == "illegible" for a in ill_ds.absent_violations),
        "review priority reads the database's own rulings: rabies tracked, lepto and a Lyme test lower":
            (F.row_priority("Rabies Vaccination 3 Yr.", vocab), F.row_priority("Leptospirosis 4- Way Vaccine", vocab),
             F.row_priority("Canine Lyme Test", vocab)) == (F.PRIORITY_TRACKED, F.PRIORITY_OTHER, F.PRIORITY_OTHER),
        "a term with no ruling fails closed to one-by-one checking":
            F.row_priority("Client Info: Rabies Vaccine", vocab) == F.PRIORITY_UNKNOWN,
        "the normaliser matches sql/15: spacing round '-' and '/', a trailing '.'":
            F.normalize_term("  Leptospirosis 4 - Way  Vaccine. ") == "leptospirosis 4-way vaccine",
        "'?' scoring: exact match correct, a filled-in digit overconfident, a ? for a readable digit missed":
            [S._partial_outcome("Jan 2?, 2027", g) for g in ("Jan 2?, 2027", "Jan 29, 2027", "Jan ??, 2027",
                                                             "Feb 2?, 2027", "Jan 2?, 27")]
            == ["correct", "overconfident", "missed", "wrong", "wrong"],
        "an ISO date beside a partly read print is overconfident, not spurious":
            _partial_iso_outcome(inv) == "overconfident",
        "the labelling tool refuses an ISO date beside a partly read print":
            any("partly read" in e for e in F.validate(_partial_iso_key(inv))[0]),
        "a trap whose wrong value is the key's own value is refused":
            any("trap 9" in e or "which is the key's own value" in e
                for e in F.validate(_trap_on_own_value(inv))[0]),
    })

    print()
    print(S.render([damaged]))
    print()
    print("SELFCHECK", "PASSED" if ok else "FAILED")
    return 0 if ok else 1


def _partial_iso_key(key: dict) -> dict:
    """The invoice key with row 2's printed date partly read, ISO left filled."""
    k = copy.deepcopy(key)
    k["expected"]["line_items"][1]["administered_on_raw"] = "04-0?-25"
    return k


def _partial_iso_outcome(key: dict) -> str:
    k = _partial_iso_key(key)
    k["expected"]["line_items"][1]["administered_on"] = None
    got = copy.deepcopy(K.strip_annotations(key["expected"]))      # the model gives the full date
    ds = S.score_document(k, got, "partial")
    return next(f.outcome for f in ds.fields if f.path == "line_items[2].administered_on")


def _trap_on_own_value(key: dict) -> dict:
    """The mistake the self-check caught twice in the invoice key: a trap
    pointing at a row whose expected value already IS the wrong value."""
    k = copy.deepcopy(key)
    k["must_not_produce"].append({"id": 99, "layer": "extraction", "field": "line_items[2].term",
                                  "wrong_value": K.strip_annotations(key["expected"])["line_items"][1]["term"]})
    return k


# ------------------------------------------------------------------------ run

def cmd_run(args) -> int:
    from . import extract as X
    corpus, keys = _corpus_and_keys()
    model = args.model or X.default_model()
    prompt_path = Path(args.prompt).resolve()
    wanted = sorted(set(args.doc) if args.doc else set(corpus))
    missing = [d for d in wanted if not corpus[d].file_path.exists()]
    if missing:
        print("These documents are not in private/:", *missing, sep="\n  ")
        return 2
    run_dir = X.new_run_dir()
    print(f"run     {run_dir}")
    print(f"model   {model}")
    print(f"prompt  {X.prompt_version(prompt_path)}")
    for doc_id in wanted:
        out = X.extract_one(corpus[doc_id], prompt_path, model, run_dir)
        rec = json.loads(out.read_text(encoding="utf-8"))
        state = f"parse error: {rec['parse_error']}" if rec["parse_error"] else \
                f"{len(rec['output'].get('line_items') or [])} line items"
        print(f"  {doc_id:<38} {rec['usage']['input_tokens']:>6} in {rec['usage']['output_tokens']:>5} out   {state}")
    print()
    return cmd_score(argparse.Namespace(run_dir=str(run_dir), verbose=args.verbose))


# ---------------------------------------------------------------------- score

def _score_run(run_dir: Path, keys: dict, pii: P.PiiMap) -> dict[str, S.DocScore]:
    scores = {}
    for rec_path in sorted(run_dir.glob("*.json")):
        if rec_path.name == "score.json":
            continue
        rec = json.loads(rec_path.read_text(encoding="utf-8"))
        doc_id = rec["document_id"]
        if doc_id not in keys:
            print(f"skipping {rec_path.name}: no key for {doc_id}")
            continue
        scores[doc_id] = S.score_document(keys[doc_id], rec.get("output"), doc_id, rec.get("parse_error"), pii)
    return scores


def cmd_score(args) -> int:
    corpus, keys = _corpus_and_keys()
    pii = P.load()
    ruler = K.ruler_version(keys, pii.digest)
    run_dir = Path(args.run_dir)
    scores = _score_run(run_dir, keys, pii)
    if not scores:
        print(f"nothing to score in {run_dir}")
        return 2
    header = f"{P.status_line(pii)}\nruler {ruler}   contract {K.CONTRACT_VERSION}   run {run_dir.name}"
    print(S.render(list(scores.values()), verbose=args.verbose, header=header))
    (run_dir / "score.json").write_text(
        json.dumps(S.to_json(list(scores.values()), ruler), indent=2, default=str) + "\n", encoding="utf-8")
    print(f"\nwritten {run_dir / 'score.json'}   (nothing written to the database — use `load` for that)")
    return 0


# ----------------------------------------------------------------------- load

def cmd_load(args) -> int:
    from . import db
    corpus, keys = _corpus_and_keys()
    pii = P.load()
    ruler = K.ruler_version(keys, pii.digest)
    run_dir = Path(args.run_dir)
    print(P.status_line(pii))
    scores = _score_run(run_dir, keys, pii)
    for line in db.load_run(run_dir, corpus, keys, scores, ruler, len(pii)):
        print(line)
    return 0


# ------------------------------------------------------------------------ cli

def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="harness", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("selfcheck", help="prove the scorer offline").set_defaults(fn=cmd_selfcheck)

    r = sub.add_parser("run", help="send the corpus to the model and score the result")
    r.add_argument("--doc", action="append", help="document_id from corpus.json (repeatable)")
    r.add_argument("--model", help="overrides EXTRACTION_MODEL")
    r.add_argument("--prompt", default=str(Path(__file__).resolve().parent.parent / "prompt_v1.md"))
    r.add_argument("-v", "--verbose", action="store_true")
    r.set_defaults(fn=cmd_run)

    s = sub.add_parser("score", help="score an existing run (no side effects)")
    s.add_argument("run_dir")
    s.add_argument("-v", "--verbose", action="store_true")
    s.set_defaults(fn=cmd_score)

    l = sub.add_parser("load", help="load a run into the database and record its score")
    l.add_argument("run_dir")
    l.set_defaults(fn=cmd_load)

    args = p.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
