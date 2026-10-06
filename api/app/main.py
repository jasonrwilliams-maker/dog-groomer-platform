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
from typing import Literal
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


# A form answer the database turned down — a missing name, an email already
# on file, no way to reach the owner. Not a rule's refusal, but the same
# shape, so the screen shows the database's own words beside the form.
FORM_PROBLEMS = {"23505", "23514", "23503", "23502", "22007", "22008"}


def refusal_from(e: psycopg.Error, form: bool = False) -> Refusal | None:
    code = e.sqlstate or ""
    if code.startswith("GR") or (form and code in FORM_PROBLEMS):
        message = e.diag.message_primary or str(e)
        if code == "23514" and "owner_contactable" in message:
            message = "Add a phone number or an email, so the shop can reach the owner."
        return Refusal(code, message, e.diag.message_hint)
    return None


# --------------------------------------------------------------- reading

@app.get("/health")
def health():
    db.row("SELECT 1 AS ok")
    return {"ok": True}


@app.get("/groomers")
def groomers():
    """Who can sign in at the counter. A manager also gets the Admin view; the
    screen decides what to show, so this is a convenience, not a lock."""
    return db.rows("""SELECT id, display_name AS name, role::text AS role
                        FROM groomer WHERE is_active ORDER BY display_name""")


# What a search looks in: the dog's name, the owner's name, or either.
SEARCH_IN = {
    "dog":   "d.name ILIKE %(like)s",
    "owner": "(o.first_name ILIKE %(like)s OR o.last_name ILIKE %(like)s"
             " OR (o.first_name || ' ' || o.last_name) ILIKE %(like)s)",
}
SEARCH_IN["any"] = f"({SEARCH_IN['dog']} OR {SEARCH_IN['owner']})"


@app.get("/dogs")
def find_dogs(q: str = "", by: str = "any"):
    """Active dogs whose name, or whose owner's name, contains q — those that
    cannot be groomed today first, then by name. `by` narrows the search to
    the dog's name or the owner's."""
    if by not in SEARCH_IN:
        raise HTTPException(422, "Search by 'dog', 'owner' or 'any'.")
    return db.rows(f"""
        SELECT d.id, d.name, breed_label(d.breed_id, d.is_mixed, d.second_breed_id) AS breed,
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
          LEFT JOIN v_compliance_dashboard c ON c.dog_id = d.id
         WHERE d.is_active AND {SEARCH_IN[by]}
         ORDER BY COALESCE(c.blocks_service, false) DESC, d.name
         LIMIT 200""", {"like": f"%{q.strip()}%"})


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
               breed_label(d.breed_id, d.is_mixed, d.second_breed_id) AS breed, ct.name AS coat,
               o.first_name || ' ' || o.last_name AS owner, o.phone, o.email
          FROM dog d
          JOIN owner o      ON o.id = d.owner_id
          JOIN coat_type ct ON ct.id = d.coat_type_id
          LEFT JOIN breed b ON b.id = d.breed_id
         WHERE d.id = %s AND d.is_active""", (dog_id,))
    if dog is None:
        raise HTTPException(404, "No active dog with that id.")
    profile = db.row("""
        SELECT o.first_name, o.last_name, o.phone, o.email,
               d.name, b.name AS breed, d.is_mixed, b2.name AS second_breed, ct.code AS coat,
               d.sex::text AS sex, d.date_of_birth
          FROM dog d
          JOIN owner o      ON o.id = d.owner_id
          JOIN coat_type ct ON ct.id = d.coat_type_id
          LEFT JOIN breed b  ON b.id = d.breed_id
          LEFT JOIN breed b2 ON b2.id = d.second_breed_id
         WHERE d.id = %s""", (dog_id,))
    household = db.row("""
        SELECT o.id AS owner_id,
               ARRAY(SELECT d2.name FROM dog d2 WHERE d2.owner_id = o.id AND d2.is_active
                       AND d2.id <> %s ORDER BY d2.name) AS other_dogs
          FROM dog d JOIN owner o ON o.id = d.owner_id WHERE d.id = %s""", (dog_id, dog_id))

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
        "household": household,
        "profile": profile,
        "can_start": not blocking,
        "blocking": [f"{v['vaccine']}: {v['label'].lower()}" for v in blocking],
        "vaccines": vaccines,
        "allergies": [{**a, "severity_label": ALLERGY_SEVERITY.get(a["severity"])} for a in allergies],
        "behaviour": [{**b, "difficulty_label": HANDLING.get(b["difficulty"])} for b in behaviour],
        "last_visit": last_visit,
        "open_visit": open_visit,
        "paperwork_requests": requests,
    }


@app.get("/admin/compliance")
def compliance():
    """The manager's view of the whole book: how many dogs are cleared, and
    every vaccine line that needs someone to do something, worst first."""
    counts = db.row("""
        SELECT count(*)                                              AS dogs,
               count(*) FILTER (WHERE NOT COALESCE(c.blocks_service, false)) AS cleared,
               count(*) FILTER (WHERE c.blocks_service)                AS blocked
          FROM dog d LEFT JOIN v_compliance_dashboard c ON c.dog_id = d.id
         WHERE d.is_active""")
    lines = db.rows("""
        SELECT d.id AS dog_id, d.name AS dog, o.first_name || ' ' || o.last_name AS owner,
               l.vaccine, l.state::text AS state, l.label, l.expires_on, l.days_until_expiry,
               l.blocks_service,
               (SELECT rr.status::text FROM record_request rr JOIN vaccine_type vt ON vt.id = rr.vaccine_type_id
                 WHERE rr.dog_id = d.id AND vt.code = l.vaccine_code
                   AND rr.status IN ('queued', 'sent', 'responded', 'insufficient')
                 ORDER BY rr.created_at DESC LIMIT 1) AS request_status
          FROM v_check_in_vaccine l
          JOIN dog d   ON d.id = l.dog_id
          JOIN owner o ON o.id = d.owner_id
         WHERE l.state NOT IN ('current', 'not_yet_due')
         ORDER BY l.blocks_service DESC, l.sort_order, l.days_until_expiry NULLS LAST, d.name, l.vaccine""")
    return {**counts, "lines": lines}


@app.get("/breeds/suggest")
def breed_suggestions(q: str = ""):
    """The nearest names on the breed list to what has been typed, for "did
    you mean". Nothing when it is already a name on the list."""
    if db.row("SELECT 1 AS ok FROM breed WHERE lower(name) = lower(btrim(%s))", (q,)):
        return []
    return db.rows("SELECT name, coat FROM suggest_breeds(%s, 4)", (q,))


@app.get("/walk-in/options")
def walk_in_options():
    """The choices the walk-in form offers: coats, the breeds the shop knows
    (with the coat each usually has), and the vaccines it tracks."""
    return {
        "coats": db.rows("SELECT code, name FROM coat_type ORDER BY name"),
        "breeds": db.rows("""SELECT b.name, ct.code AS coat FROM breed b
                               JOIN coat_type ct ON ct.id = b.default_coat_type_id ORDER BY b.name"""),
        "vaccines": db.rows("""SELECT code, name, regulatory_required AS required FROM vaccine_type
                                WHERE regulatory_required OR required_by_policy
                                ORDER BY regulatory_required DESC, name"""),
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


class NewOwner(BaseModel):
    first_name: str
    last_name: str
    phone: str | None = None
    email: str | None = None


class NewDog(BaseModel):
    name: str
    breed: str | None = None
    is_mixed: bool = False
    second_breed: str | None = None
    new_breed: bool = False                 # the groomer says the list lacks it
    coat: str | None = None
    sex: Literal["male", "female", "unknown"] | None = None
    date_of_birth: date | None = None


class WalkIn(BaseModel):
    groomer_id: UUID
    owner_id: UUID | None = None          # an owner already on file, or
    owner: NewOwner | None = None         # a new one
    dog: NewDog


@app.post("/walk-ins", status_code=201)
def walk_in(body: WalkIn):
    """A new dog, and its owner if they are new too, in one go: both are
    saved or neither is."""
    if (body.owner_id is None) == (body.owner is None):
        raise HTTPException(422, "Give either an owner already on file or a new owner.")
    try:
        with db.connect() as conn:
            owner_id = body.owner_id
            if owner_id is None:
                o = body.owner
                owner_id = conn.execute("SELECT add_client(%s, %s, %s, %s, %s) AS id",
                                        (o.first_name, o.last_name, o.phone, o.email, body.groomer_id)).fetchone()["id"]
            d = body.dog
            dog_id = conn.execute("SELECT add_dog(%s, %s, %s, %s, %s::dog_sex, %s, %s, %s, %s, %s) AS id",
                                  (owner_id, d.name, d.breed, d.coat, d.sex or "unknown", d.date_of_birth,
                                   body.groomer_id, d.is_mixed, d.second_breed, d.new_breed)).fetchone()["id"]
        return {"owner_id": owner_id, "dog_id": dog_id}
    except psycopg.Error as e:
        if (r := refusal_from(e, form=True)) is not None:
            raise r from None
        raise


class CounterShot(BaseModel):
    groomer_id: UUID
    vaccine: str
    administered_on: date | None = None
    expires_on: date | None = None


@app.post("/dogs/{dog_id}/shots", status_code=201)
def counter_shot(dog_id: UUID, body: CounterShot):
    """One vaccine typed in off the owner's paper. Saved as awaiting
    verification; no expiry date is the database's refusal (GR021)."""
    try:
        with db.connect() as conn:
            row = conn.execute("SELECT record_counter_shot(%s, %s, %s, %s, %s) AS id",
                               (dog_id, body.vaccine, body.administered_on, body.expires_on,
                                body.groomer_id)).fetchone()
        return row
    except psycopg.Error as e:
        if (r := refusal_from(e, form=True)) is not None:
            raise r from None
        if "not an active client" in str(e):
            raise HTTPException(404, "No active dog with that id.") from None
        raise


class OwnerEdit(NewOwner):
    groomer_id: UUID


@app.put("/owners/{owner_id}")
def edit_owner(owner_id: UUID, body: OwnerEdit):
    """A typo in the owner's details put right. Returns what changed, as the
    audit log records it."""
    try:
        with db.connect() as conn:
            row = conn.execute("SELECT update_client(%s, %s, %s, %s, %s, %s) AS changed",
                               (owner_id, body.first_name, body.last_name, body.phone, body.email,
                                body.groomer_id)).fetchone()
        return row
    except psycopg.Error as e:
        if (r := refusal_from(e, form=True)) is not None:
            raise r from None
        raise


class DogEdit(NewDog):
    groomer_id: UUID


@app.put("/dogs/{dog_id}")
def edit_dog(dog_id: UUID, body: DogEdit):
    """The same for the dog: name, breed, coat, sex, birthday."""
    try:
        with db.connect() as conn:
            row = conn.execute("SELECT update_dog(%s, %s, %s, %s, %s::dog_sex, %s, %s, %s, %s, %s) AS changed",
                               (dog_id, body.name, body.breed, body.coat, body.sex or "unknown",
                                body.date_of_birth, body.groomer_id, body.is_mixed, body.second_breed,
                                body.new_breed)).fetchone()
        return row
    except psycopg.Error as e:
        if (r := refusal_from(e, form=True)) is not None:
            raise r from None
        if "not an active client" in str(e):
            raise HTTPException(404, "No active dog with that id.") from None
        raise
