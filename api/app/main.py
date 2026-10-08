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
from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel

import json
import os

from . import db, paperwork, reader

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
    # Contact allergies first: they are the ones a groom can set off.
    allergies = db.rows("""
        SELECT a.id, al.name AS allergen, al.allergy_type AS type, a.severity_ordinal AS severity,
               a.source::text AS source, a.note
          FROM allergy a JOIN allergen al ON al.id = a.allergen_id
         WHERE a.dog_id = %s AND a.removed_at IS NULL
         ORDER BY allergy_type_order(al.allergy_type), a.severity_ordinal DESC, al.name""", (dog_id,))
    behaviour = db.rows("""
        SELECT n.id, n.handling_difficulty_ordinal AS difficulty, spot_label(n.body_zone_id, n.side) AS zone,
               bz.code || COALESCE(':' || n.side, '') AS zone_code, n.trigger_kind AS trigger, n.note,
               n.observed_at::date AS observed_on,
               g.display_name AS observed_by
          FROM behavior_note n
          LEFT JOIN body_zone bz ON bz.id = n.body_zone_id
          LEFT JOIN groomer g    ON g.id = n.observed_by
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

    # Which lines rest on a record someone checked by hand against a photo.
    hand_checked = {r["code"]: r for r in db.rows("""
        SELECT vt.code, g.display_name AS checked_by, vr.verified_at::date AS checked_on,
               vr.second_look_at IS NOT NULL AS second_look, vr.document_id, fg.display_name AS fixed_by
          FROM dog_vaccine_compliance s
          JOIN vaccination_record vr ON vr.id = s.latest_record_id
          JOIN vaccine_type vt       ON vt.id = s.vaccine_type_id
          JOIN groomer g             ON g.id = vr.verified_by
          LEFT JOIN groomer fg       ON fg.id = vr.fixed_by
         WHERE s.dog_id = %s AND vr.checked_by_hand""", (dog_id,))}
    for v in vaccines:
        h = hand_checked.get(v["code"])
        v["hand_checked"] = ({k: h[k] for k in ("checked_by", "checked_on", "second_look", "document_id", "fixed_by")}
                             if h else None)
    waiting = db.rows("""SELECT document_id, mime_type, received_by, received_at FROM v_paperwork_waiting
                          WHERE dog_id = %s ORDER BY received_at""", (dog_id,))

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
        "paperwork_waiting": waiting,
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
        "allergens": db.rows("""SELECT name, allergy_type AS type FROM allergen
                                 ORDER BY allergy_type_order(allergy_type), name"""),
        # Where on the dog a handling note can say, sides included.
        "zones": db.rows("SELECT code, label AS name FROM v_handling_spot ORDER BY sort_order"),
    }


@app.get("/allergens/suggest")
def allergen_suggestions(q: str = ""):
    """The nearest names on the allergy list, for "did you mean"."""
    if db.row("SELECT 1 AS ok FROM allergen WHERE lower(name) = lower(btrim(%s))", (q,)):
        return []
    return db.rows("SELECT name, allergy_type AS type FROM suggest_allergens(%s, 4)", (q,))


@app.get("/admin/reviews")
def reviews():
    """Changes that left a dog less protected, waiting for a manager."""
    return db.rows("SELECT * FROM v_change_review_open")


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


# --------------------------------------------------------------- allergies and handling

def _write(sql: str, params: tuple, missing: str = "No such record."):
    """One database call that may refuse; its refusal goes back in its own words."""
    try:
        with db.connect() as conn:
            return conn.execute(sql, params).fetchone()
    except psycopg.Error as e:
        if (r := refusal_from(e, form=True)) is not None:
            raise r from None
        if "not an active client" in str(e):
            raise HTTPException(404, missing) from None
        raise


Severity = Literal[1, 2, 3, 4]
Source = Literal["owner_reported", "observed", "vet_documented"]


class NewAllergy(BaseModel):
    groomer_id: UUID
    allergen: str
    severity: Severity
    source: Source = "owner_reported"
    note: str | None = None
    new_allergen: bool = False                 # the groomer says the list lacks it
    type: Literal["contact", "flea", "environmental", "food"] | None = None


@app.post("/dogs/{dog_id}/allergies", status_code=201)
def add_allergy(dog_id: UUID, body: NewAllergy):
    return _write("SELECT add_allergy(%s, %s, %s, %s::allergy_source, %s, %s, %s, %s) AS id",
                  (dog_id, body.allergen, body.severity, body.source, body.note, body.groomer_id,
                   body.new_allergen, body.type), "No active dog with that id.")


class AllergyEdit(BaseModel):
    groomer_id: UUID
    severity: Severity
    source: Source
    note: str | None = None
    reason: str | None = None                  # needed when it becomes less severe


@app.put("/allergies/{allergy_id}")
def edit_allergy(allergy_id: UUID, body: AllergyEdit):
    return _write("SELECT update_allergy(%s, %s, %s::allergy_source, %s, %s, %s) AS changed",
                  (allergy_id, body.severity, body.source, body.note, body.groomer_id, body.reason))


class Removal(BaseModel):
    groomer_id: UUID
    reason: str


@app.post("/allergies/{allergy_id}/remove")
def remove_allergy(allergy_id: UUID, body: Removal):
    _write("SELECT remove_allergy(%s, %s, %s) AS ok", (allergy_id, body.reason, body.groomer_id))
    return {"removed": True}


Trigger = Literal["dryer", "clippers", "scissors", "nail_grinder", "brushing", "bath", "water",
                  "restraint", "table", "other_dogs", "noise", "other"]


class BehaviourNote(BaseModel):
    groomer_id: UUID
    difficulty: Literal[1, 2, 3, 4, 5]
    trigger: Trigger | None = None
    zone: str | None = None
    note: str | None = None


@app.post("/dogs/{dog_id}/behaviour", status_code=201)
def add_behaviour(dog_id: UUID, body: BehaviourNote):
    return _write("SELECT add_behavior_note(%s, %s, %s, %s, %s, %s) AS id",
                  (dog_id, body.difficulty, body.trigger, body.zone, body.note, body.groomer_id),
                  "No active dog with that id.")


@app.put("/behaviour/{note_id}")
def correct_behaviour(note_id: UUID, body: BehaviourNote):
    return _write("SELECT correct_behavior_note(%s, %s, %s, %s, %s, %s) AS changed",
                  (note_id, body.difficulty, body.trigger, body.zone, body.note, body.groomer_id))


class Reviewer(BaseModel):
    groomer_id: UUID


@app.post("/admin/reviews/{review_id}/reviewed")
def review_done(review_id: UUID, body: Reviewer):
    _write("SELECT mark_reviewed(%s, %s) AS ok", (review_id, body.groomer_id))
    return {"reviewed": True}


# --------------------------------------------------------------- paperwork at the counter

@app.post("/dogs/{dog_id}/paperwork", status_code=201)
def receive_paperwork(dog_id: UUID, groomer_id: UUID = Form(...), files: list[UploadFile] = File(...)):
    """The owner's paperwork, as one copy however many photos and files it
    took: each photo turned upright, stripped of the camera's details and
    downsized if large, each PDF page drawn as a page, all saved under
    private/ and filed against the dog. It waits on the manager's list until
    someone says they are done checking it."""
    try:
        copy = paperwork.prepare([f.file.read(paperwork.MAX_UPLOAD_BYTES + 1) for f in files])
    except paperwork.NotPaperwork as e:
        raise HTTPException(422, str(e)) from None
    try:
        with db.connect() as conn:
            row = conn.execute("SELECT receive_paperwork(%s, %s, %s, %s, %s, %s, %s, %s) AS id",
                               (dog_id, copy.object_key, copy.mime_type, len(copy.data), copy.sha256,
                                copy.page_keys, copy.exif_stripped, groomer_id)).fetchone()
            # Written before the database commits: if saving fails, nothing is
            # filed. A copy already on record (the same files again) is not
            # written a second time.
            doc = conn.execute("SELECT object_key, page_count FROM document WHERE id = %s", (row["id"],)).fetchone()
            if doc["object_key"] == copy.object_key:
                paperwork.save(copy)
    except psycopg.Error as e:
        if (r := refusal_from(e, form=True)) is not None:
            raise r from None
        if "not an active client" in str(e):
            raise HTTPException(404, "No active dog with that id.") from None
        raise
    return {"document_id": row["id"], "mime_type": copy.mime_type, "page_count": doc["page_count"],
            "original_bytes": copy.original_bytes, "saved_bytes": len(copy.data) if copy.mime_type == "image/jpeg"
            else sum(len(p) for p in copy.pages), "resized": copy.resized}


def _page_keys(document_id: UUID) -> list[str]:
    """A copy's pages, in order. A photo filed before copies had pages is its own page."""
    pages = db.rows("""SELECT render_object_key AS key FROM document_page
                        WHERE document_id = %s ORDER BY page_number""", (document_id,))
    if pages:
        return [p["key"] for p in pages]
    doc = db.row("SELECT object_key, mime_type FROM document WHERE id = %s", (document_id,))
    return [doc["object_key"]] if doc and doc["mime_type"].startswith("image/") else []


@app.get("/paperwork/{document_id}")
def paperwork_copy(document_id: UUID):
    """What the screen needs to show a copy: how many pages it has."""
    doc = db.row("SELECT mime_type FROM document WHERE id = %s", (document_id,))
    if doc is None:
        raise HTTPException(404, "No such copy.")
    return {"mime_type": doc["mime_type"], "page_count": len(_page_keys(document_id))}


@app.get("/paperwork/{document_id}/pages/{page}")
def paperwork_page(document_id: UUID, page: int):
    """One page of a copy, as an image. This machine only, like the rest of the API."""
    keys = _page_keys(document_id)
    path = paperwork.path_of(keys[page - 1]) if 1 <= page <= len(keys) else None
    if path is None:
        raise HTTPException(404, "That page isn't on this computer.")
    return FileResponse(path, media_type="image/jpeg", headers={"Cache-Control": "private, max-age=3600"})


@app.get("/paperwork/{document_id}/file")
def paperwork_file(document_id: UUID):
    """The copy itself: the photo, or the PDF of all its pages."""
    doc = db.row("SELECT object_key, mime_type FROM document WHERE id = %s", (document_id,))
    path = paperwork.path_of(doc["object_key"]) if doc else None
    if path is None:
        raise HTTPException(404, "That copy isn't on this computer.")
    return FileResponse(path, media_type=doc["mime_type"], headers={"Cache-Control": "private, max-age=3600"})


@app.post("/dogs/{dog_id}/paperwork/{document_id}/pages/{page}/remove")
def remove_paperwork_page(dog_id: UUID, document_id: UUID, page: int, body: Reviewer):
    """One page taken out of a copy (a dark webcam shot, a duplicate). The
    copy is rebuilt from the pages left, and the unused files deleted."""
    keys = _page_keys(document_id)
    if not 1 <= page <= len(keys):
        raise HTTPException(404, "This copy has no such page.")
    try:
        copy = paperwork.rebuilt(keys[:page - 1] + keys[page:])
    except paperwork.NotPaperwork as e:
        raise HTTPException(422, str(e)) from None
    try:
        with db.connect() as conn:
            row = conn.execute("SELECT remove_paperwork_page(%s, %s, %s, %s, %s, %s, %s) AS keys",
                               (document_id, dog_id, page, body.groomer_id, copy.object_key,
                                len(copy.data), copy.sha256)).fetchone()
            path = paperwork._disk_path(copy.object_key)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(copy.data)
    except psycopg.Error as e:
        if (r := refusal_from(e, form=True)) is not None:
            raise r from None
        raise
    paperwork.discard(row["keys"])
    return {"page_count": len(keys) - 1}


@app.post("/dogs/{dog_id}/paperwork/{document_id}/remove")
def remove_paperwork(dog_id: UUID, document_id: UUID, body: Reviewer):
    """A copy nobody has checked a shot against (a blurry photo, the wrong
    paper) taken off the dog, and its files deleted. Refused once a record
    rests on it (GR029)."""
    row = _write("SELECT remove_paperwork(%s, %s, %s) AS keys", (document_id, dog_id, body.groomer_id))
    paperwork.discard(row["keys"])
    return {"removed": True}


class AiVerdict(BaseModel):
    """When the form was filled in by the AI: which reading, and which of its
    lines this vaccine came from (none: the AI missed it)."""
    ai_extraction_id: UUID | None = None
    ai_line_item_id: UUID | None = None


class CheckedShot(CounterShot, AiVerdict):
    document_id: UUID


def _write_and_grade(sql: str, params: tuple, verdict: AiVerdict, grade: tuple):
    """A write, and the AI's grade for the same vaccine, saved together."""
    try:
        with db.connect() as conn:
            row = conn.execute(sql, params).fetchone()
            if verdict.ai_extraction_id is not None:
                conn.execute("SELECT grade_counter_suggestion(%s, %s, %s, %s, %s, %s)",
                             (verdict.ai_extraction_id, verdict.ai_line_item_id, *grade))
            return row
    except psycopg.Error as e:
        if (r := refusal_from(e, form=True)) is not None:
            raise r from None
        if "not an active client" in str(e):
            raise HTTPException(404, "No active dog with that id.") from None
        raise


@app.post("/dogs/{dog_id}/checked-shots", status_code=201)
def checked_shot(dog_id: UUID, body: CheckedShot):
    """One vaccine typed in while reading the copy: verified, and marked as
    checked by hand. The same refusals as a shot typed with no copy. If the AI
    filled the form in, what was saved is its grade."""
    return _write_and_grade("SELECT record_checked_shot(%s, %s, %s, %s, %s, %s) AS id",
                            (dog_id, body.document_id, body.vaccine, body.administered_on, body.expires_on,
                             body.groomer_id),
                            body, (body.vaccine, body.administered_on, body.expires_on, "saved"))


class AskOwner(AiVerdict):
    groomer_id: UUID
    vaccine: str


@app.post("/dogs/{dog_id}/ask-owner", status_code=201)
def ask_owner(dog_id: UUID, body: AskOwner):
    """A vaccine the owner's paperwork doesn't show: recorded as asked for at
    the counter, and followed up by the shop's reminders. If the AI said it
    was there, it made it up."""
    return _write_and_grade("SELECT ask_owner_at_counter(%s, %s, %s) AS id",
                            (dog_id, body.vaccine, body.groomer_id),
                            body, (body.vaccine, None, None, "not_on_paper"))


@app.post("/dogs/{dog_id}/paperwork/{document_id}/done")
def paperwork_done(dog_id: UUID, document_id: UUID, body: Reviewer):
    _write("SELECT finish_paperwork_check(%s, %s, %s) AS ok", (document_id, dog_id, body.groomer_id))
    return {"done": True}


@app.get("/admin/paperwork")
def paperwork_waiting():
    """Copies received at the counter that nobody has finished checking."""
    return db.rows("SELECT * FROM v_paperwork_waiting")


@app.get("/admin/hand-checked")
def hand_checked():
    """Records a groomer checked by hand, waiting for a manager's second look."""
    return db.rows("SELECT * FROM v_hand_checked_open")


@app.post("/admin/hand-checked/{record_id}/looked")
def second_look(record_id: UUID, body: Reviewer):
    _write("SELECT give_second_look(%s, %s) AS ok", (record_id, body.groomer_id))
    return {"looked": True}


# --------------------------------------------------------------- a manager's fixes

@app.get("/admin/waiting-verification")
def waiting_verification():
    """Shots typed in with no copy of the paperwork, waiting for a manager."""
    return db.rows("SELECT * FROM v_waiting_verification")


class FixedDates(Reviewer):
    administered_on: date | None
    expires_on: date | None


class Verification(FixedDates):
    how: str


def _manager_write(statements: list[tuple[str, tuple]]):
    """A manager's fix, all or nothing; a refusal in its own words."""
    try:
        with db.connect() as conn:
            for sql, params in statements:
                conn.execute(sql, params)
    except psycopg.Error as e:
        if (r := refusal_from(e, form=True)) is not None:
            raise r from None
        raise


@app.post("/admin/records/{record_id}/fix")
def fix_record(record_id: UUID, body: FixedDates):
    """A manager puts a shot's dates right. On a hand-checked shot, that is
    its second look."""
    _manager_write([("SELECT correct_counter_shot(%s, %s, %s, %s)",
                     (record_id, body.administered_on, body.expires_on, body.groomer_id))])
    return {"fixed": True}


@app.post("/admin/records/{record_id}/verify")
def verify_record(record_id: UUID, body: Verification):
    """A manager verifies a shot typed in with no photo, saying how they
    checked it, and puts its dates right first if they were wrong."""
    _manager_write([("SELECT correct_counter_shot(%s, %s, %s, %s)",
                     (record_id, body.administered_on, body.expires_on, body.groomer_id)),
                    ("SELECT verify_counter_shot(%s, %s, %s)", (record_id, body.how, body.groomer_id))])
    return {"verified": True}


# --------------------------------------------------------------- the calendar

@app.get("/calendar")
def calendar(start: date | None = None, end: date | None = None, dog_id: UUID | None = None):
    """Grooms and vaccine expiries by date: those between start and end (a
    month on screen), or one dog's whole history when dog_id is given."""
    if dog_id is None and (start is None or end is None):
        raise HTTPException(422, "Give a span of dates (start and end), or a dog.")
    if start and end and (end - start).days > 400:
        raise HTTPException(422, "Ask for a year or less at a time.")
    return db.rows("""
        SELECT on_date, kind, dog_id, dog, owner, vaccine, groomer, note, stops_grooms, in_progress
          FROM v_calendar_event
         WHERE (%(start)s::date IS NULL OR on_date >= %(start)s)
           AND (%(end)s::date   IS NULL OR on_date <= %(end)s)
           AND (%(dog)s::uuid   IS NULL OR dog_id = %(dog)s)
         ORDER BY on_date, kind DESC, stops_grooms DESC, dog, vaccine""",
                   {"start": start, "end": end, "dog": dog_id})


# --------------------------------------------------------------- the AI's suggestions

@app.get("/ai/status")
def ai_status():
    """Whether "Have the AI read it" can work on this computer."""
    configured = bool(os.environ.get("EXTRACTION_MODEL")) and bool(os.environ.get("ANTHROPIC_API_KEY"))
    return {"available": configured,
            "why_not": None if configured else
            "The AI isn't set up on this computer. Add ANTHROPIC_API_KEY and EXTRACTION_MODEL to .env."}


def _ai_state(document_id: UUID):
    """The latest reading of a copy at the counter: what to fill the form in
    with, and the names it found that nobody has ruled on yet."""
    reading = db.row("""SELECT id, extracted_at, model_version, status::text AS status
                          FROM extraction WHERE document_id = %s AND read_at_counter
                         ORDER BY extracted_at DESC LIMIT 1""", (document_id,))
    if reading is None:
        return {"reading": None}
    suggestions = db.rows("""SELECT vaccine_code, line_item_id, term, administered_on, administered_on_raw,
                                    expires_on, expires_on_raw, given_doubtful, expires_doubtful
                               FROM v_counter_ai_suggestion WHERE extraction_id = %s""", (reading["id"],))
    unfamiliar = db.rows("""SELECT line_item_id, term, administered_on_raw, expires_on_raw
                              FROM v_counter_ai_unfamiliar WHERE extraction_id = %s ORDER BY n""", (reading["id"],))
    return {"reading": {**reading, "failed": reading["status"] == "rejected"},
            "suggestions": {s["vaccine_code"]: s for s in suggestions},
            "unfamiliar": unfamiliar}


@app.get("/paperwork/{document_id}/ai")
def paperwork_ai(document_id: UUID):
    return _ai_state(document_id)


@app.post("/paperwork/{document_id}/ai")
def paperwork_ai_read(document_id: UUID, body: Reviewer):
    """Send the copy to the AI and keep what it read. Takes up to a minute or
    so. Nothing it reads becomes a record: it only fills the form in."""
    doc = db.row("SELECT object_key, mime_type FROM document WHERE id = %s", (document_id,))
    if doc is None:
        raise HTTPException(404, "No such copy.")
    pages = [paperwork.path_of(k) for k in _page_keys(document_id)]
    content = reader.blocks(doc["mime_type"], paperwork.path_of(doc["object_key"]), [p for p in pages if p])
    if not content:
        raise HTTPException(404, "That copy isn't on this computer.")
    try:
        reading = reader.read(content)
    except reader.NotSetUp as e:
        raise HTTPException(503, str(e)) from None
    except reader.ReadFailed as e:
        raise HTTPException(502, str(e)) from None
    doc_fields, line_items = reader.flatten(reading.output) if reading.output is not None else (None, None)
    raw = {**reading.raw_response, "parse_error": reading.parse_error}
    _write("SELECT record_counter_reading(%s, %s, %s, %s, %s, %s::jsonb, %s::jsonb, %s::jsonb) AS id",
           (document_id, body.groomer_id, reading.model_requested, reading.model_version, reading.prompt_version,
            json.dumps(raw), json.dumps(doc_fields) if doc_fields is not None else None,
            json.dumps(line_items) if line_items is not None else None), "No such copy.")
    return _ai_state(document_id)


class TermRuling(BaseModel):
    groomer_id: UUID
    term: str
    vaccine: str | None = None          # None: not a vaccine the shop deals in


@app.post("/paperwork/{document_id}/ai/terms")
def rule_on_term(document_id: UUID, body: TermRuling):
    """Say which vaccine a name the AI found is. The ruling is kept for every
    page after this one."""
    _write("SELECT rule_on_term(%s, %s, %s) AS ok", (body.term, body.vaccine, body.groomer_id))
    return _ai_state(document_id)


@app.get("/admin/ai-accuracy")
def ai_accuracy():
    """How the AI has done on real paperwork, as graded at the counter."""
    return db.rows("SELECT * FROM v_counter_ai_accuracy ORDER BY copy_kind")
