"""The labelling and review tool.

    Documents   what has been submitted, and where each one stands
    Label       write a document's answer key by looking at the page — never at the model
    Run & test  the README's commands: database setup, pgTAP, model runs, scoring
    Review      what the model read, against the key, and what needs reconciling
    Confirm     a groomer checks the model's reading against the page, and the
                page becomes the dog's vaccination records (Layer 3)
    Outreach    owners' consent to email and texts, the sender, and the outbox

It starts with the stack — `docker compose up -d` — at
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

import importlib
import sys
from pathlib import Path

import streamlit as st

st.set_page_config(page_title="Vaccination records — labelling & review", page_icon="🐕", layout="wide")

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))       # this folder, however the app was started
import common                       # noqa: E402

# Streamlit reruns this file when it changes, but keeps every module it has
# already imported. Reload the harness in place, then — if any of this
# folder's modules changed — all of them, in dependency order, so a screen
# never holds names from a stale common.py.
common._reload_harness_if_changed()
LOCAL = ("ops", "confirm", "outreach", "common", "screen_documents", "screen_label",
         "screen_review", "screen_confirm", "screen_outreach", "screen_ops")
_stamp = max((HERE / f"{name}.py").stat().st_mtime for name in LOCAL)
if _stamp != getattr(common, "_local_stamp", None):
    for _name in LOCAL:
        importlib.reload(importlib.import_module(_name))
    common._local_stamp = _stamp

from common import K, close_draft, inventory, label_of               # noqa: E402
from harness import pii as P                                         # noqa: E402
from screen_confirm import screen_confirm                            # noqa: E402
from screen_documents import screen_documents                        # noqa: E402
from screen_label import screen_label                                # noqa: E402
from screen_ops import screen_ops                                    # noqa: E402
from screen_outreach import screen_outreach                          # noqa: E402
from screen_review import screen_review                              # noqa: E402


# ============================================================ Instructions

def screen_instructions():
    st.markdown((Path(__file__).parent / "INSTRUCTIONS.md").read_text(encoding="utf-8"))


# ==================================================================== main

def main():
    items = inventory()
    with st.sidebar:
        st.title("🐕 Records")
        screen = st.radio("Screen", ["Instructions", "Documents", "Label", "Run & test", "Review", "Confirm", "Outreach"],
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
    elif screen == "Confirm":
        screen_confirm()
    elif screen == "Outreach":
        screen_outreach()
    else:
        screen_ops(items)


main()
