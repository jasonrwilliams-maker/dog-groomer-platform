"""What every screen of the review tool shares: the harness and database
modules, the document inventory, the page viewer, and small helpers.

The screens are one module each (screen_*.py); app.py is the sidebar and
the dispatch."""
from __future__ import annotations

import json
import math
import re
import sys
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
from harness import keyform as F    # noqa: E402
from harness import keys as K       # noqa: E402
from harness.prep import prepare_image   # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))   # this folder, however the app was started

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
               "**illegible** — something is printed and you cannot read any of it.  \n"
               "Can read *part* of it? Keep 'as typed' and type ? for each character you can't read: "
               "`Jan 2?, 2027`. Don't pick the likeliest digit.")

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
    "administered_on_raw": "The date as printed: '04-04-25', 'Oct 15, 2025'. A character you can't read is ?: "
                           "'Oct 1?, 2025'.",
    "administered_on": "YYYY-MM-DD — only when the printed form states year, month AND day.",
    "expires_on_raw": "The expiry or due date as printed. '03-28' is a month; it lives here and nowhere else. "
                      "A character you can't read is ?: 'Jan 2?, 2027' — and then the ISO box stays empty.",
    "expires_on": "YYYY-MM-DD — only a full date printed for THIS row. Never derived, never a lot's expiry.",
    "status_raw": "A status word printed on the row: Active, Due, Overdue.",
    "veterinarian_phone": "A vet's own number. A clinic switchboard is not a vet's phone.",
    "tag_number": "A rabies tag printed with this vaccination.",
}
DOC_SECTIONS = {"document": "Document", "clinic": "Clinic", "owner": "Owner", "patient": "Patient"}
ROW_FIELDS = [f for f in K.LINE_ITEM_FIELDS]


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


def has_unpublished_edits(item: dict) -> bool:
    """A published key with a draft that differs from it: the harness is
    still scoring the published version."""
    if not (item["key_path"] and item["draft_path"]):
        return False
    try:
        return item["draft_path"].read_text(encoding="utf-8") != item["key_path"].read_text(encoding="utf-8")
    except OSError:
        return False


def status_word(item: dict) -> str:
    if item["key_path"] and has_unpublished_edits(item):
        return "edits not published"
    if item["key_path"]:
        return "labelled"
    if item["draft_path"]:
        return "draft"
    return "not labelled"


STATUS_MARK = {"not labelled": "🔴", "draft": "🟡", "edits not published": "🟡", "labelled": "🟢"}
STATUS_COLOUR = {"not labelled": "rgba(230, 70, 70, .28)", "draft": "rgba(240, 180, 40, .30)",
                 "edits not published": "rgba(240, 180, 40, .30)", "labelled": "rgba(60, 170, 90, .25)"}


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
PROBLEMS = ("wrong", "missed", "spurious", "overconfident")


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


# ============================================================ review verdicts

def review_file(run_record_path: Path) -> Path:
    # A subdirectory, so the harness's `*.json` glob over a run never sees it.
    return run_record_path.parent / "reviews" / run_record_path.name


def load_verdicts(run_record_path: Path) -> dict:
    p = review_file(run_record_path)
    return json.loads(p.read_text(encoding="utf-8")).get("verdicts", {}) if p.exists() else {}
