"""The API against a real database: the schema and the demo dogs, rebuilt
fresh for the run so starting a groom here never touches grooming_demo.

The database's own rules are proven by the pgTAP suite. These prove the
translation: that the card says what the views say, and that a refusal
arrives as the database's own words with a 409, not as a 500.
"""
from __future__ import annotations

import os
import subprocess
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

    from fastapi.testclient import TestClient
    from app.main import app
    return TestClient(app)


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
                                             "dog": {"name": "Rolo", "breed": "Not sure"}})
    assert no_coat.status_code == 409
    assert no_coat.json()["message"] == "Choose the dog's coat type"
