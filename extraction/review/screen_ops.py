"""The Run & test screen: the README's commands, runnable from the page."""
from __future__ import annotations

import streamlit as st

from common import (has_unpublished_edits)
import ops


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

    stale = [it["document_id"] for it in items if has_unpublished_edits(it)]
    if stale:
        st.warning("**Unpublished edits:** " + ", ".join(f"`{d}`" for d in stale) + ". Runs and scores use the "
                   "*published* key, so these edits won't count until you publish them on the **Label** screen.")

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

        st.divider()
        st.markdown(f"The groomer interface runs on its own database, `{ops.DEMO_DB}`: the same schema and a "
                    "shop's worth of demo dogs. It is built on first start; rebuild it here to undo what the "
                    "demo has recorded since.")
        with st.popover("Reset the demo database…"):
            st.write(f"Drops `{ops.DEMO_DB}` and rebuilds it from the schema and `sql/seed/demo.sql`. The test "
                     "database is not touched.")
            if st.button("Yes, rebuild the demo", type="primary"):
                run_steps(ops.setup_demo_database(), "Demo database")

    if "ops_last" in st.session_state and not st.session_state.pop("ops_ran_now", False):
        title, ok, lines = st.session_state["ops_last"]
        with st.expander(f"Last output — {title} ({'ok' if ok else 'failed'})", expanded=False):
            st.code("\n".join(lines[-400:]), language=None)
