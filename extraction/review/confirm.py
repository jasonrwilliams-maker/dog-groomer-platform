"""The Confirm screen's database work, kept out of the screen.

The screen is where a groomer checks a page the model has read and turns it
into the dog's paperwork. Every rule about what that is allowed to produce is
in the database (sections 16-18): this module only reads what the screen shows,
writes the groomer's verdict on each field, and makes the one call —
confirm_extraction() — that does the rest. Nothing here decides whether a line
becomes a record.

Each function opens its own short connection. The screen reruns on every
click, and a held connection would outlive the page that opened it.
"""
from __future__ import annotations

import os
from contextlib import contextmanager

import psycopg
from psycopg.rows import dict_row

# The four answers a reviewer can give about one field, in the order the
# screen offers them, worded for the person at the counter.
ACTIONS = {
    "confirmed":  "Matches the page",
    "edited":     "The page says something else",
    "removed":    "Not on the page — the model made it up",
    "unreadable": "On the page, but I can't read it",
}

# The fields a vaccination record carries (is_record_field() in section 16),
# in the order a person reads a vaccine line.
RECORD_FIELDS = {
    "term":                    "Vaccine name",
    "administered_on":         "Given on",
    "expires_on":              "Expires on",
    "vaccine_manufacturer":    "Manufacturer",
    "lot_serial_number":       "Lot number",
    "veterinarian_name":       "Vet",
    "veterinarian_license_no": "Vet licence no.",
    "veterinarian_phone":      "Vet phone",
}
DATE_FIELDS = {"administered_on": "administered_on_raw", "expires_on": "expires_on_raw"}

OUTCOMES = {
    "record_created":        "✅ New vaccination record",
    "already_on_file":       "↔️ Already on file — nothing added",
    "conflicts_with_record": "⚠️ Disagrees with a record on file — check which is right",
    "missing_date":          "⛔ No record — a date is missing or unreadable",
    "unreadable_name":       "⛔ No record — the vaccine name can't be read",
    "not_tracked":           "— Not a vaccine the shop tracks",
    "no_term":               "— No vaccine name",
}


@contextmanager
def _conn():
    url = os.environ.get("DATABASE_URL")
    if not url:
        raise RuntimeError("DATABASE_URL is not set. The stack sets it; see docker-compose.yml.")
    with psycopg.connect(url, row_factory=dict_row) as conn:
        conn.execute("SET search_path = groom, public")
        # The review views stack four deep, so the planner's cost estimate
        # crosses Postgres's JIT threshold and it spends ~1.2 s compiling a
        # query that runs in ~40 ms. On a database this size JIT only costs.
        # The API layer will want the same setting.
        conn.execute("SET jit = off")
        yield conn


def _all(sql: str, params: tuple = ()) -> list[dict]:
    with _conn() as conn:
        return conn.execute(sql, params).fetchall()


# ------------------------------------------------------------------ reading

def groomers() -> list[dict]:
    return _all("SELECT id::text, display_name FROM groomer WHERE is_active ORDER BY display_name")


def vaccine_types() -> list[dict]:
    return _all("SELECT id::text, code, name FROM vaccine_type ORDER BY name")


def extractions() -> list[dict]:
    """Pages awaiting review first, then pages already confirmed."""
    return _all("""
        SELECT e.id::text, e.status::text, e.prompt_version, e.model_version, e.extracted_at,
               d.id::text AS document_id, d.object_key, d.owner_id::text,
               s.line_items, s.tracked_rows, s.records_ready, s.records_awaiting_review,
               s.records_on_suspect_dates, s.tracked_rows_blocked, s.unmapped_terms,
               s.fields_to_review, s.high,
               (SELECT count(*) FROM v_extraction_line_item v
                 WHERE v.extraction_id = e.id AND v.disposition = 'tracked'
                   AND v.unreviewed_record_fields > 0) AS lines_to_check,
               c.confirmed_at, g.display_name AS confirmed_by, dg.name AS confirmed_for
          FROM extraction e
          JOIN document d ON d.id = e.document_id
          LEFT JOIN v_extraction_review_summary s ON s.extraction_id = e.id
          LEFT JOIN extraction_confirmation c     ON c.extraction_id = e.id
          LEFT JOIN groomer g                     ON g.id = c.confirmed_by
          LEFT JOIN dog dg                        ON dg.id = c.dog_id
         WHERE e.status IN ('needs_review', 'accepted')
           -- A reading made at the counter is confirmed there, by saving (section 27).
           AND NOT e.read_at_counter
         ORDER BY (e.status = 'needs_review') DESC, e.extracted_at DESC""")


def filed_dogs(document_id: str) -> list[dict]:
    return _all("""SELECT dg.id::text, dg.name FROM document_dog dd JOIN dog dg ON dg.id = dd.dog_id
                    WHERE dd.document_id = %s::uuid ORDER BY dg.name""", (document_id,))


def household_dogs(owner_id: str) -> list[dict]:
    return _all("SELECT id::text, name FROM dog WHERE owner_id = %s::uuid AND is_active ORDER BY name",
                (owner_id,))


def line_items(extraction_id: str) -> list[dict]:
    return _all("""SELECT line_item_id::text, n, source_region, term, term_unreadable, disposition::text, vaccine_code,
                          administered_on_raw, administered_on, expires_on_raw, expires_on,
                          record_candidate, can_create_record, unreviewed_record_fields
                     FROM v_extraction_line_item WHERE extraction_id = %s::uuid ORDER BY n""",
                (extraction_id,))


def fields(extraction_id: str) -> dict[str, dict[str, dict]]:
    """{line_item_id: {field_name: field}} for the fields a record carries,
    with the review work order's reasons (section 17) where it has any."""
    rows = _all("""
        SELECT ef.id::text, ef.line_item_id::text, ef.field_name, ef.extracted_value,
               ef.corrected_value, ef.correction_action::text AS action,
               p.priority, p.reasons, p.reason_labels
          FROM extraction_field ef
          LEFT JOIN v_field_review_priority p ON p.extraction_field_id = ef.id
         WHERE ef.extraction_id = %s::uuid AND ef.line_item_id IS NOT NULL
           AND is_record_field(ef.field_name)""", (extraction_id,))
    out: dict[str, dict[str, dict]] = {}
    for r in rows:
        out.setdefault(r["line_item_id"], {})[r["field_name"]] = r
    return out


def outcomes(extraction_id: str) -> list[dict]:
    return _all("""
        SELECT li.n, v.term, vt.name AS vaccine, o.outcome::text,
               vr.administered_on, vr.expires_on, vr.verification_status::text AS verification,
               v.term_unreadable,
               (SELECT array_agg(rvt.name ORDER BY rvt.name)
                  FROM line_item_request lr
                  JOIN record_request rr  ON rr.id = lr.record_request_id
                  JOIN vaccine_type rvt   ON rvt.id = rr.vaccine_type_id
                 WHERE lr.line_item_id = o.line_item_id) AS requested,
               (SELECT min(rr.channel::text)
                  FROM line_item_request lr JOIN record_request rr ON rr.id = lr.record_request_id
                 WHERE lr.line_item_id = o.line_item_id) AS channel
          FROM line_item_outcome o
          JOIN extraction_line_item li   ON li.id = o.line_item_id
          JOIN v_extraction_line_item v  ON v.line_item_id = o.line_item_id
          LEFT JOIN vaccine_type vt      ON vt.id = o.vaccine_type_id
          LEFT JOIN vaccination_record vr ON vr.id = o.vaccination_record_id
         WHERE o.extraction_id = %s::uuid
         ORDER BY li.n""", (extraction_id,))


# ------------------------------------------------------------------ writing

def save_field(field: dict, action: str | None, typed: str | None) -> str | None:
    """Record one verdict. Returns a sentence for the reviewer if it can't be
    recorded as given, else None. A no-op when nothing changed."""
    extracted = field["extracted_value"]
    typed = (typed or "").strip() or None
    if action is None:
        action, typed = "unreviewed", None
    elif action == "edited":
        if typed is None:
            return "Type what the page says, or choose another answer."
        if typed == extracted:
            action, typed = "confirmed", None          # "corrected" to what the model said
    elif action == "removed" and extracted is None:
        return "There's nothing to remove — the model left this empty."
    else:
        typed = None
    if action == field["action"] and typed == field["corrected_value"]:
        return None
    with _conn() as conn:
        conn.execute("""UPDATE extraction_field
                           SET correction_action = %s::correction_action, corrected_value = %s
                         WHERE id = %s::uuid""", (action, typed, field["id"]))
    return None


def confirm_rest_of_line(line_item_id: str) -> int:
    """'Everything else on this line matches the page.'"""
    with _conn() as conn:
        return conn.execute("""UPDATE extraction_field SET correction_action = 'confirmed'
                                WHERE line_item_id = %s::uuid AND correction_action = 'unreviewed'
                                  AND is_record_field(field_name)""", (line_item_id,)).rowcount


def file_under(document_id: str, dog_id: str) -> None:
    with _conn() as conn:
        conn.execute("""INSERT INTO document_dog (document_id, dog_id) VALUES (%s::uuid, %s::uuid)
                        ON CONFLICT DO NOTHING""", (document_id, dog_id))


def rule_on_term(raw_term: str, vaccine_type_id: str | None, sure: bool, why: str | None,
                 groomer_id: str) -> str | None:
    """Add one vocabulary ruling (section 15). None for 'not a vaccine'."""
    why = (why or "").strip() or None
    if not sure and why is None:
        return "Say why you're not sure — a ruling someone might question needs its reasoning."
    try:
        with _conn() as conn:
            conn.execute("""INSERT INTO document_term (raw_term, vaccine_type_id, confidence, rationale, ruled_by)
                            VALUES (%s, %s::uuid, %s, %s, %s::uuid)""",
                         (raw_term, vaccine_type_id, "high" if sure else "medium", why, groomer_id))
    except psycopg.errors.UniqueViolation:
        return "Someone has already ruled on this spelling. Refresh the page."
    return None


def confirm(extraction_id: str, dog_id: str, groomer_id: str) -> tuple[list[dict] | None, str | None, str | None]:
    """Run Layer 3. Returns (outcomes, None, None), or (None, message, hint)
    when the database refuses — GR015 to GR018 each carry a hint written for a
    groomer, and that is what the screen shows."""
    try:
        with _conn() as conn:
            rows = conn.execute("SELECT * FROM confirm_extraction(%s::uuid, %s::uuid, %s::uuid)",
                                (extraction_id, dog_id, groomer_id)).fetchall()
        return rows, None, None
    except psycopg.Error as e:
        diag = e.diag
        return None, diag.message_primary or str(e), diag.message_hint
