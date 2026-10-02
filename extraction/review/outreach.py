"""The outreach sender: queue what is due, deliver it, report back.

Every rule about who may be messaged, when, and with what words is in the
database (section 19). This file only moves messages out of the outbox:

    1. enqueue_due_outreach()  — the database decides what is due and writes it
    2. for each queued message — check consent once more, hand it to a provider
    3. mark_outreach_sent() / mark_outreach_failed() / cancel_outreach()

A provider is anything with a `name` and a `send(message) -> provider_message_id`.
Only the test-mode provider exists: it delivers nothing, and the outbox screen
is where a person reads what would have gone out. A real email or text service
is one more class here, chosen by OUTREACH_PROVIDER, and nothing else changes.

Run on a schedule — this is the automation:

    python outreach.py            # from extraction/review, or
    docker compose exec review python outreach.py

or from the tool's Outreach screen.
"""
from __future__ import annotations

import os
import sys
import uuid
from dataclasses import dataclass, field

import psycopg

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import confirm as C   # noqa: E402  (the shared connection, with jit off)


class TestModeProvider:
    """Delivers nothing. Returns an id so the database records a send exactly as
    it would for a real provider — the outbox is the proof of what was said."""
    name = "test-mode"

    def send(self, message: dict) -> str:
        return f"test-{uuid.uuid4().hex[:12]}"


PROVIDERS = {"test-mode": TestModeProvider}


def provider():
    name = os.environ.get("OUTREACH_PROVIDER", "test-mode")
    if name not in PROVIDERS:
        raise RuntimeError(f"OUTREACH_PROVIDER={name!r} is not one of {sorted(PROVIDERS)}.")
    return PROVIDERS[name]()


@dataclass
class Report:
    provider: str
    queued: int = 0
    sent: int = 0
    failed: int = 0
    cancelled: int = 0
    lines: list[str] = field(default_factory=list)


def send_due(limit: int = 100) -> Report:
    p = provider()
    report = Report(p.name)
    with C._conn() as conn:
        report.queued = len(conn.execute("SELECT * FROM enqueue_due_outreach()").fetchall())
        conn.commit()

        # Every queued message, including ones an earlier run left behind.
        # SKIP LOCKED, so two senders running at once never send one twice.
        while report.sent + report.failed + report.cancelled < limit:
            with conn.transaction():
                m = conn.execute("""SELECT m.*, d.name AS dog_name
                                      FROM outreach_message m JOIN dog d ON d.id = m.dog_id
                                     WHERE m.status = 'queued'
                                     ORDER BY m.queued_at
                                     LIMIT 1 FOR UPDATE OF m SKIP LOCKED""").fetchone()
                if m is None:
                    break
                to = f"{m['dog_name']} — {m['channel']} to {m['recipient_address']}"
                if not conn.execute("SELECT may_message(%s, %s)", (m["owner_id"], m["channel"])).fetchone()["may_message"]:
                    conn.execute("SELECT cancel_outreach(%s, %s)", (m["id"], "consent withdrawn before sending"))
                    report.cancelled += 1
                    report.lines.append(f"cancelled  {to} — consent withdrawn")
                    continue
                try:
                    provider_id = p.send(m)
                except Exception as e:                       # the provider's failure, recorded
                    conn.execute("SELECT mark_outreach_failed(%s, %s)", (m["id"], str(e)[:500]))
                    report.failed += 1
                    report.lines.append(f"failed     {to} — {e}")
                    continue
                conn.execute("SELECT mark_outreach_sent(%s, %s, %s)", (m["id"], p.name, provider_id))
                report.sent += 1
                report.lines.append(f"sent       {to}")
    return report


# ------------------------------------------------------------ for the screen

def owners() -> list[dict]:
    return C._all("""SELECT o.id::text, o.first_name || ' ' || o.last_name AS name, o.email, o.phone,
                            o.email_opted_out,
                            string_agg(d.name, ', ' ORDER BY d.name) AS dogs
                       FROM owner o LEFT JOIN dog d ON d.owner_id = o.id AND d.is_active
                      GROUP BY o.id ORDER BY o.last_name, o.first_name""")


def consent(owner_id: str) -> dict[str, dict]:
    rows = C._all("""SELECT c.channel::text, c.granted, c.source, c.recorded_at, g.display_name AS recorded_by,
                            may_message(c.owner_id, c.channel) AS usable
                       FROM v_owner_consent c LEFT JOIN groomer g ON g.id = c.recorded_by
                      WHERE c.owner_id = %s::uuid""", (owner_id,))
    return {r["channel"]: r for r in rows}


def record_consent(owner_id: str, channel: str, granted: bool, source: str, groomer_id: str) -> str | None:
    if not source.strip():
        return "Say how you know — 'ticked the box on the intake form', 'said yes at the counter'."
    with C._conn() as conn:
        conn.execute("""INSERT INTO contact_consent (owner_id, channel, granted, source, recorded_by)
                        VALUES (%s::uuid, %s::request_channel, %s, %s, %s::uuid)""",
                     (owner_id, channel, granted, source.strip(), groomer_id))
    return None


def outbox(limit: int = 50) -> list[dict]:
    return C._all("""SELECT m.id::text, m.status::text, m.channel::text, m.recipient_address, m.subject, m.body,
                            m.is_reminder, m.queued_at, m.sent_at, m.provider, m.error,
                            d.name AS dog_name, o.first_name || ' ' || o.last_name AS owner_name
                       FROM outreach_message m JOIN dog d ON d.id = m.dog_id JOIN owner o ON o.id = m.owner_id
                      ORDER BY m.queued_at DESC LIMIT %s""", (limit,))


def for_staff() -> list[dict]:
    return C._all("SELECT * FROM v_outreach_for_staff ORDER BY owner_name, dog_name, vaccine")


if __name__ == "__main__":
    try:
        r = send_due()
    except (psycopg.Error, RuntimeError) as e:
        sys.exit(f"outreach: {e}")
    print(f"provider {r.provider}: {r.queued} queued, {r.sent} sent, {r.failed} failed, {r.cancelled} cancelled")
    for line in r.lines:
        print("  " + line)
