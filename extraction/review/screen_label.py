"""The Label screen: write a document's answer key by looking at the page, never at the model."""
from __future__ import annotations

import copy
import json
import re
from datetime import date

import pandas as pd
import streamlit as st

from common import (
    DOC_SECTIONS, F, HELP, K, NO_HOUSEHOLD, PRIORITY_BADGE, ROW_FIELDS, STATUS,
    STATUS_BY_CAT, STATUS_HELP, bump, close_draft, fixture_choices, open_draft,
    page_viewer, records, rel, suggest_id, vocabulary, wk,
)
from harness import pii as P  # noqa: E402  (common put the harness on the path)


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
    pub_banner = st.empty()  # likewise: whether there is anything to publish depends on this run's edits

    left, right = st.columns([5, 6], gap="large")
    page_count = page_viewer(file, left)
    _label_tabs(key, item, src, right, page_count)

    unpublished_banner(key, item, pub_banner)
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
    # Which row is open. The table is the picker: a click on a row opens it.
    # Row operations set this directly and bump the generation, which gives
    # the table a fresh key — so its old click cannot pull the editor back.
    sel_key = "sel_row"
    ns = [r["n"] for r in rs]
    if st.session_state.get(sel_key) not in ns:
        # Open on the first row that still needs a one-by-one check, tracked vaccines first.
        order = sorted(ns, key=lambda n: ({F.PRIORITY_TRACKED: 0, F.PRIORITY_UNKNOWN: 1, F.PRIORITY_OTHER: 2}[
            F.row_priority(F.get(key, f"line_items[{n}].term"), vocab)], not left_on(n), n))
        st.session_state[sel_key] = order[0] if ns else None
    n = st.session_state[sel_key]

    if rs:
        st.caption("**Click a row to edit it.** ✏️ marks the row open below.")
        overview = pd.DataFrame([{"": "✏️" if r["n"] == n else "", "n": r["n"],
                                  "priority": PRIORITY_BADGE[F.row_priority(r.get("term"), vocab)],
                                  "to check": str(len(left_on(r["n"])) or ""),
                                  "term": r.get("term"), "given (printed)": r.get("administered_on_raw"),
                                  "given": r.get("administered_on"), "expires (printed)": r.get("expires_on_raw"),
                                  "expires": r.get("expires_on"), "region": r.get("source_region")} for r in rs])
        event = st.dataframe(overview, hide_index=True, width="stretch", height=min(36 * (len(rs) + 1) + 3, 460),
                             on_select="rerun", selection_mode="single-row", key=wk("rows_table"))
        picked = event.selection.rows if event is not None else []
        if picked and rs[picked[0]]["n"] != n:
            st.session_state[sel_key] = rs[picked[0]]["n"]
            st.rerun()

    b = st.columns(5)
    if b[0].button("➕ Add row at end", width="stretch"):
        st.session_state[sel_key] = F.insert_row(key, None); bump(); st.rerun()
    if not rs:
        st.info("No rows yet.")
        return
    if b[1].button(f"Insert below row {n}", width="stretch"):
        st.session_state[sel_key] = F.insert_row(key, n); bump(); st.rerun()
    if b[2].button("⬆ Move up", width="stretch", disabled=n == 1):
        st.session_state[sel_key] = F.move_row(key, n, -1); bump(); st.rerun()
    if b[3].button("⬇ Move down", width="stretch", disabled=n == len(rs)):
        st.session_state[sel_key] = F.move_row(key, n, +1); bump(); st.rerun()
    if b[4].button(f"🗑 Delete row {n}", width="stretch"):
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
            if iso and raw and "?" in raw:
                st.warning(f"The printed form **{raw}** is partly read, so it doesn't state a full date. "
                           "Leave this box empty.")
            elif iso and not re.match(r"^\d{4}-\d{2}-\d{2}$", str(iso)):
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
                                     index=F.DOC_CLASSES.index(dc if dc in F.DOC_CLASSES else "unknown"))
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


def publish_checks(key: dict) -> tuple[list[str], list[str]]:
    errors, warns = F.validate(key, P.load())
    if not st.session_state.get("corpus_owner"):
        errors = errors + ["No household chosen (About this document → Corpus entry). If it isn't in the "
                           "list, choose '(not in the fixture yet)'."]
    return errors, warns


def is_unpublished(key: dict) -> bool:
    target = F.published_path(key["meta"].get("document_id") or "")
    return not target.exists() or F.dumps(key) != target.read_text(encoding="utf-8")


def publish(key: dict, item: dict):
    doc_id = key["meta"]["document_id"]
    target = F.published_path(doc_id)
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
    st.session_state.flash = (f"Published {target.name}. Scoring now uses it — re-score an older run from "
                              "**Run & test → Scoring**, or send it to the model from **Run & test → Model**.")
    close_draft()
    st.rerun()


def unpublished_banner(key: dict, item: dict, where):
    """Shown on every tab of the Label screen while the open key differs from
    what is published — because the harness only ever reads the published
    one, and an edit that never gets published silently changes nothing."""
    if not is_unpublished(key):
        return
    errors, _ = publish_checks(key)
    never = not F.published_path(key["meta"].get("document_id") or "").exists()
    with where.container(border=True):
        c1, c2 = st.columns([4, 1])
        c1.markdown("**✏️ This key isn't published yet.** Scoring and model runs can't use it until it is."
                    if never else
                    "**✏️ Unpublished changes.** Scoring and model runs still use the published version of "
                    "this key — publish to make them count.")
        if errors:
            c1.caption(f"{len(errors)} thing(s) to fix first — **④ Check & publish** lists them.")
        elif c2.button("Publish now", type="primary", width="stretch", key=wk("publish_banner")):
            publish(key, item)


def tab_publish(key: dict, item: dict):
    errors, warns = publish_checks(key)
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
        publish(key, item)


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
