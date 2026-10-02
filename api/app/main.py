"""The groomer interface's backend.

Thin on purpose. Every rule — who may be groomed, what a vaccine's state is,
what blocks service — is decided in the database; this layer reads the views
that already say so and calls the functions that already enforce it. Its own
job is two translations:

  * rows into the shapes a screen wants, and
  * a database refusal (SQLSTATE GR0xx) into a 409 that carries the refusal's
    own message and the hint written for a groomer — never a stack trace,
    never a reworded guess.
"""
from __future__ import annotations

from datetime import date
from uuid import UUID

import psycopg
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from . import db

app = FastAPI(title="Paws & Polish — groomer API", version="0.1.0")

# Presentation words for two ordinal scales the schema stores as numbers.
ALLERGY_SEVERITY = {1: "Mild", 2: "Moderate", 3: "Severe", 4: "Dangerous — never use"}
HANDLING = {1: "Easy", 2: "Some care", 3: "Needs care", 4: "Two people", 5: "Specialist only"}


# --------------------------------------------------------------- refusals

class Refusal(Exception):
    def __init__(self, code: str, message: str, hint: str | None):
        self.code, self.message, self.hint = code, message, hint


@app.exception_handler(Refusal)
async def refusal_handler(_: Request, r: Refusal):
    return JSONResponse(status_code=409, content={"code": r.code, "message": r.message, "hint": r.hint})


def refusal_from(e: psycopg.Error) -> Refusal | None:
    code = e.sqlstate or ""
    if code.startswith("GR"):
        return Refusal(code, e.diag.message_primary or str(e), e.diag.message_hint)
    return None


# --------------------------------------------------------------- reading

@app.get("/health")
def health():
    db.row("SELECT 1 AS ok")
    return {"ok": True}


@app.get("/groomers")
def groomers():
    return db.rows("SELECT id, display_name AS name FROM groomer WHERE is_active ORDER BY display_name")


@app.get("/dogs")
def find_dogs(q: str = ""):
    """Active dogs whose name, or whose owner's name, contains q — those that
    cannot be groomed today first, then by name."""
    like = f"%{q.strip()}%"
    return db.rows("""
        SELECT d.id, d.name, b.name AS breed,
               o.first_name || ' ' || o.last_name AS owner,
               c.state::text AS state, c.plain_language_label AS label,
               COALESCE(c.blocks_service, false) AS blocks_service,
               -- The one line a groomer should know about first, named:
               -- 'Bordetella: expired' says more than the dog's worst state.
               (SELECT l.vaccine || ': ' || lower(l.label) FROM v_check_in_vaccine l
                 WHERE l.dog_id = d.id AND l.state NOT IN ('current', 'not_yet_due')
                 ORDER BY l.blocks_service DESC, l.sort_order, l.vaccine LIMIT 1) AS attention
          FROM dog d
          JOIN owner o ON o.id = d.owner_id
          LEFT JOIN breed b ON b.id = d.breed_id
          LEFT JOIN v_compliance_dashboard c ON c.dog_id = d.id
         WHERE d.is_active
           AND (d.name ILIKE %s OR o.first_name ILIKE %s OR o.last_name ILIKE %s
                OR (o.first_name || ' ' || o.last_name) ILIKE %s)
         ORDER BY COALESCE(c.blocks_service, false) DESC, d.name
         LIMIT 50""", (like, like, like, like))


def _age(born: date | None) -> str | None:
    if born is None:
        return None
    days = (date.today() - born).days
    if days < 7 * 26:
        return f"{days // 7} weeks"
    years, months = divmod(days * 12 // 365, 12)
    return f"{years} yr {months} mo" if years else f"{months} months"


@app.get("/dogs/{dog_id}")
def check_in_card(dog_id: UUID):
    dog = db.row("""
        SELECT d.id, d.name, d.sex::text AS sex, d.date_of_birth, d.is_altered,
               b.name AS breed, ct.name AS coat,
               o.first_name || ' ' || o.last_name AS owner, o.phone, o.email
          FROM dog d
          JOIN owner o      ON o.id = d.owner_id
          JOIN coat_type ct ON ct.id = d.coat_type_id
          LEFT JOIN breed b ON b.id = d.breed_id
         WHERE d.id = %s AND d.is_active""", (dog_id,))
    if dog is None:
        raise HTTPException(404, "No active dog with that id.")

    vaccines = db.rows("""
        SELECT vaccine_code AS code, vaccine, state::text AS state, label, expires_on,
               days_until_expiry, blocks_service, regulatory_required
          FROM v_check_in_vaccine WHERE dog_id = %s ORDER BY sort_order, vaccine""", (dog_id,))
    allergies = db.rows("""
        SELECT al.name AS allergen, a.severity_ordinal AS severity, a.source::text AS source, a.note
          FROM allergy a JOIN allergen al ON al.id = a.allergen_id
         WHERE a.dog_id = %s ORDER BY a.severity_ordinal DESC, al.name""", (dog_id,))
    behaviour = db.rows("""
        SELECT n.handling_difficulty_ordinal AS difficulty, bz.plain_language_label AS zone,
               n.trigger_kind AS trigger, n.note, n.observed_at::date AS observed_on
          FROM behavior_note n LEFT JOIN body_zone bz ON bz.id = n.body_zone_id
         WHERE n.dog_id = %s ORDER BY n.observed_at DESC LIMIT 5""", (dog_id,))
    last_visit = db.row("""
        SELECT v.visit_date, g.display_name AS groomer, v.overall_note AS note
          FROM visit v JOIN groomer g ON g.id = v.performed_by
         WHERE v.dog_id = %s AND v.check_out IS NOT NULL
         ORDER BY v.visit_date DESC, v.check_in DESC NULLS LAST LIMIT 1""", (dog_id,))
    open_visit = db.row("""
        SELECT v.id, v.check_in, g.display_name AS groomer
          FROM visit v JOIN groomer g ON g.id = v.performed_by
         WHERE v.dog_id = %s AND v.check_out IS NULL AND v.visit_date = shop_now()::date
         ORDER BY v.created_at DESC LIMIT 1""", (dog_id,))
    requests = db.rows("""
        SELECT vt.name AS vaccine, rr.status::text AS status, rr.channel::text AS channel,
               rr.next_reminder_on
          FROM record_request rr JOIN vaccine_type vt ON vt.id = rr.vaccine_type_id
         WHERE rr.dog_id = %s AND rr.status IN ('queued', 'sent', 'responded', 'insufficient')
         ORDER BY vt.name""", (dog_id,))

    blocking = [v for v in vaccines if v["blocks_service"]]
    return {
        "dog": {**dog, "age": _age(dog["date_of_birth"])},
        "can_start": not blocking,
        "blocking": [f"{v['vaccine']}: {v['label'].lower()}" for v in blocking],
        "vaccines": vaccines,
        "allergies": [{**a, "severity_label": ALLERGY_SEVERITY.get(a["severity"])} for a in allergies],
        "behaviour": [{**b, "difficulty_label": HANDLING.get(b["difficulty"])} for b in behaviour],
        "last_visit": last_visit,
        "open_visit": open_visit,
        "paperwork_requests": requests,
    }


# --------------------------------------------------------------- writing

class StartVisit(BaseModel):
    groomer_id: UUID


@app.post("/dogs/{dog_id}/visits", status_code=201)
def start_groom(dog_id: UUID, body: StartVisit):
    """The database's start_visit(): refuses while a service-blocking vaccine
    is not in order (GR020), and returns the open visit if the dog is already
    checked in today."""
    try:
        with db.connect() as conn:
            visit = conn.execute("SELECT start_visit(%s, %s) AS id", (dog_id, body.groomer_id)).fetchone()
            row = conn.execute("""SELECT v.id, v.visit_date, v.check_in, g.display_name AS groomer
                                    FROM visit v JOIN groomer g ON g.id = v.performed_by
                                   WHERE v.id = %s""", (visit["id"],)).fetchone()
        return row
    except psycopg.Error as e:
        if (r := refusal_from(e)) is not None:
            raise r from None
        if e.sqlstate == "23503":                       # unknown groomer
            raise HTTPException(422, "No such groomer.") from None
        if "not an active client" in str(e):
            raise HTTPException(404, "No active dog with that id.") from None
        raise
