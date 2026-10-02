"""The Outreach screen: owners' consent to email and texts, the sender, and the outbox."""
from __future__ import annotations

import pandas as pd
import streamlit as st

import confirm as C
import ops
import outreach as O


# ============================================================ Outreach screen
#
# When a confirmed page leaves the shop short of a certificate, the owner is
# asked — automatically, if they agreed to it. The rules are in section 19;
# this screen records consent, runs the sender, and shows what was said.

def screen_outreach():
    st.header("Outreach")
    if ops.database_state() != "ready":
        st.warning("The database isn't set up. Open **Run & test → Database** first.")
        return
    try:
        prov = O.provider().name
    except RuntimeError as e:
        st.error(str(e))
        return
    if prov == "test-mode":
        st.info("**Test mode.** Messages are written to the outbox below and nothing is delivered. "
                "A real email or text service plugs in later without changing who gets asked, or when.")
    st.caption("The shop asks owners for missing certificates by itself — but only owners who have agreed to "
               "email or texts, once per dog, and no more than a few times. Everyone else is listed for a person.")

    people = C.groomers()
    names = {p["id"]: p["display_name"] for p in people}
    me = st.selectbox("Working as", list(names), format_func=names.get, key="confirm_groomer")

    t_send, t_staff, t_consent, t_outbox = st.tabs(["Send", "Needs a person", "Consent", "Outbox"])

    with t_send:
        st.markdown("Queues a message for every owner who is due one, then sends everything queued. "
                    "On a schedule, the same thing runs as `python outreach.py`.")
        if st.button("Send due messages now", type="primary"):
            r = O.send_due()
            st.success(f"{r.queued} queued · {r.sent} sent · {r.failed} failed · {r.cancelled} cancelled "
                       f"(provider: {r.provider})")
            if r.lines:
                st.code("\n".join(r.lines), language=None)

    with t_staff:
        rows = O.for_staff()
        if not rows:
            st.success("Nobody needs a person's follow-up.")
        else:
            st.caption("The shop can't ask these owners by itself. Ask at the counter or call — and if they're happy "
                       "to be emailed or texted, record that on the **Consent** tab.")
            st.dataframe(pd.DataFrame([{"owner": r["owner_name"], "dog": r["dog_name"], "needs": r["vaccine"],
                                        "phone": r["phone"], "email": r["email"], "why": r["why"]} for r in rows]),
                         hide_index=True, width="stretch")

    with t_consent:
        owners = {o["id"]: o for o in O.owners()}
        oid = st.selectbox("Owner", list(owners), key="outreach_owner",
                           format_func=lambda i: f"{owners[i]['name']} ({owners[i]['dogs'] or 'no dogs'})")
        o = owners[oid]
        now = O.consent(oid)
        c1, c2 = st.columns(2)
        for col, ch, label, addr in ((c1, "email", "Email", o["email"]), (c2, "sms", "Texts", o["phone"])):
            a = now.get(ch)
            with col.container(border=True):
                st.markdown(f"**{label}** · {addr or '— no address on file'}")
                if a is None:
                    st.write("Not asked yet — treated as **no**.")
                else:
                    st.write(f"{'✅ Yes' if a['granted'] else '⛔ No'} — {a['source']}  \n"
                             f"recorded {a['recorded_at'].strftime('%Y-%m-%d')}"
                             + (f" by {a['recorded_by']}" if a["recorded_by"] else " by the owner"))
                if ch == "email" and o["email_opted_out"]:
                    st.warning("Opted out of email. No email goes to this owner, whatever is recorded here.")
                elif a and a["granted"] and not a["usable"]:
                    st.warning("Agreed, but there's no address on file to use.")
        with st.form(f"consent|{oid}"):
            st.markdown("**Record their answer**")
            ch = st.radio("For", ["email", "sms"], horizontal=True, format_func={"email": "Email", "sms": "Texts"}.get)
            yes = st.radio("They said", [True, False], horizontal=True,
                           format_func={True: "Yes, you can message me", False: "No"}.get)
            how = st.text_input("How you know", placeholder="ticked the box on the intake form")
            if st.form_submit_button("Record"):
                if msg := O.record_consent(oid, ch, yes, how, me):
                    st.error(msg)
                else:
                    st.rerun()
        st.caption("Answers are never edited: a change of mind is a new entry, and the earlier ones stay as the "
                   "record of what was true when older messages went out.")

    with t_outbox:
        msgs = O.outbox()
        if not msgs:
            st.write("Nothing has been queued yet.")
        mark = {"sent": "✅", "queued": "🕓", "failed": "❌", "cancelled": "⛔"}
        for m in msgs:
            when = (m["sent_at"] or m["queued_at"]).strftime("%Y-%m-%d %H:%M")
            head = (f"{mark.get(m['status'], '')} {m['status']} · {m['dog_name']} · "
                    f"{'text' if m['channel'] == 'sms' else 'email'} to {m['recipient_address']} · {when}"
                    + (" · reminder" if m["is_reminder"] else ""))
            with st.expander(head):
                if m["subject"]:
                    st.markdown(f"**Subject:** {m['subject']}")
                st.text(m["body"])
                if m["error"]:
                    st.caption(f"Why: {m['error']}")
                if m["provider"]:
                    st.caption(f"Provider: {m['provider']}")
