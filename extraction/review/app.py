"""The labelling and review tool.

    Documents   what has been submitted, and where each one stands
    Label       write a document's answer key by looking at the page — never at the model
    Review      what the model read, against the key, and what needs reconciling

Run it with `docker compose --profile review up review` and open
http://localhost:8501. Everything it writes is either a key in
extraction/answer_keys/ (committed, anonymised), a draft in private/drafts/, or
a review verdict inside a run directory in extraction/runs/ (both gitignored).

Labelling and reviewing are deliberately different screens. A form that
arrives pre-filled with the model's answer makes accepting it the easy path,
and then the key grades the model against itself. So the Label screen never
shows the model's reading, and the Review screen only corrects a key one
recorded slot at a time, with a reason, after the page has been looked at.
"""
from __future__ import annotations

import copy
import json
import math
import re
import sys
from datetime import date, datetime, timezone
from pathlib import Path

import pandas as pd
import streamlit as st

HARNESS_DIR = Path(__file__).resolve().parents[1] / "harness"
sys.path.insert(0, str(HARNESS_DIR))
import importlib                    # noqa: E402

import harness.keys                 # noqa: E402
import harness.pii                  # noqa: E402
import harness.score                # noqa: E402
import harness.prep                 # noqa: E402
import harness.keyform              # noqa: E402


def _reload_harness_if_changed():
    """Streamlit reloads this file when it changes, but not the harness
    modules it imports from outside this folder — a running app would keep
    the old keyform after an edit. Reload them, in dependency order, whenever
    any of their files is newer than what is loaded."""
    stamp = max(p.stat().st_mtime for p in (HARNESS_DIR / "harness").glob("*.py"))
    if stamp != getattr(harness, "_loaded_stamp", None):
        for mod in (harness.keys, harness.pii, harness.score, harness.prep, harness.keyform):
            importlib.reload(mod)
        harness._loaded_stamp = stamp


import harness                      # noqa: E402
_reload_harness_if_changed()
from harness import keyform as F    # noqa: E402
from harness import keys as K       # noqa: E402
from harness import pii as P        # noqa: E402
from harness import score as S      # noqa: E402
from harness.prep import prepare_image   # noqa: E402

import ops                          # noqa: E402  (this folder: the terminal commands, runnable from the page)

RUNS_DIR = K.EXTRACTION_DIR / "runs"
FIXTURE = K.EXTRACTION_DIR.parent / "sql" / "seed" / "fixture.sql"

STATUS = {                       # what the labeller picks -> absent category
    "": None,
    "blank on page": "labeled_but_blank",
    "unfilled form question": "unfilled_form_fields",
    "not on this format": "not_present",
    "illegible": "illegible",
}
STATUS_BY_CAT = {v: k for k, v in STATUS.items()}
STATUS_HELP = ("Leave empty when you typed a value, or when the page simply has nothing here.  \n"
               "**blank on page** — the label is printed and left empty.  \n"
               "**unfilled form question** — a printed question nobody answered.  \n"
               "**not on this format** — this kind of document never carries it.  \n"
               "**illegible** — something is printed and you cannot read it. Say what you *can* see in a note.")

HELP = {
    "document.as_of_date": "A date the page states about ITSELF — printed on, report date, 'as of'. Not a vaccination date. YYYY-MM-DD.",
    "clinic.address_raw": "One string. Printed over several lines? Join them with a single space, adding no punctuation.",
    "owner.address_line1": "Street and number only. A unit (#511, Apt 511) goes in line 2, exactly as printed.",
    "owner.address_line2": "The unit designator exactly as printed: '#511', 'Apt 511'.",
    "patient.breed_raw": "Verbatim — 'Shih Tzu Mix' stays one string.",
    "patient.sex_raw": "Verbatim — 'Spayed Female' stays one string.",
    "patient.date_of_birth": "Only if the page prints a DATE. Never work it out from an age. YYYY-MM-DD.",
    "patient.age_raw": "Only if the page prints an AGE, as printed: '16m', '2 yrs'.",
    "patient.tag_number": "A rabies tag printed in the patient header. One printed with the vaccination goes on the row.",
    "term": "Exactly as printed, capitalisation and punctuation included. Don't decide whether it is a vaccine.",
    "source_region": "Where on the page the row sits: services_billed, reminders, vaccinations_table… Not scored.",
    "administered_on_raw": "The date as printed: '04-04-25', 'Oct 15, 2025'.",
    "administered_on": "YYYY-MM-DD — only when the printed form states year, month AND day.",
    "expires_on_raw": "The expiry or due date as printed. '03-28' is a month; it lives here and nowhere else.",
    "expires_on": "YYYY-MM-DD — only a full date printed for THIS row. Never derived, never a lot's expiry.",
    "status_raw": "A status word printed on the row: Active, Due, Overdue.",
    "veterinarian_phone": "A vet's own number. A clinic switchboard is not a vet's phone.",
    "tag_number": "A rabies tag printed with this vaccination.",
}
DOC_SECTIONS = {"document": "Document", "clinic": "Clinic", "owner": "Owner", "patient": "Patient"}
ROW_FIELDS = [f for f in K.LINE_ITEM_FIELDS]

st.set_page_config(page_title="Vaccination records — labelling & review", page_icon="🐕", layout="wide")


# =============================================================== inventory

def rel(path: Path) -> str:
    return str(path.relative_to(K.EXTRACTION_DIR.parent)).replace("\\", "/")


@st.cache_data(show_spinner=False)
def _run_records(sig: tuple) -> list[dict]:
    out = []
    for stamp_dir in sorted(RUNS_DIR.glob("*/"), reverse=True):
        for p in stamp_dir.glob("*.json"):
            if p.name == "score.json":
                continue
            try:
                rec = json.loads(p.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError):
                continue
            if "document_id" in rec and "output" in rec:
                out.append({"stamp": stamp_dir.name, "path": str(p), "document_id": rec["document_id"],
                            "source_file": rec.get("source_file"), "model": rec.get("model_name"),
                            "prompt": rec.get("prompt_version"), "parse_error": rec.get("parse_error")})
    return out


def run_records() -> list[dict]:
    if not RUNS_DIR.exists():
        return []
    sig = tuple(sorted((str(p), p.stat().st_mtime) for p in RUNS_DIR.glob("*/*.json")))
    return _run_records(sig)


def drafts_by_file() -> dict[str, Path]:
    out = {}
    if F.DRAFTS_DIR.exists():
        for p in F.DRAFTS_DIR.glob("*.key.json"):
            try:
                out[json.loads(p.read_text(encoding="utf-8"))["meta"]["source_file"]] = p
            except (json.JSONDecodeError, KeyError, OSError):
                pass
    return out


def inventory() -> list[dict]:
    """One row per document in private/: what it is, whether it has a key,
    and whether the model has read it."""
    corpus = F.load_corpus_json()["documents"]
    by_file = {Path(d["file"]).name: d for d in corpus}
    drafts = drafts_by_file()
    runs = run_records()
    rows = []
    for f in F.private_files():
        entry = by_file.get(f.name)
        doc_id = entry["document_id"] if entry else None
        key_path = (K.EXTRACTION_DIR / entry["key"]).resolve() if entry else None
        draft = drafts.get(f.name)
        if doc_id is None and draft is not None:
            doc_id = json.loads(draft.read_text(encoding="utf-8"))["meta"]["document_id"]
        doc_runs = [r for r in runs if r["source_file"] == f.name or (doc_id and r["document_id"] == doc_id)]
        rows.append({
            "file": f, "document_id": doc_id, "entry": entry,
            "key_path": key_path if key_path and key_path.exists() else None,
            "draft_path": draft, "runs": doc_runs,
        })
    return rows


def status_word(item: dict) -> str:
    if item["key_path"]:
        return "labelled"
    if item["draft_path"]:
        return "draft"
    return "not labelled"


STATUS_MARK = {"not labelled": "🔴", "draft": "🟡", "labelled": "🟢"}
STATUS_COLOUR = {"not labelled": "rgba(230, 70, 70, .28)", "draft": "rgba(240, 180, 40, .30)",
                 "labelled": "rgba(60, 170, 90, .25)"}


def label_of(item: dict) -> str:
    name = item["document_id"] or item["file"].name
    return f"{STATUS_MARK[status_word(item)]} {name}  ·  {status_word(item)}"


# ================================================================== pages

@st.cache_data(show_spinner="Rendering the page…")
def render_pages(path_str: str, mtime: float) -> tuple[list[bytes], dict | None]:
    """PNG bytes per page. A photo goes through the same prep the model's copy
    does, so the labeller sees exactly the image the model is sent."""
    path = Path(path_str)
    if path.suffix.lower() == ".pdf":
        import pymupdf
        with pymupdf.open(path) as doc:
            return [page.get_pixmap(dpi=144).tobytes("png") for page in doc], None
    prepared = prepare_image(path)
    return [prepared.data], prepared.notes


def page_viewer(path: Path, where) -> int:
    pages, notes = render_pages(str(path), path.stat().st_mtime)
    with where:
        c1, c2 = st.columns([1, 2])
        page = c1.selectbox("Page", range(1, len(pages) + 1), key=f"page|{path.name}") if len(pages) > 1 else 1
        zoom = c2.slider("Zoom", 50, 250, 100, step=10, key=f"zoom|{path.name}", format="%d%%")
        if notes:
            bits = [f"sent at {notes['sent_size'][0]}×{notes['sent_size'][1]}"]
            if notes.get("exif_orientation") not in (None, 1):
                bits.append("turned upright")
            if notes.get("had_gps"):
                bits.append("GPS removed")
            st.caption("Prepared exactly as the model receives it: " + ", ".join(bits) + ".")
        if zoom == 100:
            st.image(pages[page - 1], width="stretch")
        else:
            # Wider than the column: scroll inside a fixed-height box.
            import base64
            b64 = base64.b64encode(pages[page - 1]).decode()
            st.html(f'<div style="height:78vh;overflow:auto;border:1px solid rgba(128,128,128,.3);border-radius:6px">'
                    f'<img src="data:image/png;base64,{b64}" style="width:{zoom}%;max-width:none;display:block"></div>')
    return len(pages)


# ================================================================= helpers

def gen() -> int:
    return st.session_state.setdefault("gen", 0)


def wk(*parts) -> str:
    return f"{gen()}|" + "|".join(str(p) for p in parts)


def bump():
    st.session_state.gen = gen() + 1


def records(df: pd.DataFrame) -> list[dict]:
    out = []
    for r in df.to_dict("records"):
        out.append({k: (None if isinstance(v, float) and math.isnan(v) else v) for k, v in r.items()})
    return out


def open_draft(key: dict, source: str, file: Path, disk_text: str | None):
    st.session_state.draft = key
    st.session_state.draft_source = source          # published | draft | new
    st.session_state.draft_file = file.name
    st.session_state.saved_text = disk_text          # what is on disk, for "unsaved changes"
    st.session_state.rule_orig = F.rule_originals(key)
    st.session_state.trap_orig = F.trap_originals(key)
    bump()


def close_draft():
    for k in ("draft", "draft_source", "draft_file", "saved_text", "rule_orig", "trap_orig"):
        st.session_state.pop(k, None)
    bump()


NO_HOUSEHOLD = "__none__"


def fixture_choices() -> tuple[dict, dict]:
    """Owners and dogs from sql/seed/fixture.sql, for corpus.json."""
    owners, dogs = {}, {}
    if FIXTURE.exists():
        text = FIXTURE.read_text(encoding="utf-8")
        for oid, first, last in re.findall(r"\('([0-9a-f-]+a\d{3})',\s*'([^']+)',\s*'([^']+)'", text):
            owners[oid] = f"{first} {last}"
        for did, oid, name in re.findall(r"\('([0-9a-f-]+d\d{3})',\s*'([0-9a-f-]+a\d{3})',\s*'([^']+)'", text):
            dogs[did] = f"{name} ({owners.get(oid, oid[-4:])})"
    return owners, dogs


@st.cache_data(show_spinner=False)
def _vocabulary(stamp: float) -> tuple[dict, set]:
    return F.load_vocabulary()


def vocabulary() -> tuple[dict, set]:
    """The database's own term rulings and tracking flags, read from the seed
    SQL. Orders the review; written into no key."""
    stamp = max(p.stat().st_mtime for p in F.SQL_DIR.glob("*.sql"))
    return _vocabulary(stamp)


PRIORITY_BADGE = {F.PRIORITY_TRACKED: "🔴 tracked vaccine", F.PRIORITY_UNKNOWN: "🟠 no ruling yet",
                  F.PRIORITY_OTHER: "⚪ lower priority"}


def suggest_id(file: Path) -> str:
    stem = re.sub(r"[^a-z0-9]+", "_", file.stem.lower()).strip("_")
    return stem or "new_document"


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
            problems = [f.path for f in ds.fields if f.outcome in ("wrong", "missed", "spurious")]
            verdicts = load_verdicts(Path(latest["path"]))
            row.update({"correct": f"{ds.count('correct')}/{ds.scored}", "wrong": ds.count("wrong"),
                        "missed": ds.count("missed"), "spurious": ds.count("spurious"),
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
    order = ["document", "key", "to reconcile", "correct", "wrong", "missed", "spurious", "traps hit",
             "model runs", "latest run", "labelled before any run", "file"]
    df = pd.DataFrame(table)
    df = df[[c for c in order if c in df.columns]]
    styled = df.style.map(lambda v: f"background-color: {STATUS_COLOUR[v]}" if v in STATUS_COLOUR else "",
                          subset=["key"])
    if "to reconcile" in df.columns:
        styled = styled.map(lambda v: "background-color: rgba(240, 180, 40, .30)"
                            if isinstance(v, (int, float)) and v == v and v > 0 else "", subset=["to reconcile"])
    st.dataframe(styled, width="stretch", hide_index=True)
    st.caption("🔴 no key yet   🟡 a draft in progress   🟢 key published")

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


# =============================================================== Label screen

def screen_label(item: dict):
    file = item["file"]
    loaded = st.session_state.get("draft_file") == file.name and "draft" in st.session_state
    if not loaded:
        label_start(item)
        return

    key = st.session_state.draft
    src = st.session_state.draft_source
    top = st.columns([5, 1, 1.4])
    top[0].subheader(f"Labelling {key['meta'].get('document_id') or file.name}")
    if top[1].button("Close", help="Your edits are kept as a draft in private/drafts/.", width="stretch"):
        close_draft()
        st.rerun()
    discard_label = "Discard changes" if src == "published" else "Discard draft"
    with top[2].popover(f"🗑 {discard_label}", width="stretch"):
        if src == "published":
            st.write("Throw away your edits and go back to the published key?")
        else:
            st.write("Throw away this draft and start again from nothing? This can't be undone.")
        if st.button("Yes, discard", type="primary"):
            dp = F.draft_path(key["meta"].get("document_id") or "")
            if dp.exists():
                dp.unlink()
            close_draft()
            st.rerun()
    st.caption("The model's reading is never shown here. Type what the page prints; a blank box means null, "
               "and null is a correct answer.")
    banner = st.empty()      # filled at the end of the run, so its count is never one click behind

    left, right = st.columns([5, 6], gap="large")
    page_count = page_viewer(file, left)
    _label_tabs(key, item, src, right, page_count)

    left_to_check = F.unchecked(key)
    if left_to_check:
        groups = F.bulk_checkable(key, vocabulary())
        in_bulk = sum(len(v) for v in groups.values())
        banner.warning(
            f"**{len(left_to_check)} values from {key['meta'].get('_started_from')} still to check against this page.** "
            f"{len(left_to_check) - in_bulk} are on 🔴 tracked-vaccine or 🟠 unruled rows and are checked one by one; "
            f"{in_bulk} are in the page header or ⚪ lower-priority rows and can be checked a section at a time. "
            "Change a value if it doesn't match, or mark it illegible if you can't read it *here* — even if you "
            "know it from another document. Publishing waits until all are checked.")
    autosave(key)


def _label_tabs(key: dict, item: dict, src: str, right, page_count: int):
    with right:
        tabs = st.tabs(["① Page header", "② Rows", "③ Traps", "④ Check & publish", "More…"])
        with tabs[0]:
            tab_doc_fields(key)
        with tabs[1]:
            tab_rows(key)
            with st.expander("Rules for every row — e.g. this format never prints a lot number"):
                tab_rules(key)
        with tabs[2]:
            tab_traps(key)
        with tabs[3]:
            with st.expander("About this document", expanded=src == "new"):
                tab_about(key, item, page_count)
            tab_publish(key, item)
        with tabs[4]:
            st.markdown("**Also accept** — rarely needed")
            tab_also_accept(key)
            st.divider()
            st.markdown("**PII map**")
            tab_pii()


def label_start(item: dict):
    file = item["file"]
    st.subheader(file.name)
    if item["key_path"]:
        st.write("This document has a published key.")
        if item["draft_path"]:
            st.info("There is also an unpublished draft of it.")
            if st.button("Continue the draft", type="primary"):
                text = item["draft_path"].read_text(encoding="utf-8")
                open_draft(json.loads(text), "draft", file, text)
                st.rerun()
        if st.button("Open the published key" if not item["draft_path"] else "Discard the draft and open the published key"):
            if item["draft_path"]:
                item["draft_path"].unlink()
            text = item["key_path"].read_text(encoding="utf-8")
            open_draft(K.load_key(item["key_path"]), "published", file, text)
            st.rerun()
        return
    if item["draft_path"]:
        st.write("You have a draft for this document.")
        c1, c2, _ = st.columns([1, 1, 3])
        if c1.button("Continue the draft", type="primary", width="stretch"):
            text = item["draft_path"].read_text(encoding="utf-8")
            open_draft(json.loads(text), "draft", file, text)
            st.rerun()
        with c2.popover("🗑 Discard the draft", width="stretch"):
            st.write("Throw the draft away and start again? This can't be undone.")
            if st.button("Yes, discard", type="primary"):
                item["draft_path"].unlink()
                st.rerun()
        return

    if item["runs"]:
        st.warning(f"The model has already read this file ({len(item['runs'])} run(s)). Label it from the page "
                   "without opening those runs, and it can still serve as a test.")
    doc_id = st.text_input("Document id", suggest_id(file),
                           help="Lower-case, no spaces. The convention so far: clinic_kind_YYYY-MM-DD, "
                                "e.g. bettervet_rabies_2024-02-29.")
    how = st.radio("Start from", ["A blank key", "Parts of an existing key"], horizontal=True,
                   help="Copy parts of an existing key when this page is the same clinic, or the same document "
                        "in another form — a photo of a screenshot, a reprint.")
    template, blocks = None, set()
    if how == "Parts of an existing key":
        published = sorted(K.KEYS_DIR.glob("*.key.json"))
        choice = st.selectbox("Which key?", published, index=None, placeholder="Choose a key…",
                              format_func=lambda p: p.name.replace(".key.json", ""))
        if choice:
            st.markdown("**What to copy** — anything you don't tick starts blank. Traps are never copied: "
                        "a trap is a prediction about *this* page.")
            for b, label in F.START_FROM_BLOCKS.items():
                if st.checkbox(label, value=False, key=f"blk|{b}"):
                    blocks.add(b)
            template = K.load_key(choice)
            preview = F.preview_copy(template, blocks)
            if preview:
                st.markdown(f"**These {len(preview)} values will be copied**, each marked 🟠 until you've "
                            "checked it against this page:")
                st.dataframe(pd.DataFrame(preview), hide_index=True, width="stretch",
                             height=min(36 * (len(preview) + 1), 320))
            else:
                st.caption("Nothing ticked yet.")
    ready = how == "A blank key" or (template is not None and bool(blocks))
    if st.button("Start labelling", type="primary", disabled=not ready):
        if not re.match(r"^[a-z0-9][a-z0-9_\-.]*$", doc_id):
            st.error("Use lower-case letters, digits, _ - and . only.")
            return
        if F.published_path(doc_id).exists():
            st.error(f"{doc_id} already has a published key.")
            return
        key = (F.start_from(template, doc_id, file.name, blocks) if template
               else F.skeleton(doc_id, file.name))
        open_draft(key, "new", file, F.dumps(key))   # nothing on disk until the first edit
        st.rerun()


def field_input(key: dict, path: str, label: str, where=None, help_text: str | None = None):
    """One slot: its value, and — beside it — which kind of nothing it is."""
    where = where or st
    cat, entry = F.absence_of(key, path)
    c1, c2 = where.columns([3, 1.4])
    status = c2.selectbox(f"{label} status", list(STATUS), index=list(STATUS).index(STATUS_BY_CAT[cat]),
                          key=wk(path, "status"), label_visibility="collapsed",
                          help=STATUS_HELP, format_func=lambda s: s or "as typed")
    new_cat = STATUS[status]
    if new_cat != cat:
        F.set_absence(key, path, new_cat)
        if new_cat is not None:
            st.session_state[wk(path)] = ""
    value = F.get(key, path)
    st.session_state.setdefault(wk(path), "" if value is None else str(value))
    typed = c1.text_input(label, key=wk(path), disabled=new_cat is not None, help=help_text,
                          placeholder="(null)" if new_cat is None else STATUS_BY_CAT[new_cat])
    if new_cat != cat or (new_cat is None and F.K._clean(typed) != value):
        F.mark_checked(key, path)            # changed, or marked as a kind of nothing: that is a check
    copied_check(key, path, c1)
    if new_cat is None:
        F.set_value(key, path, typed)
    else:
        _, entry = F.absence_of(key, path)
        note = c1.text_input(f"{label} — note", F.note_text(entry.get("_note")), key=wk(path, "note"),
                             placeholder="what you can see, e.g. 03/1_/2025" if new_cat == "illegible" else "optional note",
                             label_visibility="collapsed")
        F.set_note(entry, note)


def copied_check(key: dict, path: str, where):
    """The 🟠 marker on a value copied from another key, until someone says it
    matches this page."""
    if path not in F.unchecked(key):
        return
    if where.checkbox(f":orange[🟠 copied from {key['meta'].get('_started_from')} — tick if it matches this page]",
                      key=wk(path, "copied_ok")):
        F.mark_checked(key, path)


def tab_doc_fields(key: dict):
    for sec, title in DOC_SECTIONS.items():
        waiting = sum(1 for p in F.unchecked(key) if p.startswith(sec + "."))
        with st.expander(title + (f"  ·  🟠 {waiting} to check" if waiting else ""),
                         expanded=sec in ("document", "patient") or waiting > 0):
            if waiting:
                if st.button(f"✓ All {waiting} {title.lower()} values below match the page",
                             key=wk("bulk", sec), type="primary"):
                    F.mark_all_checked(key, [p for p in F.unchecked(key) if p.startswith(sec + ".")])
                    bump(); st.rerun()
            for f in K.DOCUMENT_LEVEL[sec]:
                path = f"{sec}.{f}"
                field_input(key, path, f, help_text=HELP.get(path))
                if path in ("document.as_of_date", "patient.date_of_birth"):
                    v = F.get(key, path)
                    if v and not re.match(r"^\d{4}-\d{2}-\d{2}$", str(v)):
                        st.warning("YYYY-MM-DD only.")


def tab_rows(key: dict):
    rs = F.rows(key)
    st.caption("Every row of every list on the page — billed services, vaccinations, reminders — in page order, "
               "whether or not it looks like a vaccine. A discount line is a row; a heading is not.")
    vocab = vocabulary()
    to_check = set(F.unchecked(key))

    def left_on(n):
        return [p for p in to_check if p.startswith(f"line_items[{n}].")]

    if rs:
        low = F.bulk_checkable(key, vocab).get("rows", [])
        if low:
            n_low = len({K.parse_path(p)[0] for p in low})
            if st.button(f"✓ All {len(low)} values on the {n_low} ⚪ lower-priority rows match the page",
                         key=wk("bulk", "rows"), type="primary",
                         help="Tests, preventatives, exams, and vaccines the shop does not track. "
                              "🔴 and 🟠 rows are still checked one by one."):
                F.mark_all_checked(key, low)
                bump(); st.rerun()
        overview = pd.DataFrame([{"n": r["n"], "priority": PRIORITY_BADGE[F.row_priority(r.get("term"), vocab)],
                                  "to check": str(len(left_on(r["n"])) or ""),
                                  "term": r.get("term"), "given (printed)": r.get("administered_on_raw"),
                                  "given": r.get("administered_on"), "expires (printed)": r.get("expires_on_raw"),
                                  "expires": r.get("expires_on"), "region": r.get("source_region")} for r in rs])
        st.dataframe(overview, hide_index=True, width="stretch", height=min(38 * (len(rs) + 1), 300))

    sel_key = "sel_row"
    ns = [r["n"] for r in rs]
    if st.session_state.get(sel_key) not in ns:
        # Open on the first row that still needs a one-by-one check, tracked vaccines first.
        order = sorted(ns, key=lambda n: ({F.PRIORITY_TRACKED: 0, F.PRIORITY_UNKNOWN: 1, F.PRIORITY_OTHER: 2}[
            F.row_priority(F.get(key, f"line_items[{n}].term"), vocab)], not left_on(n), n))
        st.session_state[sel_key] = order[0] if ns else None
    b = st.columns(5)
    if b[0].button("➕ Add row at end", width="stretch"):
        st.session_state[sel_key] = F.insert_row(key, None); bump(); st.rerun()
    if not rs:
        st.info("No rows yet.")
        return
    n = st.selectbox("Row", ns, index=ns.index(st.session_state[sel_key]), format_func=lambda n: f"Row {n}")
    st.session_state[sel_key] = n
    if b[1].button("Insert below", width="stretch"):
        st.session_state[sel_key] = F.insert_row(key, n); bump(); st.rerun()
    if b[2].button("⬆ Move up", width="stretch", disabled=n == 1):
        st.session_state[sel_key] = F.move_row(key, n, -1); bump(); st.rerun()
    if b[3].button("⬇ Move down", width="stretch", disabled=n == len(rs)):
        st.session_state[sel_key] = F.move_row(key, n, +1); bump(); st.rerun()
    if b[4].button("🗑 Delete row", width="stretch"):
        F.delete_row(key, n); st.session_state[sel_key] = max(1, n - 1); bump(); st.rerun()

    row = F.row_by_n(key, n)
    prio = F.row_priority(row.get("term"), vocab)
    st.markdown(f"**Row {n}** · {row.get('term') or '(no term yet)'} &nbsp; {PRIORITY_BADGE[prio]}")
    pending = left_on(n)
    if pending and prio == F.PRIORITY_UNKNOWN:
        st.caption("No ruling for this term in document_term yet, so it might be a tracked vaccine. Look at the "
                   "whole row on the page, then confirm it in one go — or tick the values one by one.")
        if st.button(f"✓ All {len(pending)} values on row {n} match the page", key=wk("bulk", "row", n)):
            F.mark_all_checked(key, pending)
            bump(); st.rerun()
    elif pending and prio == F.PRIORITY_TRACKED:
        st.caption("A tracked vaccine: these values can end up on a vaccination record, so each is checked on its own.")
    term = st.text_input("term", row.get("term") or "", key=wk("row", n, "term"), help=HELP["term"])
    if F.K._clean(term) != row.get("term"):
        F.mark_checked(key, f"line_items[{n}].term")
    copied_check(key, f"line_items[{n}].term", st)
    F.set_value(key, f"line_items[{n}].term", term)
    region = st.text_input("source_region", row.get("source_region") or "", key=wk("row", n, "source_region"),
                           help=HELP["source_region"])
    F.set_value(key, f"line_items[{n}].source_region", region)
    for f in ROW_FIELDS:
        if f in ("term", "source_region"):
            continue
        path = f"line_items[{n}].{f}"
        field_input(key, path, f, help_text=HELP.get(f))
        if f in F.DATE_PAIRS:
            iso, raw = F.get(key, path), F.get(key, f"line_items[{n}].{F.DATE_PAIRS[f]}")
            if iso and not re.match(r"^\d{4}-\d{2}-\d{2}$", str(iso)):
                st.warning("YYYY-MM-DD only. The printed form goes in the _raw box above.")
            elif F.raw_supports_iso(raw, iso) is False:
                st.warning(f"The page prints **{raw}**. Does that really state the year, month *and* day of {iso}? "
                           "If not, leave this box empty — the printed form above is the whole fact.")
    note = st.text_area("Row note (not compared)", F.note_text(row.get("_note")), key=wk("row", n, "_note"), height=68)
    F.set_note(row, note)


def tab_rules(key: dict):
    st.caption("Absences that apply to **every row** — e.g. this format never prints a lot number. "
               "An absence for one slot is set beside that slot instead.")
    init_key = wk("rules_init")
    if init_key not in st.session_state:
        st.session_state[init_key] = F.row_rules(key)
    df = pd.DataFrame(st.session_state[init_key], columns=["category", "field", "note", "_ref"])
    edited = st.data_editor(
        df, key=wk("rules"), num_rows="dynamic", hide_index=True, width="stretch",
        column_config={
            "category": st.column_config.SelectboxColumn("kind of nothing", options=list(K.ABSENT_CATEGORIES), required=True),
            "field": st.column_config.SelectboxColumn("field", options=F.rule_field_options(key), required=True, width="medium"),
            "note": st.column_config.TextColumn("note", width="large"),
            "_ref": None,
        })
    F.set_row_rules(key, records(edited), st.session_state.rule_orig)


def tab_traps(key: dict):
    st.caption("A trap is the **nearest wrong answer** for a slot — the value a careful reader could reach for "
               "and be wrong. Write them last, from the page, by asking what would tempt you. "
               "The model's output is never a source for these.")
    init_key = wk("traps_init")
    if init_key not in st.session_state:
        st.session_state[init_key] = F.trap_table(key)
    paths = (["any date field"] + F.DOC_PATHS
             + [f"line_items[{r['n']}].{f}" for r in F.rows(key) for f in ROW_FIELDS if f != "source_region"]
             + [f"line_items[].{f}" for f in ROW_FIELDS if f != "source_region"])
    for t in st.session_state[init_key]:
        if t["field"] and t["field"] not in paths:
            paths.append(t["field"])
    df = pd.DataFrame(st.session_state[init_key], columns=F.TRAP_COLUMNS)
    edited = st.data_editor(
        df, key=wk("traps"), num_rows="dynamic", hide_index=True, width="stretch",
        column_config={
            "id": st.column_config.NumberColumn("id", disabled=True, width="small"),
            "layer": st.column_config.SelectboxColumn("layer", options=F.TRAP_LAYERS, default="extraction", width="small"),
            "field": st.column_config.SelectboxColumn("field", options=paths, width="medium"),
            "wrong_value": st.column_config.TextColumn("wrong value"),
            "source_of_error": st.column_config.TextColumn("how someone gets there", width="medium"),
            "why_tempting": st.column_config.TextColumn("why it's tempting", width="medium"),
            "caught_by_plausibility_check": st.column_config.SelectboxColumn(
                "plausibility check catches it?", options=list(F.PLAUSIBILITY), width="small"),
            "note": st.column_config.TextColumn("note"),
        })
    F.set_traps(key, records(edited), st.session_state.trap_orig)


def tab_also_accept(key: dict):
    st.caption("Only for a fact the page prints **twice, in two forms** — a phone number as (888) 788-1165 in the "
               "header and 888-788-1165 in the footer. Never for a value the page doesn't print.")
    init_key = wk("aa_init")
    if init_key not in st.session_state:
        st.session_state[init_key] = F.also_accept_table(key)
    filled = [p for p in F.DOC_PATHS + [f"line_items[{r['n']}].{f}" for r in F.rows(key) for f in ROW_FIELDS]
              if F.get(key, p) is not None]
    for r in st.session_state[init_key]:
        if r["field"] not in filled:
            filled.append(r["field"])
    df = pd.DataFrame(st.session_state[init_key], columns=["field", "also_accept"])
    edited = st.data_editor(
        df, key=wk("aa"), num_rows="dynamic", hide_index=True, width="stretch",
        column_config={"field": st.column_config.SelectboxColumn("field", options=filled, width="medium"),
                       "also_accept": st.column_config.TextColumn("the other printed form", width="large")})
    F.set_also_accept(key, records(edited))


def tab_about(key: dict, item: dict, page_count: int):
    meta = key["meta"]
    locked = st.session_state.draft_source == "published"
    new_id = st.text_input("Document id", meta.get("document_id") or "", disabled=locked,
                           help="Fixed once published — runs and scores refer to it.")
    meta["document_id"] = new_id.strip()
    st.text_input("File", meta.get("source_file") or "", disabled=True)
    meta["format_family"] = st.text_input("Format family", meta.get("format_family") or "",
                                          help="The layout, e.g. petly_portal_vaccination_summary_v1. Two documents "
                                               "from the same software share one.") or None
    c1, c2 = st.columns(2)
    dc = meta.get("doc_class") or "unknown"
    meta["doc_class"] = c1.selectbox("Document type", F.DOC_CLASSES,
                                     index=F.DOC_CLASSES.index(dc) if dc in F.DOC_CLASSES else 4)
    src = meta.get("source") or "upload"
    meta["source"] = c2.selectbox("Arrived by", F.SOURCES, index=F.SOURCES.index(src) if src in F.SOURCES else 0)
    if meta.get("page_count") != page_count and st.session_state.draft_source == "new":
        meta["page_count"] = page_count
    st.caption(f"Pages: {meta.get('page_count')}   ·   type: {meta.get('mime_type')}")
    c1, c2 = st.columns(2)
    meta["dog"] = c1.text_input("Dog (pseudonym)", meta.get("dog") or "") or None
    meta["household"] = c2.text_input("Household (pseudonym)", meta.get("household") or "") or None
    cq = meta.setdefault("capture_quality", {})
    cq["medium"] = st.text_input("How it was captured", cq.get("medium") or "",
                                 placeholder="phone photo of a paper certificate, at an angle, low light") or None
    set_note_text = st.text_area("Capture notes (glare, folds, cropped edges…)",
                                 F.note_text(cq.get("_note")), height=80)
    F.set_note(cq, set_note_text)

    st.markdown("**Corpus entry** — which fixture household this document belongs to")
    owners, dogs = fixture_choices()
    entry = item["entry"] or {}
    if not entry and meta.get("_started_from"):
        # A key copied from another document of the same household starts from its entry.
        entry = next((d for d in F.load_corpus_json()["documents"]
                      if d["document_id"] == meta["_started_from"]), {})
    o_opts = list(owners) + [NO_HOUSEHOLD]
    d_opts = [""] + list(dogs)
    cur_o, cur_d = entry.get("owner_id"), entry.get("dog_id") or ""
    if entry and not cur_o:
        cur_o = NO_HOUSEHOLD            # published before, deliberately without one
    c1, c2 = st.columns(2)
    # No silent default: a wrong household here attaches the document to someone else's dog.
    st.session_state.corpus_owner = c1.selectbox(
        "Owner", o_opts, index=o_opts.index(cur_o) if cur_o in o_opts else None,
        placeholder="Choose the household…", key=wk("corpus_owner"),
        format_func=lambda o: "(not in the fixture yet)" if o == NO_HOUSEHOLD else owners.get(o, o))
    st.session_state.corpus_dog = c2.selectbox(
        "Dog", d_opts, index=d_opts.index(cur_d) if cur_d in d_opts else 0,
        format_func=lambda d: dogs.get(d, "(none)"), key=wk("corpus_dog"))
    if st.session_state.corpus_owner is None:
        st.caption("⚠ No household chosen yet.")
    elif st.session_state.corpus_owner == NO_HOUSEHOLD:
        st.caption("The key can be published, run and scored. Loading it into the database waits until the "
                   "household has an owner row in `sql/seed/fixture.sql` — adding one changes the fixture the "
                   "test suite counts on, so that is its own piece of work.")


def tab_pii():
    st.caption("Keys are anonymised; the pages are not. Every substitution you make in a key needs a line here — "
               "**real value as printed → the pseudonym the key uses** — or the model's correct reading of the real "
               "page scores as wrong. One line per printed form. This file stays in `private/`.")
    path = P.PII_MAP_FILE
    data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {"replacements": {}}
    init_key = wk("pii_init")
    if init_key not in st.session_state:
        st.session_state[init_key] = [{"real value on the page": k, "pseudonym in the key": v}
                                      for k, v in data.get("replacements", {}).items()]
    df = pd.DataFrame(st.session_state[init_key], columns=["real value on the page", "pseudonym in the key"])
    edited = st.data_editor(df, key=wk("pii"), num_rows="dynamic", hide_index=True, width="stretch")
    new = {r["real value on the page"]: r["pseudonym in the key"] for r in records(edited)
           if r["real value on the page"] and r["pseudonym in the key"]}
    if new != data.get("replacements", {}):
        if st.button("Save the PII map", type="primary"):
            data["replacements"] = new
            F.write(path, data)
            st.success(f"Saved {len(new)} replacements to private/pii_map.json.")


def tab_publish(key: dict, item: dict):
    pii = P.load()
    errors, warns = F.validate(key, pii)
    if not st.session_state.get("corpus_owner"):
        errors = errors + ["No household chosen (About this document → Corpus entry). If it isn't in the "
                           "list, choose '(not in the fixture yet)'."]
    st.code(F.self_score_line(key), language=None)
    if errors:
        st.error("**Fix before publishing**\n\n" + "\n".join(f"- {e}" for e in errors))
    if warns:
        st.warning("**Worth a second look at the page**\n\n" + "\n".join(f"- {w}" for w in warns))
    if not errors and not warns:
        st.success("The key is valid and scores perfectly against itself.")

    doc_id = key["meta"]["document_id"]
    target = F.published_path(doc_id)
    st.caption(f"Publishing writes `{rel(target)}` (committed — anonymised values only) and the "
               f"`corpus.json` entry. Drafts autosave to `private/drafts/`.")
    if st.button("Publish the key", type="primary", disabled=bool(errors)):
        out = copy.deepcopy(key)
        if st.session_state.draft_source == "new" and not item["runs"]:
            out["meta"]["_labelled_blind"] = (f"Labelled on {date.today().isoformat()}, before any model run on "
                                              "this file. A held-out test until a run is reviewed.")
        F.write(target, out)
        F.upsert_corpus({"document_id": doc_id, "key": f"answer_keys/{target.name}",
                         "file": f"../private/{item['file'].name}",
                         "owner_id": None if st.session_state.get("corpus_owner") == NO_HOUSEHOLD
                                     else st.session_state.get("corpus_owner"),
                         "dog_id": st.session_state.get("corpus_dog") or None})
        dp = F.draft_path(doc_id)
        if dp.exists():
            dp.unlink()
        st.session_state.flash = (f"Published {target.name}. Next: **Run & test** → Checks → self-check, "
                                  "then Model → send it to the model.")
        close_draft()
        st.rerun()


def autosave(key: dict):
    """A draft never lives only in the browser: every change lands in
    private/drafts/ so a refresh or a closed tab loses nothing."""
    text = F.dumps(key)
    if text == st.session_state.get("saved_text"):
        return
    doc_id = key["meta"].get("document_id")
    if not doc_id:
        return
    F.write(F.draft_path(doc_id), key)
    st.session_state.saved_text = text
    st.session_state.draft_source = "draft" if st.session_state.draft_source == "new" else st.session_state.draft_source
    st.toast("Draft saved", icon="💾")


# ============================================================== Review screen

def review_file(run_record_path: Path) -> Path:
    # A subdirectory, so the harness's `*.json` glob over a run never sees it.
    return run_record_path.parent / "reviews" / run_record_path.name


def load_verdicts(run_record_path: Path) -> dict:
    p = review_file(run_record_path)
    return json.loads(p.read_text(encoding="utf-8")).get("verdicts", {}) if p.exists() else {}


def save_verdict(run_record_path: Path, path: str, verdict: str, note: str, key: dict, got, expected):
    p = review_file(run_record_path)
    data = json.loads(p.read_text(encoding="utf-8")) if p.exists() else {"verdicts": {}}
    data["verdicts"][path] = {"verdict": verdict, "note": note or None, "key_value": expected, "model_value": got,
                              "on": datetime.now(timezone.utc).isoformat(timespec="seconds")}
    F.write(p, data)


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
    if rec.get("parse_error"):
        st.error(f"The response didn't parse: {rec['parse_error']}")
        st.code(rec.get("raw_response", "")[:4000])
        return

    m = st.columns(7)
    m[0].metric("Rows", f"{ds.got_items}/{ds.expected_items}")
    m[1].metric("Correct", f"{ds.count('correct')}/{ds.scored}")
    m[2].metric("Wrong", ds.count("wrong"))
    m[3].metric("Missed", ds.count("missed"))
    m[4].metric("Spurious", ds.count("spurious"), help="A value where the page has none — the hallucination class.")
    m[5].metric("Traps hit", f"{ds.traps_hit}/{ds.traps_scorable}")
    m[6].metric("Absence violations", len(ds.absent_violations))
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
        problems = [f for f in ds.fields if f.outcome in ("wrong", "missed", "spurious")]
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
                    for f in ds.fields if not only or f.outcome in ("wrong", "missed", "spurious")]
            st.dataframe(pd.DataFrame(rows), hide_index=True, width="stretch", height=600)


def _s(v):
    return None if v is None else str(v)


def reconcile_card(f: S.FieldResult, key: dict, item: dict, rec_path: Path, run: dict,
                   absent_cat: str | None, traps: list):
    with st.container(border=True):
        badge = {"wrong": "🟠 wrong", "missed": "🔵 missed", "spurious": "🔴 spurious"}[f.outcome]
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
        choice = st.radio("Verdict", options, format_func=VERDICTS.get, key=f"v|{run['stamp']}|{f.path}",
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


# ============================================================ Instructions

def screen_instructions():
    st.markdown((Path(__file__).parent / "INSTRUCTIONS.md").read_text(encoding="utf-8"))


# =============================================================== Run & test

def run_steps(steps: list, title: str):
    """Run the steps in order, streaming each one's output; stop at the first
    failure. The transcript stays on the page after the run finishes."""
    lines: list[str] = []
    box = st.empty()
    ok = True
    with st.status(title, expanded=True) as status:
        for step in steps:
            lines.append(f"$ {step.label}")
            status.update(label=f"{title} — {step.label}")
            code = None
            for out in ops.stream(step):
                if isinstance(out, tuple):
                    code = out[1]
                    continue
                lines.append(out)
                box.code("\n".join(lines[-400:]), language=None)
            if code != 0:
                lines.append(f"[exit {code}]")
                ok = False
                break
        status.update(label=f"{title} — {'done' if ok else 'failed'}", state="complete" if ok else "error",
                      expanded=True)
    box.code("\n".join(lines[-400:]), language=None)
    st.session_state["ops_last"] = (title, ok, lines)
    st.session_state["ops_ran_now"] = True


def screen_ops(items: list[dict]):
    st.header("Run & test")
    st.caption("The commands from the READMEs, run inside this container. Output appears below as it happens.")

    env = ops.environment()
    db = ops.database_state()
    c = st.columns(4)
    c[0].metric("API key", "set" if env["API key"] == "set" else "missing")
    c[1].metric("Model", env["Model"].split(" ")[0])
    c[2].metric("Database", {"ready": "ready", "empty": "not set up"}.get(db, "unreachable"))
    c[3].metric("Test tools", "yes" if env["psql"] == env["pg_prove"] == "yes" else "no")
    if env["API key"] != "set":
        st.warning("No API key: sending documents to the model won't work. Put `ANTHROPIC_API_KEY=` in `.env`, "
                   "then restart the stack.")
    if db not in ("ready", "empty"):
        st.warning(f"Database: {db}. Is the `db` container running?")
    elif db == "empty":
        st.info("The database is reachable but has no schema. Open **Database** below and set it up.")

    t_model, t_score, t_checks, t_db = st.tabs(["Model", "Scoring", "Checks", "Database"])

    with t_model:
        labelled = [it["document_id"] for it in items if it["key_path"]]
        st.markdown("Send labelled documents to the model. Each run is saved in `extraction/runs/` and scored "
                    "straight away; open **Review** to go through it.")
        docs = st.multiselect("Documents", labelled, placeholder="Choose one or more…")
        prompts = ops.prompts()
        prompt = st.selectbox("Prompt", prompts, index=len(prompts) - 1 if prompts else None)
        cost = st.checkbox(f"I understand this sends {len(docs) or 'the chosen'} document(s) to the API, "
                           "which costs money.")
        if st.button("Send to the model", type="primary", disabled=not (docs and prompt and cost)):
            args = ["run", "--prompt", prompt] + [a for d in docs for a in ("--doc", d)]
            run_steps(ops.harness(*args), "Model run")
            st.cache_data.clear()

    with t_score:
        runs = ops.run_dirs()
        run = st.selectbox("Run", runs, index=0 if runs else None, placeholder="No runs yet")
        c1, c2 = st.columns(2)
        if c1.button("Re-score against the current keys", disabled=not run, width="stretch",
                     help="After a key changes. Writes score.json in the run folder; nothing goes to the database."):
            run_steps(ops.harness("score", f"../runs/{run}"), f"Score {run}")
        if c2.button("Load into the database", disabled=not run or db != "ready", width="stretch",
                     help="Writes the run's extractions and its score into the database, for the SQL views."):
            run_steps(ops.harness("load", f"../runs/{run}"), f"Load {run}")

    with t_checks:
        c1, c2 = st.columns(2)
        if c1.button("Harness self-check", width="stretch",
                     help="Proves the scorer and every key, offline. Run it after publishing a key."):
            run_steps(ops.harness("selfcheck"), "Self-check")
        if c2.button("Database test suite (pg_prove)", width="stretch", disabled=db != "ready",
                     help="The pgTAP tests in tests/. Needs the database set up."):
            run_steps(ops.run_tests(), "Database tests")

    with t_db:
        st.markdown("Loads the schema (" + ", ".join(f"`{f.name}`" for f in ops.schema_files()) +
                    ") and the test fixture into the `grooming_test` database.")
        if st.button("Set up the database", disabled=db == "ready", type="primary",
                     help="For an empty database. Already set up? Use reset."):
            run_steps(ops.setup_database(reset=False), "Database setup")
            st.rerun()
        with st.popover("Reset the database…"):
            st.write("Drops the `groom` schema — every owner, dog, document, extraction and score in the test "
                     "database — and loads it fresh. Answer keys and runs on disk are not touched.")
            if st.button("Yes, reset it", type="primary"):
                run_steps(ops.setup_database(reset=True), "Database reset")

    if "ops_last" in st.session_state and not st.session_state.pop("ops_ran_now", False):
        title, ok, lines = st.session_state["ops_last"]
        with st.expander(f"Last output — {title} ({'ok' if ok else 'failed'})", expanded=False):
            st.code("\n".join(lines[-400:]), language=None)


# ==================================================================== main

def main():
    items = inventory()
    with st.sidebar:
        st.title("🐕 Records")
        screen = st.radio("Screen", ["Instructions", "Documents", "Label", "Review", "Run & test"],
                          index=1, key="screen")
        item = None
        if screen in ("Label", "Review"):
            labels = {label_of(it): it for it in items}
            # Keep the open draft's document selected.
            default = next((l for l, it in labels.items() if it["file"].name == st.session_state.get("draft_file")), None)
            choice = st.selectbox("Document", list(labels), index=list(labels).index(default) if default else 0)
            item = labels[choice]
            if "draft" in st.session_state and st.session_state.get("draft_file") != item["file"].name and screen == "Label":
                close_draft()
        if "draft" in st.session_state:
            st.caption(f"Open: {st.session_state.draft['meta'].get('document_id')} "
                       f"({st.session_state.draft_source}) — autosaved to private/drafts/")
        st.divider()
        st.caption(P.status_line(P.load()))
        st.caption(f"Contract {K.CONTRACT_VERSION}")

    if msg := st.session_state.pop("flash", None):
        st.success(msg)
    if screen == "Instructions":
        screen_instructions()
    elif screen == "Documents":
        screen_documents(items)
    elif screen == "Label":
        screen_label(item)
    elif screen == "Review":
        screen_review(item)
    else:
        screen_ops(items)


main()
