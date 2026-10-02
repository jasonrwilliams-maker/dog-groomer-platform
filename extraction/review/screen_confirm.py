"""The Confirm screen: a groomer checks the model's reading against the page, and the page becomes the dog's vaccination records."""
from __future__ import annotations

from pathlib import Path

import streamlit as st

from common import (K, page_viewer)
import confirm as C
import ops


# ============================================================= Confirm screen
#
# Production, not evaluation. The Review screen asks "did the model match the
# answer key?"; this one asks what a groomer asks at the counter: "is this what
# the page says?" — and then turns the page into the dog's paperwork. The
# database decides what that may produce (sections 16-18); the screen only
# collects the groomer's verdicts and shows the database's answer.

def screen_confirm():
    st.header("Confirm")
    st.caption("Check what the model read against the page, then turn the page into the dog's paperwork. "
               "Nothing becomes a record until every vaccine line the shop tracks has been checked.")
    if ops.database_state() != "ready":
        st.warning("The database isn't set up. Open **Run & test → Database** first.")
        return

    people = C.groomers()
    if not people:
        st.warning("There are no groomers in the database to sign for a record.")
        return
    names = {p["id"]: p["display_name"] for p in people}
    me = st.selectbox("Reviewing as", list(names), format_func=names.get, key="confirm_groomer",
                      help="Whoever confirms a page signs its records as verified.")

    pages = C.extractions()
    if not pages:
        st.info("Nothing to confirm yet. The model's readings reach this screen when a run is loaded into the "
                "database: **Run & test → Scoring → Load into the database**.")
        return

    def page_label(x: dict) -> str:
        when = x["extracted_at"].strftime("%Y-%m-%d %H:%M")
        state = (f"✅ confirmed for {x['confirmed_for']}" if x["status"] == "accepted"
                 else f"🟡 {x['lines_to_check']} vaccine line(s) to check")
        return f"{Path(x['object_key']).name}  ·  {x['prompt_version']}  ·  read {when}  ·  {state}"

    by_id = {x["id"]: x for x in pages}
    xid = st.selectbox("Page", list(by_id), format_func=lambda i: page_label(by_id[i]), key="confirm_page")
    page = by_id[xid]
    file = K.EXTRACTION_DIR.parent / page["object_key"]

    left, right = st.columns([5, 6], gap="large")
    if file.exists():
        page_viewer(file, left)
    else:
        left.warning(f"`{page['object_key']}` isn't on this computer, so the page can't be shown. "
                     "Checking a reading without the page is guessing — find the file before confirming.")

    with right:
        if page["status"] == "accepted":
            confirmed_view(page)
        else:
            review_view(page, me)


def confirmed_view(page: dict):
    st.success(f"Confirmed for **{page['confirmed_for']}** by {page['confirmed_by']} on "
               f"{page['confirmed_at'].strftime('%Y-%m-%d %H:%M')}. Its checks are locked: the records rest on them.")
    outcome_table(C.outcomes(page["id"]))


def outcome_table(rows: list[dict]):
    def what(r: dict) -> str:
        if r["outcome"] in ("missing_date", "unreadable_name"):
            if r["requested"]:
                by = {"email": "by email", "sms": "by text", "verbal_at_counter": "at the counter"}
                return (f"owner asked for a readable copy ({', '.join(r['requested'])}), "
                        f"{by.get(r['channel'], '')}")
            return "nothing to ask — the dog already has current records"
        if r["expires_on"]:
            return f"{r['vaccine']}: given {r['administered_on']}, expires {r['expires_on']} ({r['verification']})"
        return ""
    for r in rows:
        with st.container(border=True):
            c1, c2 = st.columns([2, 3])
            c1.markdown(f"**Line {r['n']}** · {r['term'] or ('(name unreadable)' if r['term_unreadable'] else '(no name)')}")
            c2.markdown(C.OUTCOMES.get(r["outcome"], r["outcome"]) + (f"  \n{what(r)}" if what(r) else ""))


def review_view(page: dict, me: str):
    items = C.line_items(page["id"])
    flds = C.fields(page["id"])
    tracked = [li for li in items if li["disposition"] == "tracked"]
    unchecked = [li for li in tracked if li["unreviewed_record_fields"]]
    unmapped = [li for li in items if li["disposition"] == "unmapped"]

    m = st.columns(4)
    m[0].metric("Lines to check", len(unchecked), help="Vaccine lines the shop tracks, with a field nobody has checked.")
    m[1].metric("New names", len(unmapped), help="Printed names the shop has never ruled on.")
    m[2].metric("Ready", page["records_ready"] or 0,
                help="Lines that will become records: both dates present and every field checked.")
    m[3].metric("Can't record", page["tracked_rows_blocked"] or 0,
                help="Vaccine lines missing a date a record needs. The owner will be asked for a proper copy.")

    # --- 1. whose page
    st.markdown("#### 1. Whose page is this?")
    dogs = C.filed_dogs(page["document_id"])
    dog = None
    if dogs:
        dog_names = {d["id"]: d["name"] for d in dogs}
        dog = st.radio("Dog", list(dog_names), format_func=dog_names.get, horizontal=True,
                       key=f"confirm_dog|{page['id']}", label_visibility="collapsed",
                       index=0 if len(dogs) == 1 else None)
    household = [d for d in C.household_dogs(page["owner_id"]) if d["id"] not in {x["id"] for x in dogs}]
    if household:
        with st.expander("This page is about a dog it isn't filed under" if dogs
                         else "This page isn't filed under any dog yet", expanded=not dogs):
            hh = {d["id"]: d["name"] for d in household}
            pick = st.selectbox("File it under", list(hh), format_func=hh.get, key=f"file_under|{page['id']}")
            if st.button("File the page under this dog", key=f"file_btn|{page['id']}"):
                C.file_under(page["document_id"], pick)
                st.rerun()

    # --- 2. the lines
    st.markdown("#### 2. Check each vaccine line against the page")
    st.caption("Only the lines for vaccines the shop tracks need checking. Dates are year-month-day.")
    for li in items:
        line_card(li, flds.get(li["line_item_id"], {}), me)

    # --- 3. confirm
    st.markdown("#### 3. Confirm")
    if unchecked or unmapped:
        st.info(f"Still to do: {len(unchecked)} vaccine line(s) to check, {len(unmapped)} unfamiliar name(s). "
                "The database will refuse until they're done.")
    if st.button("Confirm this page", type="primary", disabled=dog is None, key=f"confirm_btn|{page['id']}",
                 help=None if dog else "Choose whose page it is first."):
        rows, message, hint = C.confirm(page["id"], dog, me)
        if message:
            st.error(f"**Not confirmed.** {message}" + (f"\n\n{hint}" if hint else ""))
        else:
            st.session_state.flash = f"Confirmed. {sum(r['outcome'] == 'record_created' for r in rows)} new record(s)."
            st.rerun()


def line_card(li: dict, flds: dict, me: str):
    disp = li["disposition"]
    badge = {"tracked": f"🟢 {li['vaccine_code']}", "unmapped": "🟠 unfamiliar name",
             "recognized_untracked": f"⚪ {li['vaccine_code'] or 'vaccine'} — not tracked",
             "not_a_vaccine": "⚪ not a vaccine"}.get(disp, "⚪ no name")
    if li["term_unreadable"]:
        badge = "🟠 name unreadable — the owner will be asked for a readable copy"
    done = disp == "tracked" and not li["unreviewed_record_fields"]
    name = li["term"] or ("(name unreadable)" if li["term_unreadable"] else "(no name)")
    title = f"Line {li['n']} · {name} · {badge}" + (" · ✔ checked" if done else "")
    needs_work = disp == "unmapped" or (disp == "tracked" and not done)
    with st.expander(title, expanded=needs_work):
        if disp == "unmapped":
            rule_form(li, me)
        if disp not in ("tracked", "unmapped"):
            st.caption("Nothing on this line becomes a record, so it doesn't need checking. Open it anyway if the "
                       "name was misread — correcting it can make it a vaccine line.")
        field_form(li, flds)


def field_form(li: dict, flds: dict):
    """One row per field the record would carry. An answer saves the moment
    it is clicked; only a correction needs its own Save, for the typing."""
    lid = li["line_item_id"]
    for name, label in C.RECORD_FIELDS.items():
        f = flds.get(name)
        if f is None:
            continue
        akey = f"a|{f['id']}"
        shown = "—" if f["extracted_value"] is None else f["extracted_value"]
        read_as = li.get(C.DATE_FIELDS.get(name, ""), None)
        c1, c2 = st.columns([2, 3])
        c1.markdown(f"**{label}**  \n`{shown}`" + (f"  \nthe model read the print as _{read_as}_" if read_as else ""))
        # 'feeds a record' is true of every field here, so it is not news.
        extra = [lab for code, lab in zip(f["reasons"] or [], f["reason_labels"] or []) if code != "feeds_a_record"]
        if extra and f["action"] == "unreviewed":
            c1.caption("⚑ " + " · ".join(extra))
        options = [a for a in C.ACTIONS if not (a == "removed" and f["extracted_value"] is None)]
        current = f["action"] if f["action"] in options else None
        choice = c2.radio(label, options, format_func=C.ACTIONS.get, key=akey,
                          index=options.index(current) if current else None, label_visibility="collapsed",
                          on_change=_save_answer, args=(f, akey))
        if choice == "edited":
            typed = c2.text_input("What the page says", value=f["corrected_value"] or f["extracted_value"] or "",
                                  key=f"t|{f['id']}",
                                  placeholder="year-month-day, e.g. 2026-10-15" if name in C.DATE_FIELDS else None)
            if c2.button("Save the correction", key=f"s|{f['id']}"):
                if msg := C.save_field(f, "edited", typed):
                    st.session_state[f"err|{f['id']}"] = msg
                st.rerun()
        if msg := st.session_state.pop(f"err|{f['id']}", None):
            c2.error(msg)
    st.button("Everything I haven't answered on this line matches the page", key=f"rest|{lid}",
              on_click=_confirm_rest, args=(lid, flds))


def _save_answer(f: dict, akey: str):
    choice = st.session_state.get(akey)
    if choice == "edited":
        return                     # waits for the typed value and its Save
    if msg := C.save_field(f, choice, None):
        st.session_state[f"err|{f['id']}"] = msg


def _confirm_rest(lid: str, flds: dict):
    C.confirm_rest_of_line(lid)
    for f in flds.values():        # the radios show what was just saved
        if st.session_state.get(f"a|{f['id']}") is None and f["action"] == "unreviewed":
            st.session_state[f"a|{f['id']}"] = "confirmed"


def rule_form(li: dict, me: str):
    st.warning(f"Nobody has ruled on **{li['term']}**. Decide what it is once, and every page that prints it "
               "the same way is handled from then on.")
    types = C.vaccine_types()
    opts = [None] + [t["id"] for t in types]
    tnames = {t["id"]: t["name"] for t in types}
    with st.form(f"rule|{li['line_item_id']}", border=True):
        what = st.selectbox("It is", opts, format_func=lambda i: "Not a vaccine (a test, a treatment, a fee…)"
                            if i is None else f"The {tnames[i]} vaccine")
        sure = st.checkbox("I'm sure", value=True)
        why = st.text_input("Why (needed if you're not sure)")
        if st.form_submit_button("Record this ruling"):
            if msg := C.rule_on_term(li["term"], what, sure, why, me):
                st.error(msg)
            else:
                st.rerun()
