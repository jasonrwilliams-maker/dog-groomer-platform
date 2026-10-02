"""The Review screen: a model run against its key, one disagreement at a time."""
from __future__ import annotations

import copy
import json
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
import streamlit as st

from common import (F, K, PROBLEMS, STATUS_BY_CAT, load_verdicts, page_viewer, review_file)
from harness import pii as P  # noqa: E402  (common put the harness on the path)
from harness import score as S  # noqa: E402  (common put the harness on the path)


# ============================================================== Review screen

def save_verdict(run_record_path: Path, path: str, verdict: str, note: str, key: dict, got, expected):
    p = review_file(run_record_path)
    data = json.loads(p.read_text(encoding="utf-8")) if p.exists() else {"verdicts": {}}
    data["verdicts"][path] = {"verdict": verdict, "note": note or None, "key_value": expected, "model_value": got,
                              "on": datetime.now(timezone.utc).isoformat(timespec="seconds")}
    F.write(p, data)


VERDICTS_OVERCONFIDENT = {
    "model_wrong": "The model guessed — the key's ? stands",
    "key_wrong": "It is readable after all — use the model's reading",
}
VERDICTS = {
    "model_wrong": "The model is wrong — the key stands",
    "key_wrong": "The key is wrong — use the model's reading",
    "also_accept": "Both are right — the page prints this fact twice (also accept)",
}


def screen_review(item: dict):
    file = item["file"]
    st.subheader(f"Review · {item['document_id'] or file.name}")
    if not item["runs"]:
        st.info("The model hasn't read this document yet.")
        if item["key_path"]:
            st.write("Send it to the model on the **Run & test** screen.")
        else:
            st.write("Label it first, on the **Label** screen, so the run is a real test.")
        return
    run = st.selectbox("Run", item["runs"],
                       format_func=lambda r: f"{r['stamp']}  ·  {r['model']}  ·  {r['prompt']}")
    rec_path = Path(run["path"])
    rec = json.loads(rec_path.read_text(encoding="utf-8"))

    if not item["key_path"]:
        st.warning("**No published key yet.** This document is still unseen. Label it first — once you've "
                   "looked at the model's reading, a key written afterwards is graded against the model's "
                   "answer rather than the page.")
        if not st.checkbox("Show the model's reading anyway — this document stops being a held-out test"):
            return
        left, right = st.columns([5, 6], gap="large")
        page_viewer(file, left)
        with right:
            st.json(rec.get("output") or {"parse_error": rec.get("parse_error")})
        return

    key = K.load_key(item["key_path"])
    pii = P.load()
    ds = S.score_document(key, rec.get("output"), item["document_id"], rec.get("parse_error"), pii)
    verdicts = load_verdicts(rec_path)
    if rec.get("stop_reason") == "max_tokens":
        used = (rec.get("usage") or {}).get("output_tokens")
        st.error(f"**The model ran out of room before finishing.** It used all {used} output tokens it was "
                 f"allowed — most of them thinking — and its answer stops partway through. Nothing is wrong "
                 "with the document or the key. Run it again from **Run & test**: runs now allow 16,000 tokens.")
        st.caption("What it wrote before being cut off:")
        st.code(rec.get("raw_response", "")[-3000:])
        return
    if rec.get("parse_error"):
        st.error(f"The response didn't parse: {rec['parse_error']}")
        st.code(rec.get("raw_response", "")[:4000])
        return

    m = st.columns(8)
    m[0].metric("Rows", f"{ds.got_items}/{ds.expected_items}")
    m[1].metric("Correct", f"{ds.count('correct')}/{ds.scored}")
    m[2].metric("Wrong", ds.count("wrong"))
    m[3].metric("Missed", ds.count("missed"))
    m[4].metric("Spurious", ds.count("spurious"), help="A value where the page has none — the hallucination class.")
    m[5].metric("Overconfident", ds.count("overconfident"),
                help="A character filled in where the key reads ? — printed, but not readable. A lucky guess and "
                     "a wrong one look the same, so neither counts as correct.")
    m[6].metric("Traps hit", f"{ds.traps_hit}/{ds.traps_scorable}")
    m[7].metric("Absence violations", len(ds.absent_violations))
    if rec.get("prepared"):
        pn = rec["prepared"]
        st.caption(f"Sent as a {pn['sent_size'][0]}×{pn['sent_size'][1]} image"
                   + (", turned upright" if pn.get("exif_orientation") not in (None, 1) else "")
                   + (", GPS removed" if pn.get("had_gps") else "") + ".")
    if ds.got_items != ds.expected_items:
        st.warning(f"The model produced {ds.got_items} rows and the page has {ds.expected_items}. Rows are compared "
                   "by number, so every row after a missing or extra one shows up below as a disagreement — "
                   "fix the first one and read the rest with that in mind.")

    left, right = st.columns([5, 6], gap="large")
    page_viewer(file, left)
    with right:
        problems = [f for f in ds.fields if f.outcome in PROBLEMS]
        absent_by_path = {a.path: a.outcome for a in ds.absent_violations}
        hits = {}
        for t in ds.traps:
            if t.outcome == "hit":
                hits.setdefault(t.got.split(" = ")[0] if t.got else t.field, []).append(t)
        open_items = [f for f in problems if f.path not in verdicts]
        done_items = [f for f in problems if f.path in verdicts]
        tabs = st.tabs([f"To reconcile ({len(open_items)})", f"Reconciled ({len(done_items)})",
                        f"Traps ({ds.traps_hit} hit)", "Everything side by side"])
        with tabs[0]:
            if not open_items:
                st.success("Nothing left to reconcile on this run.")
            for f in open_items:
                reconcile_card(f, key, item, rec_path, run, absent_by_path.get(f.path), hits.get(f.path, []))
        with tabs[1]:
            for f in done_items:
                v = verdicts[f.path]
                st.markdown(f"**{f.path}** — {VERDICTS.get(v['verdict'], v['verdict'])}"
                            + (f"  \n_{v['note']}_" if v.get("note") else ""))
                st.caption(f"key: {f.expected!r}   ·   model: {f.got!r}   ·   {v['on']}")
            relabelled = (key.get("annotations") or {}).get("relabelled") if isinstance(key.get("annotations"), dict) else None
            if relabelled:
                st.markdown("**Key corrections recorded in the key** (`annotations.relabelled`)")
                st.dataframe(pd.DataFrame(relabelled), hide_index=True, width="stretch")
        with tabs[2]:
            st.dataframe(pd.DataFrame([{"id": t.id, "field": t.field, "wrong value": str(t.wrong_value),
                                        "outcome": t.outcome, "model produced": t.got, "note": t.note}
                                       for t in ds.traps]), hide_index=True, width="stretch")
        with tabs[3]:
            only = st.toggle("Only disagreements", value=False)
            rows = [{"field": f.path, "key": _s(f.expected), "model": _s(f.got), "outcome": f.outcome,
                     "via PII map": "yes" if f.pii_mapped else "", "alternate form": "yes" if f.accepted_alternate else ""}
                    for f in ds.fields if not only or f.outcome in PROBLEMS]
            st.dataframe(pd.DataFrame(rows), hide_index=True, width="stretch", height=600)


def _s(v):
    return None if v is None else str(v)


def reconcile_card(f: S.FieldResult, key: dict, item: dict, rec_path: Path, run: dict,
                   absent_cat: str | None, traps: list):
    with st.container(border=True):
        badge = {"wrong": "🟠 wrong", "missed": "🔵 missed", "spurious": "🔴 spurious",
                 "overconfident": "🟣 overconfident — filled in a character the key reads as ?"}[f.outcome]
        st.markdown(f"**{f.path}** &nbsp; {badge}")
        c1, c2 = st.columns(2)
        c1.markdown("Key says")
        c1.code("null" if f.expected is None else str(f.expected), language=None)
        c2.markdown("Model read")
        c2.code("null" if f.got is None else str(f.got), language=None)
        notes = []
        if absent_cat:
            notes.append(f"the key marks this slot **{STATUS_BY_CAT.get(absent_cat, absent_cat)}**")
        for t in traps:
            notes.append(f"it is **trap {t.id}** — the wrong answer the key predicted")
        if f.pii_mapped:
            notes.append("the model's value is shown after the PII map")
        if notes:
            st.caption("Note: " + "; ".join(notes) + ".")
        options = ["model_wrong", "key_wrong"] + (["also_accept"] if f.outcome == "wrong" else [])
        wording = VERDICTS_OVERCONFIDENT if f.outcome == "overconfident" else VERDICTS
        choice = st.radio("Verdict", options, format_func=wording.get, key=f"v|{run['stamp']}|{f.path}",
                          index=None, label_visibility="collapsed")
        note = st.text_input("Why (optional, but future-you will want it)", key=f"n|{run['stamp']}|{f.path}")
        if choice == "key_wrong":
            st.caption("This changes the published key, and records the change in `annotations.relabelled` "
                       "— that slot is no longer blind. Check the page first.")
        if st.button("Record", key=f"b|{run['stamp']}|{f.path}", disabled=choice is None):
            if choice in ("key_wrong", "also_accept"):
                k = copy.deepcopy(key)
                run_label = f"{run['stamp']}/{rec_path.stem}"
                refusal = (F.adopt_model_value(k, f.path, f.got, note, run_label) if choice == "key_wrong"
                           else F.add_also_accept(k, f.path, f.got, note, run_label))
                if refusal:
                    st.error(refusal)
                    return
                errors, _ = F.validate(k, P.load())
                if errors:
                    st.error("That change would make the key invalid:\n\n" + "\n".join(f"- {e}" for e in errors))
                    return
                F.write(item["key_path"], k)
            save_verdict(rec_path, f.path, choice, note, key, f.got, f.expected)
            st.rerun()
