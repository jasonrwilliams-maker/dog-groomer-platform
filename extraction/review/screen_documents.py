"""The Documents screen: what is in private/, and where each document stands."""
from __future__ import annotations

import json
from pathlib import Path

import pandas as pd
import streamlit as st

from common import (K, PROBLEMS, STATUS_COLOUR, STATUS_MARK, load_verdicts, status_word)
from harness import pii as P  # noqa: E402  (common put the harness on the path)
from harness import score as S  # noqa: E402  (common put the harness on the path)


# =========================================================== Documents screen

def screen_documents(items: list[dict]):
    st.header("What has been submitted")
    st.caption("Every document in `private/`. A document is labelled when its answer key is published; "
               "a model run is only worth reading once it is — that is what keeps it a held-out test.")
    pii = P.load()
    table = []
    for it in items:
        latest = it["runs"][0] if it["runs"] else None
        row = {"document": it["document_id"] or "—", "file": it["file"].name, "key": status_word(it),
               "model runs": len(it["runs"]), "latest run": latest["stamp"] if latest else "—"}
        if latest and it["key_path"]:
            key = K.load_key(it["key_path"])
            rec = json.loads(Path(latest["path"]).read_text(encoding="utf-8"))
            ds = S.score_document(key, rec.get("output"), it["document_id"], rec.get("parse_error"), pii)
            problems = [f.path for f in ds.fields if f.outcome in PROBLEMS]
            verdicts = load_verdicts(Path(latest["path"]))
            row.update({"correct": f"{ds.count('correct')}/{ds.scored}", "wrong": ds.count("wrong"),
                        "missed": ds.count("missed"), "spurious": ds.count("spurious"),
                        "overconfident": ds.count("overconfident"),
                        "traps hit": f"{ds.traps_hit}/{ds.traps_scorable}",
                        "to reconcile": sum(1 for p in problems if p not in verdicts)})
        elif latest:
            row.update({"correct": "no key yet"})
        blind = None
        if it["key_path"]:
            blind = "yes" if K.load_key(it["key_path"])["meta"].get("_labelled_blind") else "—"
        row["labelled before any run"] = blind or "—"
        table.append(row)
    # What needs a human first; the long file names last.
    order = ["document", "key", "to reconcile", "correct", "wrong", "missed", "spurious", "overconfident", "traps hit",
             "model runs", "latest run", "labelled before any run", "file"]
    df = pd.DataFrame(table)
    df = df[[c for c in order if c in df.columns]]
    styled = df.style.map(lambda v: f"background-color: {STATUS_COLOUR[v]}" if v in STATUS_COLOUR else "",
                          subset=["key"])
    if "to reconcile" in df.columns:
        styled = styled.map(lambda v: "background-color: rgba(240, 180, 40, .30)"
                            if isinstance(v, (int, float)) and v == v and v > 0 else "", subset=["to reconcile"])
    st.dataframe(styled, width="stretch", hide_index=True)
    st.caption("🔴 no key yet   🟡 a draft in progress, or edits not yet published   🟢 key published")

    waiting = [it for it in items if status_word(it) != "labelled"]
    if waiting:
        st.subheader("Next up")
        for it in waiting:
            ran = " — ⚠ the model has already read it; label it without looking at that run" if it["runs"] else ""
            st.markdown(f"- {STATUS_MARK[status_word(it)]} **{it['file'].name}** is {status_word(it)}{ran}. "
                        "Open it on the **Label** screen.")
    st.subheader("After labelling")
    st.markdown("Send a labelled document to the model on the **Run & test** screen, then open it on "
                "the **Review** screen.")
