"""The API against a real database: the schema and the demo dogs, rebuilt
fresh for the run so starting a groom here never touches grooming_demo.

The database's own rules are proven by the pgTAP suite. These prove the
translation: that the card says what the views say, and that a refusal
arrives as the database's own words with a 409, not as a 500.
"""
from __future__ import annotations

import io
import os
import subprocess
import tempfile
from datetime import date, timedelta
from pathlib import Path
from urllib.parse import urlparse, urlunparse

import pytest

TEST_DB = "grooming_api_test"
REPO = Path(__file__).resolve().parents[2]


@pytest.fixture(scope="session")
def client():
    base = urlparse(os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/grooming_demo"))
    env = {**os.environ, "PGHOST": base.hostname or "localhost", "PGPORT": str(base.port or 5432),
           "PGUSER": base.username or "postgres", "PGPASSWORD": base.password or ""}
    subprocess.run(["sh", "api/load_demo.sh", "--fresh", TEST_DB], cwd=REPO, env=env, check=True)
    os.environ["DATABASE_URL"] = urlunparse(base._replace(path=f"/{TEST_DB}"))
    # Copies of paperwork go somewhere temporary, never into private/.
    os.environ["PRIVATE_DIR"] = tempfile.mkdtemp(prefix="paperwork-")

    from fastapi.testclient import TestClient
    from app.main import app
    c = TestClient(app)
    # Admin is locked to a verified manager (section 33): Nadia sets up a PIN,
    # which opens it, and every request in the run carries her session.
    nadia = next(g["id"] for g in c.get("/groomers").json() if g["name"] == "Nadia")
    session = c.post("/admin/access/set-pin", json={"groomer_id": nadia, "pin": "2468"}).json()["session"]
    c.headers["X-Admin-Session"] = session["token"]
    return c


def dog_named(client, name: str) -> dict:
    hits = [d for d in client.get("/dogs", params={"q": name}).json() if d["name"] == name]
    assert len(hits) == 1, hits
    return hits[0]


def groomer(client, name: str = "Tanya") -> str:
    return next(g["id"] for g in client.get("/groomers").json() if g["name"] == name)


def test_search_finds_by_dog_or_owner_and_puts_blocked_dogs_first(client):
    by_owner = client.get("/dogs", params={"q": "Williams"}).json()
    assert [d["name"] for d in by_owner] == ["Jaddi"]
    everyone = client.get("/dogs").json()
    flags = [d["blocks_service"] for d in everyone]
    assert flags == sorted(flags, reverse=True), "dogs that cannot be groomed today come first"
    assert len(everyone) == 11


def test_jaddi_card_says_why_he_cannot_be_groomed(client):
    card = client.get(f"/dogs/{dog_named(client, 'Jaddi')['id']}").json()
    assert card["can_start"] is False
    assert card["blocking"] == ["Rabies: expired"]
    rabies = next(v for v in card["vaccines"] if v["code"] == "rabies")
    assert rabies["expires_on"] == "2025-02-28"
    assert [r["status"] for r in card["paperwork_requests"]] == ["insufficient"]


def test_a_card_carries_allergies_behaviour_and_the_last_visit(client):
    card = client.get(f"/dogs/{dog_named(client, 'Tank')['id']}").json()
    assert card["allergies"][0]["allergen"] == "Chlorhexidine shampoo"
    assert card["allergies"][0]["severity_label"] == "Dangerous — never use"
    assert card["behaviour"][0]["trigger"] == "water"
    assert card["last_visit"]["groomer"] == "Nadia"


def test_a_puppy_too_young_for_rabies_can_start(client):
    card = client.get(f"/dogs/{dog_named(client, 'Noodle')['id']}").json()
    assert card["can_start"] is True
    assert card["dog"]["age"] == "11 weeks"
    assert next(v for v in card["vaccines"] if v["code"] == "rabies")["label"] == "Not yet due (puppy)"


def test_starting_a_groom_for_a_blocked_dog_returns_the_databases_refusal(client):
    jaddi = dog_named(client, "Jaddi")["id"]
    r = client.post(f"/dogs/{jaddi}/visits", json={"groomer_id": groomer(client)})
    assert r.status_code == 409
    body = r.json()
    assert body["code"] == "GR020"
    assert body["message"] == "Cannot start the groom: Rabies (expired)"
    assert body["hint"].startswith("Ask the owner for a current certificate")
    assert client.get(f"/dogs/{jaddi}").json()["open_visit"] is None


def test_starting_a_groom_opens_one_visit_and_twice_is_still_one(client):
    pepper = dog_named(client, "Pepper")["id"]
    first = client.post(f"/dogs/{pepper}/visits", json={"groomer_id": groomer(client)})
    assert first.status_code == 201
    again = client.post(f"/dogs/{pepper}/visits", json={"groomer_id": groomer(client, "Nadia")})
    assert again.json()["id"] == first.json()["id"]
    assert client.get(f"/dogs/{pepper}").json()["open_visit"]["groomer"] == "Tanya"


def test_unknown_dog_and_unknown_groomer_are_plain_errors(client):
    missing = "00000000-0000-0000-0000-000000000000"
    assert client.get(f"/dogs/{missing}").status_code == 404
    moose = dog_named(client, "Moose")["id"]
    assert client.post(f"/dogs/{moose}/visits", json={"groomer_id": missing}).status_code == 422


def test_staff_list_says_who_is_a_manager(client):
    roles = {g["name"]: g["role"] for g in client.get("/groomers").json()}
    assert roles == {"Nadia": "manager", "Tanya": "groomer"}


def test_search_can_look_at_only_the_dog_or_only_the_owner(client):
    assert [d["name"] for d in client.get("/dogs", params={"q": "Williams", "by": "owner"}).json()] == ["Jaddi"]
    assert client.get("/dogs", params={"q": "Williams", "by": "dog"}).json() == []
    assert [d["name"] for d in client.get("/dogs", params={"q": "Jaddi", "by": "dog"}).json()] == ["Jaddi"]
    assert client.get("/dogs", params={"by": "breed"}).status_code == 422


def test_compliance_summary_counts_the_book_and_lists_what_needs_doing(client):
    summary = client.get("/admin/compliance").json()
    assert summary["dogs"] == 11
    assert summary["cleared"] + summary["blocked"] == summary["dogs"]
    lines = summary["lines"]
    blocks = [l["blocks_service"] for l in lines]
    assert blocks == sorted(blocks, reverse=True), "what stops a groom comes first"
    assert {"dog": "Jaddi", "vaccine": "Rabies", "state": "expired"}.items() <= next(
        l for l in lines if l["dog"] == "Jaddi").items()
    assert any(l["state"] == "received_unverified" and not l["blocks_service"] for l in lines)
    assert not any(l["state"] in ("current", "not_yet_due") for l in lines)


def test_a_walk_in_is_added_and_held_to_the_same_rule_until_its_paper_is_typed_in(client):
    options = client.get("/walk-in/options").json()
    assert [v["code"] for v in options["vaccines"]][0] == "rabies", "the one the law requires comes first"
    assert {"name": "Shih Tzu", "coat": "silky"} in options["breeds"]
    assert len(options["breeds"]) >= 199, "the whole list, not just the demo's breeds"

    r = client.post("/walk-ins", json={
        "groomer_id": groomer(client),
        "owner": {"first_name": "Maria", "last_name": "Lopez", "phone": "410-555-0300"},
        "dog": {"name": "Biscuit", "breed": "Cavapoo", "coat": "curly", "sex": "female"},
    })
    assert r.status_code == 201
    biscuit = r.json()["dog_id"]
    assert dog_named(client, "Biscuit")["owner"] == "Maria Lopez"
    assert client.get(f"/dogs/{biscuit}").json()["can_start"] is False

    given, expires = str(date.today() - timedelta(days=30)), str(date.today() + timedelta(days=1065))
    no_expiry = client.post(f"/dogs/{biscuit}/shots", json={
        "groomer_id": groomer(client), "vaccine": "rabies", "administered_on": given})
    assert no_expiry.status_code == 409
    assert no_expiry.json()["code"] == "GR021"
    assert no_expiry.json()["message"] == "Rabies: no expiry date, so it cannot be recorded"

    shot = client.post(f"/dogs/{biscuit}/shots", json={
        "groomer_id": groomer(client), "vaccine": "rabies",
        "administered_on": given, "expires_on": expires})
    assert shot.status_code == 201
    card = client.get(f"/dogs/{biscuit}").json()
    assert card["can_start"] is True
    assert next(v for v in card["vaccines"] if v["code"] == "rabies")["state"] == "received_unverified"


def test_a_second_dog_joins_its_owner_and_form_problems_come_back_in_plain_words(client):
    jaddi = client.get(f"/dogs/{dog_named(client, 'Jaddi')['id']}").json()
    r = client.post("/walk-ins", json={"groomer_id": groomer(client), "owner_id": jaddi["household"]["owner_id"],
                                       "dog": {"name": "Ziggy", "breed": "Shih Tzu"}})
    assert r.status_code == 201
    assert "Ziggy" in client.get(f"/dogs/{jaddi['dog']['id']}").json()["household"]["other_dogs"]

    nowhere = client.post("/walk-ins", json={"groomer_id": groomer(client),
                                             "owner": {"first_name": "Sam", "last_name": "Nobody"},
                                             "dog": {"name": "Rolo", "coat": "smooth"}})
    assert nowhere.status_code == 409
    assert nowhere.json()["message"] == "Add a phone number or an email, so the shop can reach the owner."
    assert client.get("/dogs", params={"q": "Rolo"}).json() == [], "neither the owner nor the dog is saved"

    no_coat = client.post("/walk-ins", json={"groomer_id": groomer(client), "owner_id": jaddi["household"]["owner_id"],
                                             "dog": {"name": "Rolo"}})
    assert no_coat.status_code == 409
    assert no_coat.json()["message"] == "Choose the dog's coat type"


def test_a_misspelt_breed_is_caught_and_a_typo_can_be_put_right(client):
    assert client.get("/breeds/suggest", params={"q": "Shitzu"}).json()[0] == {"name": "Shih Tzu", "coat": "silky"}
    assert client.get("/breeds/suggest", params={"q": "shih tzu"}).json() == [], "already a name on the list"

    jaddi_id = dog_named(client, "Jaddi")["id"]
    owner_id = client.get(f"/dogs/{jaddi_id}").json()["household"]["owner_id"]
    typo = client.put(f"/dogs/{jaddi_id}", json={"groomer_id": groomer(client), "name": "Jaddi",
                                               "breed": "Shitzu", "coat": "silky", "sex": "male"})
    assert typo.status_code == 409
    assert typo.json()["code"] == "GR023"
    assert typo.json()["hint"].startswith("Did you mean Shih Tzu")

    mix = client.put(f"/dogs/{jaddi_id}", json={"groomer_id": groomer(client), "name": "Jaddi", "breed": "Shih Tzu",
                                              "is_mixed": True, "second_breed": "Maltese", "coat": "silky",
                                              "sex": "male"})
    assert mix.json()["changed"] == {"breed": {"old": "Shih Tzu", "new": "Shih Tzu × Maltese"}}
    card = client.get(f"/dogs/{jaddi_id}").json()
    assert card["dog"]["breed"] == "Shih Tzu × Maltese"
    assert card["profile"]["second_breed"] == "Maltese"

    renamed = client.put(f"/owners/{owner_id}", json={"groomer_id": groomer(client), "first_name": "Jayson",
                                                      "last_name": "Williams", "phone": "410-555-0100",
                                                      "email": "jason@example.test"})
    assert renamed.json()["changed"] == {"first_name": {"old": "Jason", "new": "Jayson"}}
    assert client.get(f"/dogs/{jaddi_id}").json()["dog"]["owner"] == "Jayson Williams"


def test_allergies_are_kept_from_the_counter_and_a_weaker_one_waits_for_a_manager(client):
    tank = dog_named(client, "Tank")["id"]
    card = client.get(f"/dogs/{tank}").json()
    assert card["allergies"][0]["type"] == "contact", "contact allergies come first"

    assert client.get("/allergens/suggest", params={"q": "Chiken"}).json()[0]["name"] == "Chicken"
    typo = client.post(f"/dogs/{tank}/allergies", json={"groomer_id": groomer(client), "allergen": "Chiken",
                                                     "severity": 2})
    assert typo.status_code == 409 and typo.json()["code"] == "GR024"
    added = client.post(f"/dogs/{tank}/allergies", json={"groomer_id": groomer(client), "allergen": "Chicken",
                                                      "severity": 2, "note": "Treats only"})
    assert added.status_code == 201
    chicken = added.json()["id"]

    weaker = client.put(f"/allergies/{chicken}", json={"groomer_id": groomer(client), "severity": 1,
                                                       "source": "owner_reported", "note": "Treats only"})
    assert weaker.status_code == 409 and weaker.json()["code"] == "GR025"
    removed = client.post(f"/allergies/{chicken}/remove", json={"groomer_id": groomer(client),
                                                                "reason": "Owner says it was the beef"})
    assert removed.status_code == 200
    assert "Chicken" not in [a["allergen"] for a in client.get(f"/dogs/{tank}").json()["allergies"]]

    waiting = client.get("/admin/reviews").json()
    assert [(r["dog"], r["summary"], r["reason"]) for r in waiting] == [
        ("Tank", "Chicken (Moderate) taken off", "Owner says it was the beef")]
    not_manager = client.post(f"/admin/reviews/{waiting[0]['id']}/reviewed", json={"groomer_id": groomer(client)})
    assert not_manager.status_code == 409 and not_manager.json()["code"] == "GR036", "Admin is Nadia's"
    done = client.post(f"/admin/reviews/{waiting[0]['id']}/reviewed", json={"groomer_id": groomer(client, "Nadia")})
    assert done.status_code == 200 and client.get("/admin/reviews").json() == []


def test_a_handling_note_is_added_and_a_typo_in_it_put_right(client):
    moose = dog_named(client, "Moose")["id"]
    r = client.post(f"/dogs/{moose}/behaviour", json={"groomer_id": groomer(client), "difficulty": 3,
                                                     "trigger": "scissors", "zone": "feet:back", "note": "Kiks"})
    assert r.status_code == 201
    latest = client.get(f"/dogs/{moose}").json()["behaviour"][0]
    assert (latest["trigger"], latest["zone"], latest["observed_by"]) == ("scissors", "Back feet", "Tanya")
    assert latest["zone_code"] == "feet:back", "what the edit form starts from"
    fixed = client.put(f"/behaviour/{latest['id']}", json={"groomer_id": groomer(client), "difficulty": 3,
                                                          "trigger": "scissors", "zone": "feet:back", "note": "Kicks"})
    assert fixed.json()["changed"] == {"note": {"old": "Kiks", "new": "Kicks"}}


def tablet_photo(width: int = 4032, height: int = 3024) -> bytes:
    """A camera-sized JPEG carrying a GPS position, as a tablet photo would."""
    from PIL import Image
    im = Image.new("RGB", (width, height), "white")
    exif = im.getexif()
    exif[0x010F] = "TabletCo"                       # make
    exif.get_ifd(0x8825)[2] = (39.0, 17.0, 0.0)     # GPS latitude
    buf = io.BytesIO()
    im.save(buf, format="JPEG", quality=95, exif=exif)
    return buf.getvalue()


def test_a_photo_of_the_paperwork_is_downsized_checked_by_hand_and_waits_for_a_second_look(client):
    from PIL import Image
    jaddi = dog_named(client, "Jaddi")["id"]
    tanya, nadia = groomer(client), groomer(client, "Nadia")

    not_a_photo = client.post(f"/dogs/{jaddi}/paperwork", data={"groomer_id": tanya},
                              files={"files": ("notes.txt", b"rabies 2026", "text/plain")})
    assert not_a_photo.status_code == 422

    up = client.post(f"/dogs/{jaddi}/paperwork", data={"groomer_id": tanya},
                     files={"files": ("IMG_0001.jpg", tablet_photo(), "image/jpeg")})
    assert up.status_code == 201, up.text
    body = up.json()
    assert body["resized"] and body["page_count"] == 1
    assert body["saved_bytes"] < body["original_bytes"]
    doc = body["document_id"]

    again = client.post(f"/dogs/{jaddi}/paperwork", data={"groomer_id": tanya},
                        files={"files": ("IMG_0001.jpg", tablet_photo(), "image/jpeg")})
    assert again.json()["document_id"] == doc, "the same photo twice is one copy"
    other_owner = client.post(f"/dogs/{dog_named(client, 'Moose')['id']}/paperwork", data={"groomer_id": tanya},
                              files={"files": ("IMG_0001.jpg", tablet_photo(), "image/jpeg")})
    assert other_owner.status_code == 201 and other_owner.json()["document_id"] != doc,         "another owner handing in the same file gets a copy of their own"

    file = client.get(f"/paperwork/{doc}/file")
    assert file.status_code == 200 and file.headers["content-type"] == "image/jpeg"
    saved = Image.open(io.BytesIO(file.content))
    assert saved.size == (2576, 1932), "downsized to the long edge the model reads"
    assert len(saved.getexif()) == 0, "no camera details or GPS kept"

    card = client.get(f"/dogs/{jaddi}").json()
    assert [w["document_id"] for w in card["paperwork_waiting"]] == [doc]
    assert card["can_start"] is False

    given, expires = date.today() - timedelta(days=10), date.today() + timedelta(days=1085)
    shot = client.post(f"/dogs/{jaddi}/checked-shots", json={
        "groomer_id": tanya, "document_id": doc, "vaccine": "rabies",
        "administered_on": given.isoformat(), "expires_on": expires.isoformat()})
    assert shot.status_code == 201, shot.text

    card = client.get(f"/dogs/{jaddi}").json()
    assert card["can_start"] is True
    rabies = next(v for v in card["vaccines"] if v["code"] == "rabies")
    assert rabies["label"] == "Current"
    assert rabies["hand_checked"]["checked_by"] == "Tanya"
    assert rabies["hand_checked"]["second_look"] is False

    assert client.post(f"/dogs/{jaddi}/paperwork/{doc}/done", json={"groomer_id": tanya}).status_code == 200
    assert client.get(f"/dogs/{jaddi}").json()["paperwork_waiting"] == []
    assert all(w["document_id"] != doc for w in client.get("/admin/paperwork").json())

    open_ = [r for r in client.get("/admin/hand-checked").json() if r["dog"] == "Jaddi"]
    assert [r["vaccine"] for r in open_] == ["Rabies"]
    refused = client.post(f"/admin/hand-checked/{open_[0]['id']}/looked", json={"groomer_id": tanya})
    assert refused.status_code == 409 and refused.json()["code"] == "GR036"
    assert client.post(f"/admin/hand-checked/{open_[0]['id']}/looked", json={"groomer_id": nadia}).status_code == 200
    assert not [r for r in client.get("/admin/hand-checked").json() if r["dog"] == "Jaddi"]


def test_a_checked_shot_needs_the_photo_on_file(client):
    moose = dog_named(client, "Moose")["id"]
    r = client.post(f"/dogs/{moose}/checked-shots", json={
        "groomer_id": groomer(client), "document_id": "00000000-0000-0000-0000-000000000000",
        "vaccine": "rabies", "administered_on": (date.today() - timedelta(days=5)).isoformat(),
        "expires_on": (date.today() + timedelta(days=360)).isoformat()})
    assert r.status_code == 409 and r.json()["code"] == "GR027"


def test_a_vaccine_not_on_the_paperwork_is_asked_for_and_shows_on_the_card(client):
    gus = dog_named(client, "Gus")["id"]
    r = client.post(f"/dogs/{gus}/ask-owner", json={"groomer_id": groomer(client), "vaccine": "bordetella"})
    assert r.status_code == 201, r.text
    card = client.get(f"/dogs/{gus}").json()
    asked = [p for p in card["paperwork_requests"] if p["vaccine"] == "Bordetella"]
    assert asked and asked[0]["channel"] == "verbal_at_counter" and asked[0]["next_reminder_on"]


def two_page_pdf() -> bytes:
    from PIL import Image
    pages = [Image.new("RGB", (850, 1100), c) for c in ("white", "ivory")]
    buf = io.BytesIO()
    pages[0].save(buf, format="PDF", save_all=True, append_images=pages[1:])
    return buf.getvalue()


def test_several_photos_and_a_pdf_are_one_copy_with_pages_and_an_unused_copy_can_be_removed(client):
    from PIL import Image
    olive = dog_named(client, "Olive")["id"]
    tanya = groomer(client)
    up = client.post(f"/dogs/{olive}/paperwork", data={"groomer_id": tanya}, files=[
        ("files", ("page1.jpg", tablet_photo(), "image/jpeg")),
        ("files", ("page2.jpg", tablet_photo(3024, 4032), "image/jpeg")),
        ("files", ("emailed.pdf", two_page_pdf(), "application/pdf")),
    ])
    assert up.status_code == 201, up.text
    doc = up.json()["document_id"]
    assert up.json()["page_count"] == 4 and up.json()["mime_type"] == "application/pdf"
    assert client.get(f"/paperwork/{doc}").json()["page_count"] == 4
    sizes = [Image.open(io.BytesIO(client.get(f"/paperwork/{doc}/pages/{n}").content)).size for n in (1, 2, 3, 4)]
    assert sizes[0] == (2576, 1932) and sizes[1] == (1932, 2576), "each photo is its own page, upright"
    assert max(sizes[2]) == 2576, "a PDF page is drawn at the same size"
    assert client.get(f"/paperwork/{doc}/pages/5").status_code == 404
    assert client.get(f"/paperwork/{doc}/file").content[:5] == b"%PDF-"

    page2 = client.get(f"/paperwork/{doc}/pages/2").content
    dark = client.post(f"/dogs/{olive}/paperwork/{doc}/pages/1/remove", json={"groomer_id": tanya})
    assert dark.status_code == 200 and dark.json()["page_count"] == 3
    assert client.get(f"/paperwork/{doc}/pages/1").content == page2, "the pages after it move up"
    assert client.get(f"/paperwork/{doc}/file").content[:5] == b"%PDF-"

    gone = client.post(f"/dogs/{olive}/paperwork/{doc}/remove", json={"groomer_id": tanya})
    assert gone.status_code == 200
    assert client.get(f"/paperwork/{doc}").status_code == 404
    assert client.get(f"/dogs/{olive}").json()["paperwork_waiting"] == []


def test_a_copy_shots_were_checked_against_stays(client):
    jaddi = dog_named(client, "Jaddi")["id"]
    rabies = next(v for v in client.get(f"/dogs/{jaddi}").json()["vaccines"] if v["code"] == "rabies")
    r = client.post(f"/dogs/{jaddi}/paperwork/{rabies['hand_checked']['document_id']}/remove",
                    json={"groomer_id": groomer(client)})
    assert r.status_code == 409 and r.json()["code"] == "GR029"


def test_a_manager_verifies_a_typed_in_shot_and_fixes_a_misread_one(client):
    tanya, nadia = groomer(client), groomer(client, "Nadia")
    waiting = [r for r in client.get("/admin/waiting-verification").json() if r["dog"] == "Daisy"]
    assert [r["vaccine"] for r in waiting] == ["Rabies"]
    daisy = waiting[0]

    form = {"how": "Called the vet's office", "administered_on": daisy["administered_on"],
            "expires_on": daisy["expires_on"]}
    refused = client.post(f"/admin/records/{daisy['id']}/verify", json={**form, "groomer_id": tanya})
    assert refused.status_code == 409 and refused.json()["code"] == "GR036"
    blank = client.post(f"/admin/records/{daisy['id']}/verify", json={**form, "how": " ", "groomer_id": nadia})
    assert blank.status_code == 409 and "how you checked" in blank.json()["message"]
    ok = client.post(f"/admin/records/{daisy['id']}/verify", json={**form, "groomer_id": nadia})
    assert ok.status_code == 200, ok.text
    assert not [r for r in client.get("/admin/waiting-verification").json() if r["dog"] == "Daisy"]

    # A groomer misreads a date off a photo; the manager fixes it from the list.
    moose = dog_named(client, "Moose")["id"]
    doc = client.post(f"/dogs/{moose}/paperwork", data={"groomer_id": tanya},
                      files={"files": ("bordetella.jpg", tablet_photo(900, 700), "image/jpeg")}).json()["document_id"]
    given = date.today() - timedelta(days=5)
    misread = client.post(f"/dogs/{moose}/checked-shots", json={
        "groomer_id": tanya, "document_id": doc, "vaccine": "bordetella",
        "administered_on": given.isoformat(), "expires_on": (given + timedelta(days=30)).isoformat()})
    assert misread.status_code == 201, misread.text
    record = misread.json()["id"]
    bad = client.post(f"/admin/records/{record}/fix", json={
        "groomer_id": nadia, "administered_on": given.isoformat(), "expires_on": None})
    assert bad.status_code == 409 and bad.json()["code"] == "GR021"
    fixed = client.post(f"/admin/records/{record}/fix", json={
        "groomer_id": nadia, "administered_on": given.isoformat(),
        "expires_on": (given + timedelta(days=365)).isoformat()})
    assert fixed.status_code == 200, fixed.text
    assert all(r["id"] != record for r in client.get("/admin/hand-checked").json())
    bordetella = next(v for v in client.get(f"/dogs/{moose}").json()["vaccines"] if v["code"] == "bordetella")
    assert bordetella["expires_on"] == (given + timedelta(days=365)).isoformat()
    assert bordetella["hand_checked"]["checked_by"] == "Tanya", "who checked it by hand stays on the record"
    assert bordetella["hand_checked"]["fixed_by"] == "Nadia"


def test_the_calendar_shows_grooms_and_expiries_by_month_or_by_dog(client):
    olive = dog_named(client, "Olive")["id"]
    whole = client.get("/calendar", params={"dog_id": olive}).json()
    kinds = {e["kind"] for e in whole}
    assert kinds == {"groom", "expiry"} and all(e["dog"] == "Olive" for e in whole)
    groom = next(e for e in whole if e["kind"] == "groom")
    month = client.get("/calendar", params={"start": groom["on_date"][:8] + "01", "end": groom["on_date"]}).json()
    assert any(e["kind"] == "groom" and e["dog"] == "Olive" for e in month)
    assert all(e["on_date"] <= groom["on_date"] for e in month)
    rabies = [e for e in client.get("/calendar", params={"dog_id": dog_named(client, "Moose")["id"]}).json()
              if e["vaccine"] == "Rabies"]
    assert rabies and rabies[0]["stops_grooms"] is True
    assert client.get("/calendar").status_code == 422


def test_a_groom_is_booked_with_the_usual_groomer_and_shows_on_card_and_calendar(client):
    olive = dog_named(client, "Olive")["id"]
    tanya, nadia = groomer(client), groomer(client, "Nadia")
    day = date.fromisoformat(client.get("/booking/hours").json()["today"]) + timedelta(days=1)
    at = f"{day.isoformat()}T10:00:00"

    offer = client.get("/booking/choices", params={"dog_id": olive, "starts_at": at, "minutes": 60}).json()
    assert offer["choices"][0]["groomer"] == "Tanya" and offer["choices"][0]["is_regular"] is True
    assert at in offer["choices"][0]["free_starts"]

    form = {"dog_id": olive, "groomer_id": tanya, "starts_at": at, "minutes": 60, "booked_by": nadia}
    booked = client.post("/appointments", json=form)
    assert booked.status_code == 201, booked.text
    clash = client.post("/appointments", json={**form, "dog_id": dog_named(client, "Pepper")["id"]})
    assert clash.status_code == 409 and clash.json()["code"] == "GR031"
    elsewhere = client.post("/appointments", json={**form, "groomer_id": nadia, "starts_at": f"{day.isoformat()}T14:00:00"})
    assert elsewhere.status_code == 409 and elsewhere.json()["code"] == "GR032"

    card = client.get(f"/dogs/{olive}").json()
    assert [a["groomer"] for a in card["appointments"]] == ["Tanya"]
    assert card["usual_groomer"]["name"] == "Tanya"
    month = client.get("/calendar", params={"start": day.isoformat(), "end": day.isoformat()}).json()
    assert any(e["kind"] == "booking" and e["dog"] == "Olive" and e["starts_at"] == "10:00:00" for e in month)

    appt = booked.json()["id"]
    assert client.post(f"/appointments/{appt}/cancel", json={"groomer_id": tanya, "reason": "Owner sick"}).status_code == 200
    assert client.get(f"/dogs/{olive}").json()["appointments"] == []


def test_a_dog_photo_is_kept_in_three_sizes_replaced_and_removed(client):
    from PIL import Image
    noodle = dog_named(client, "Noodle")["id"]
    tanya = groomer(client)
    assert client.get(f"/dogs/{noodle}").json()["photo"] is None
    assert client.get(f"/dogs/{noodle}/photo").status_code == 404, "no photo yet: the screen shows the placeholder"

    not_a_photo = client.post(f"/dogs/{noodle}/photo", data={"groomer_id": tanya},
                              files={"file": ("notes.txt", b"a good boy", "text/plain")})
    assert not_a_photo.status_code == 422

    first = client.post(f"/dogs/{noodle}/photo", data={"groomer_id": tanya},
                        files={"file": ("IMG_0002.jpg", tablet_photo(), "image/jpeg")})
    assert first.status_code == 201, first.text
    card = client.get(f"/dogs/{noodle}").json()
    assert card["photo"]["id"] == first.json()["photo"]
    assert dog_named(client, "Noodle")["photo"] == first.json()["photo"], "the dog list knows there is a photo"
    thumb = Image.open(io.BytesIO(client.get(f"/dogs/{noodle}/photo", params={"size": "thumb"}).content))
    display = Image.open(io.BytesIO(client.get(f"/dogs/{noodle}/photo").content))
    assert thumb.size == (256, 256) and max(display.size) == 1200
    assert len(display.getexif()) == 0, "no camera details or GPS kept"

    old_files = list(Path(os.environ["PRIVATE_DIR"]).rglob("*.jpg"))
    second = client.post(f"/dogs/{noodle}/photo", data={"groomer_id": tanya},
                         files={"file": ("IMG_0003.jpg", tablet_photo(800, 1000), "image/jpeg")})
    assert second.status_code == 201 and second.json()["photo"] != first.json()["photo"]
    assert len(list(Path(os.environ["PRIVATE_DIR"]).rglob("*.jpg"))) == len(old_files), "the old photo's files are gone"

    assert client.post(f"/dogs/{noodle}/photo/remove", json={"groomer_id": tanya}).status_code == 200
    assert client.get(f"/dogs/{noodle}").json()["photo"] is None
    assert client.get(f"/dogs/{noodle}/photo").status_code == 404


class FakeReply:
    """What the SDK's final message looks like, enough for app/reader.py."""
    def __init__(self, text: str, stop_reason: str = "end_turn"):
        self.content = [type("Block", (), {"type": "text", "text": text})()]
        self.stop_reason = stop_reason
        self.model = "claude-test-1"
        self.usage = type("Usage", (), {"input_tokens": 1200, "output_tokens": 800})()


def fake_reading(term_2: str = "Kennel Cough Nasal") -> str:
    import json
    line = lambda n, term, given, expires: {
        "n": n, "term": term, "source_region": None, "administered_on_raw": given, "administered_on": given,
        "expires_on_raw": expires, "expires_on": expires}
    given = (date.today() - timedelta(days=7)).isoformat()
    return json.dumps({
        "document": {}, "clinic": {"name": "Harbor Vet"}, "owner": {}, "patient": {"name": "Gus"},
        "line_items": [line(1, "Rabies Vaccine 3 Year", given, (date.today() + timedelta(days=1088)).isoformat()),
                       line(2, term_2, given, (date.today() + timedelta(days=358)).isoformat())]})


def test_the_ai_fills_the_form_in_and_what_is_saved_grades_it(client, monkeypatch):
    from app import reader
    gus = dog_named(client, "Gus")["id"]
    tanya = groomer(client)
    monkeypatch.setenv("EXTRACTION_MODEL", "claude-test")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")
    sent = {}
    def fake_call(name, system, content):
        sent.update(name=name, kinds=[b["type"] for b in content], system=system)
        return FakeReply(fake_reading())
    monkeypatch.setattr(reader, "call_model", fake_call)

    assert client.get("/ai/status").json()["available"] is True
    doc = client.post(f"/dogs/{gus}/paperwork", data={"groomer_id": tanya},
                      files={"files": ("emailed.pdf", two_page_pdf(), "application/pdf")}).json()["document_id"]
    assert client.get(f"/paperwork/{doc}/ai").json() == {"reading": None}

    state = client.post(f"/paperwork/{doc}/ai", json={"groomer_id": tanya}).json()
    assert sent["kinds"] == ["document"], "an emailed PDF goes to the model as a PDF"
    assert "Transcribe" in sent["system"] or len(sent["system"]) > 1000, "the harness's prompt"
    rabies = state["suggestions"]["rabies"]
    assert rabies["expires_on"] == (date.today() + timedelta(days=1088)).isoformat()
    assert [u["term"] for u in state["unfamiliar"]] == ["Kennel Cough Nasal"]

    state = client.post(f"/paperwork/{doc}/ai/terms",
                        json={"groomer_id": tanya, "term": "Kennel Cough Nasal", "vaccine": "bordetella"}).json()
    assert "bordetella" in state["suggestions"] and state["unfamiliar"] == []

    # Rabies saved one day off what the AI read; Bordetella said not to be there.
    saved = client.post(f"/dogs/{gus}/checked-shots", json={
        "groomer_id": tanya, "document_id": doc, "vaccine": "rabies",
        "administered_on": rabies["administered_on"], "expires_on": (date.today() + timedelta(days=1087)).isoformat(),
        "ai_extraction_id": state["reading"]["id"], "ai_line_item_id": rabies["line_item_id"]})
    assert saved.status_code == 201, saved.text
    asked = client.post(f"/dogs/{gus}/ask-owner", json={
        "groomer_id": tanya, "vaccine": "bordetella",
        "ai_extraction_id": state["reading"]["id"], "ai_line_item_id": state["suggestions"]["bordetella"]["line_item_id"]})
    assert asked.status_code == 201, asked.text

    score = {r["copy_kind"]: r for r in client.get("/admin/ai-accuracy").json()}
    assert score["pdf"]["right_first_time"] == 1 and score["pdf"]["read_wrong"] == 1
    assert score["pdf"]["made_up"] == 2


def test_the_ai_says_plainly_when_it_is_not_set_up(client, monkeypatch):
    monkeypatch.delenv("EXTRACTION_MODEL", raising=False)
    olive = dog_named(client, "Olive")["id"]
    doc = client.post(f"/dogs/{olive}/paperwork", data={"groomer_id": groomer(client)},
                      files={"files": ("p.jpg", tablet_photo(800, 600), "image/jpeg")}).json()["document_id"]
    assert client.get("/ai/status").json()["available"] is False
    r = client.post(f"/paperwork/{doc}/ai", json={"groomer_id": groomer(client)})
    assert r.status_code == 503 and "isn't set up" in r.json()["detail"]


def test_a_groom_is_finished_with_its_haircut_and_the_next_one_starts_from_it(client):
    willow, tanya = dog_named(client, "Willow")["id"], groomer(client)
    visit = client.post(f"/dogs/{willow}/visits", json={"groomer_id": tanya}).json()["id"]

    start = client.get(f"/dogs/{willow}/haircut").json()
    assert start["visit"]["id"] == visit and start["usual"] is None and start["start"] is None
    plan = {z["zone_code"]: z for z in client.get(f"/dogs/{willow}/haircut/plan",
                                                    params={"style": "teddy_bear", "length": "medium"}).json()}
    assert plan["ears"]["cut"] == "#4F" and plan["sanitary"]["is_hygiene"] is True

    done = client.post(f"/visits/{visit}/finish", json={
        "groomer_id": tanya, "services": ["full_groom", "bath"],
        "coat": {"condition": 2, "density": 3},
        "haircut": {"style": "teddy_bear", "length": "medium", "keep_as_usual": True,
                    "changes": [{"zone": "ears", "tool": "scissors"}]},
        "note": "Muzzle on for ears only, as usual."})
    assert done.status_code == 200, done.text

    card = client.get(f"/dogs/{willow}").json()
    assert card["open_visit"] is None
    assert card["last_visit"]["haircut"] == "Teddy Bear, medium"
    assert card["last_visit"]["haircut_changes"] == [{"zone": "Ears", "cut": "Scissors", "today": True, "flagged": False}]
    usual = client.get(f"/dogs/{willow}/haircut").json()["usual"]
    assert usual["style"] == "Teddy Bear" and usual["changes"] == [{"zone": "Ears", "cut": "Scissors"}]

    again = client.post(f"/visits/{visit}/finish", json={"groomer_id": tanya, "services": ["bath"]})
    assert again.status_code == 409


def test_finishing_is_all_or_nothing_and_refusals_come_back_in_their_own_words(client):
    olive, tanya = dog_named(client, "Olive")["id"], groomer(client)
    visit = client.post(f"/dogs/{olive}/visits", json={"groomer_id": tanya}).json()["id"]

    pelted = client.post(f"/visits/{visit}/finish", json={
        "groomer_id": tanya, "services": ["full_groom"], "coat": {"condition": 5, "density": 4},
        "haircut": {"style": "shaved"}})
    assert pelted.status_code == 409 and pelted.json()["code"] == "GR033"
    assert pelted.json()["hint"]
    bath_only = client.post(f"/visits/{visit}/finish", json={
        "groomer_id": tanya, "services": ["bath"], "haircut": {"style": "teddy_bear", "length": "short"}})
    assert bath_only.status_code == 409 and bath_only.json()["code"] == "GR004"
    assert client.get(f"/dogs/{olive}").json()["open_visit"]["id"] == visit, "nothing was saved"

    told = client.post(f"/visits/{visit}/finish", json={
        "groomer_id": tanya, "services": ["full_groom"], "coat": {"condition": 5, "density": 4},
        "haircut": {"style": "shaved", "shave_acknowledged": True}})
    assert told.status_code == 200, told.text
    assert client.get(f"/dogs/{olive}").json()["last_visit"]["haircut"] == "Shaved (remedial)"


def test_admin_opens_only_for_a_verified_manager(client):
    nadia, tanya = groomer(client, "Nadia"), groomer(client)
    locked = client.get("/admin/compliance", headers={"X-Admin-Session": ""})
    assert locked.status_code == 401 and locked.json()["code"] == "locked"

    assert client.get(f"/admin/access/{nadia}").json() | {"passkeys": 0} == {
        "name": "Nadia", "is_manager": True, "set_up": True, "has_pin": True, "passkeys": 0, "open": True}
    wrong = client.post("/admin/access/pin", json={"groomer_id": nadia, "pin": "0000"})
    assert wrong.status_code == 409 and wrong.json()["code"] == "GR036"
    right = client.post("/admin/access/pin", json={"groomer_id": nadia, "pin": "2468"}).json()
    mine = {"X-Admin-Session": right["token"]}
    assert right["name"] == "Nadia" and client.get("/admin/reviews", headers=mine).status_code == 200

    groomer_try = client.post("/admin/access/set-pin", json={"groomer_id": tanya, "pin": "1357"},
                              headers={"X-Admin-Session": ""})
    assert groomer_try.status_code == 409 and groomer_try.json()["code"] == "GR037"
    no_pin = client.post("/admin/access/pin", json={"groomer_id": tanya, "pin": "1357"})
    assert no_pin.status_code == 409 and no_pin.json()["code"] == "GR036"

    assert client.post("/admin/access/lock", headers=mine).status_code == 200
    assert client.get("/admin/reviews", headers=mine).status_code == 401


def test_adding_a_passkey_starts_with_a_challenge_and_a_forged_one_is_refused(client):
    nadia = groomer(client, "Nadia")
    options = client.post("/admin/access/register/options", json={"groomer_id": nadia}).json()
    assert options["rp"]["id"] == "localhost" and options["challenge"]
    assert options["authenticatorSelection"]["userVerification"] == "required"
    forged = client.post("/admin/access/register", json={"groomer_id": nadia, "credential": {
        "id": "AAAA", "rawId": "AAAA", "type": "public-key",
        "response": {"clientDataJSON": "e30", "attestationObject": "oA"}}})
    assert forged.status_code == 409 and forged.json()["code"] == "GR037"
    no_keys = client.post("/admin/access/passkey/options", json={"groomer_id": nadia})
    assert no_keys.status_code == 409, "no passkey was added"


class SoftPasskey:
    """A stand-in for a fingerprint reader: makes a key pair and answers the
    backend's challenges the way a browser and Windows Hello would."""

    ORIGIN = "http://localhost:3000"

    def __init__(self):
        import secrets
        from cryptography.hazmat.primitives.asymmetric import ec
        self.key = ec.generate_private_key(ec.SECP256R1())
        self.cred_id = secrets.token_bytes(16)

    @staticmethod
    def b64(b: bytes) -> str:
        import base64
        return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

    def _client_data(self, kind: str, challenge: str) -> bytes:
        import json as j
        return j.dumps({"type": kind, "challenge": challenge, "origin": self.ORIGIN, "crossOrigin": False}).encode()

    def _rp_hash(self) -> bytes:
        import hashlib
        return hashlib.sha256(b"localhost").digest()

    def register(self, options: dict) -> dict:
        import cbor2
        nums = self.key.public_key().public_numbers()
        cose = cbor2.dumps({1: 2, 3: -7, -1: 1, -2: nums.x.to_bytes(32, "big"), -3: nums.y.to_bytes(32, "big")})
        auth = (self._rp_hash() + bytes([0x45]) + (0).to_bytes(4, "big") + bytes(16)
                + len(self.cred_id).to_bytes(2, "big") + self.cred_id + cose)
        return {"id": self.b64(self.cred_id), "rawId": self.b64(self.cred_id), "type": "public-key",
                "response": {"clientDataJSON": self.b64(self._client_data("webauthn.create", options["challenge"])),
                             "attestationObject": self.b64(cbor2.dumps({"fmt": "none", "attStmt": {}, "authData": auth})),
                             "transports": ["internal"]},
                "clientExtensionResults": {}, "authenticatorAttachment": "platform"}

    def sign(self, options: dict, user_handle: bytes | None = None, verified: bool = True) -> dict:
        import hashlib
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import ec
        client = self._client_data("webauthn.get", options["challenge"])
        # Present, verified if so; Windows Hello keeps its counter at 0.
        auth = self._rp_hash() + bytes([0x05 if verified else 0x01]) + (0).to_bytes(4, "big")
        sig = self.key.sign(auth + hashlib.sha256(client).digest(), ec.ECDSA(hashes.SHA256()))
        return {"id": self.b64(self.cred_id), "rawId": self.b64(self.cred_id), "type": "public-key",
                "response": {"clientDataJSON": self.b64(client), "authenticatorData": self.b64(auth),
                             "signature": self.b64(sig), "userHandle": self.b64(user_handle) if user_handle else None},
                "clientExtensionResults": {}, "authenticatorAttachment": "platform"}


def test_a_passkey_added_opens_admin_again_and_again(client):
    from uuid import UUID
    nadia = groomer(client, "Nadia")
    device = SoftPasskey()
    added = client.post("/admin/access/register", json={
        "groomer_id": nadia, "label": "Test device",
        "credential": device.register(client.post("/admin/access/register/options", json={"groomer_id": nadia}).json())})
    assert added.status_code == 201, added.text

    # Twice, as after a page reload; the second answer without the "verified"
    # flag, as a real Windows laptop sent it.
    for verified in (True, False):
        options = client.post("/admin/access/passkey/options", json={"groomer_id": nadia}).json()
        opened = client.post("/admin/access/passkey", json={
            "groomer_id": nadia, "credential": device.sign(options, UUID(nadia).bytes, verified)},
            headers={"X-Admin-Session": ""})
        assert opened.status_code == 200, opened.text
        assert client.get("/admin/reviews", headers={"X-Admin-Session": opened.json()["token"]}).status_code == 200

    stranger = SoftPasskey()      # a key that was never added
    options = client.post("/admin/access/passkey/options", json={"groomer_id": nadia}).json()
    forged = client.post("/admin/access/passkey", json={"groomer_id": nadia, "credential": stranger.sign(options)},
                         headers={"X-Admin-Session": ""})
    assert forged.status_code == 409 and forged.json()["code"] == "GR036"
    replay = client.post("/admin/access/passkey", json={"groomer_id": nadia, "credential": device.sign(options)},
                         headers={"X-Admin-Session": ""})
    assert replay.status_code == 409, "a challenge opens Admin once at most"
