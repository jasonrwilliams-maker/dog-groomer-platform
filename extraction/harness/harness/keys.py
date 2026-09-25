"""Answer keys and the canonical shape.

The contract (extraction/answer_key_contract.md) says `expected` is canonical
and compared, and everything else is documentation. This module is the only
place that knows the shape, so a change to the contract is a change here and
nowhere else.
"""
from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path

EXTRACTION_DIR = Path(__file__).resolve().parent.parent.parent   # extraction/
KEYS_DIR = EXTRACTION_DIR / "answer_keys"
CORPUS_FILE = EXTRACTION_DIR / "corpus.json"

# The canonical shape, v4. Order matters only for readable reports.
DOCUMENT_LEVEL: dict[str, list[str]] = {
    "document": ["as_of_date"],
    "clinic":   ["name", "phone", "fax", "email", "website", "address_raw"],
    "owner":    ["name", "clinic_client_id", "address_line1", "address_line2",
                 "city", "state", "postal_code", "phone", "email"],
    "patient":  ["name", "clinic_patient_id", "species_raw", "breed_raw", "sex_raw",
                 "date_of_birth", "age_raw", "weight_raw", "color", "microchip", "tag_number"],
}
LINE_ITEM_FIELDS: list[str] = [
    "term", "source_region",
    "administered_on_raw", "administered_on",
    "expires_on_raw", "expires_on",
    "status_raw",
    "lot_serial_number", "vaccine_manufacturer",
    "veterinarian_name", "veterinarian_license_no", "veterinarian_phone",
    "tag_number",
]
# Emitted for the reviewer, never scored: every format names its regions
# differently and there is no verbatim answer to hold the model to.
UNSCORED_LINE_ITEM_FIELDS = {"source_region"}

DATE_FIELDS = {"as_of_date", "date_of_birth", "administered_on", "expires_on"}

_LI_PATH = re.compile(r"^line_items\[(\d*)\]\.(\w+)$")


@dataclass(frozen=True)
class CorpusDoc:
    document_id: str
    key_path: Path
    file_path: Path
    owner_id: str | None   # None: labelled and scorable, but not loadable until the fixture has the household
    dog_id: str | None


def load_corpus() -> list[CorpusDoc]:
    data = json.loads(CORPUS_FILE.read_text())
    docs = []
    for d in data["documents"]:
        docs.append(CorpusDoc(
            document_id=d["document_id"],
            key_path=(EXTRACTION_DIR / d["key"]).resolve(),
            file_path=(EXTRACTION_DIR / d["file"]).resolve(),
            owner_id=d.get("owner_id"),
            dog_id=d.get("dog_id"),
        ))
    return docs


CONTRACT_VERSION = "v4.3"
_CONTRACT_RE = re.compile(r"answer_key_contract\.md (v4(?:\.\d+)?)\b")

# The four kinds of nothing (contract, "Four kinds of absence"). Every one is
# scored the same way — the model must emit null there — and reported by name,
# because inventing a value the clinic left blank is a different mistake from
# guessing at one the photo made unreadable.
ABSENT_CATEGORIES = ("labeled_but_blank", "unfilled_form_fields", "not_present", "illegible")

# The blocks the harness compares. Everything else in a key is documentation,
# and editing documentation must not change the ruler.
COMPARED_BLOCKS = ("expected", "also_accept", "absent", "must_not_produce")


def load_key(path: Path) -> dict:
    key = json.loads(path.read_text(encoding="utf-8"))
    m = _CONTRACT_RE.search(key.get("_contract", ""))
    if not m:
        raise ValueError(f"{path.name}: not a v4.x key ({key.get('_contract', '')[:40]!r}). "
                         "Keys are only comparable if they agree on the contract.")
    if m.group(1) != CONTRACT_VERSION:
        raise ValueError(f"{path.name}: declares contract {m.group(1)}, harness expects {CONTRACT_VERSION}. "
                         "Bring every key to the same version before comparing any of them.")
    return key


def ruler_version(keys: dict[str, dict], pii_digest: str) -> str:
    """One identifier for everything that decides a score: the compared blocks
    of every key, and the PII map. Re-scoring a run under a different ruler is
    a different evaluation and is stored as one; re-scoring under the same
    ruler is a duplicate and is refused."""
    h = hashlib.sha256()
    for doc_id in sorted(keys):
        compared = {b: strip_annotations(keys[doc_id].get(b)) for b in COMPARED_BLOCKS}
        h.update(doc_id.encode())
        h.update(json.dumps(compared, sort_keys=True, ensure_ascii=False).encode())
    h.update(pii_digest.encode())
    return f"r-{h.hexdigest()[:12]}"


def strip_annotations(obj):
    """Drop every key beginning with '_' at any depth. Those are human notes."""
    if isinstance(obj, dict):
        return {k: strip_annotations(v) for k, v in obj.items() if not k.startswith("_")}
    if isinstance(obj, list):
        return [strip_annotations(v) for v in obj]
    return obj


def flatten(expected: dict) -> dict[str, object]:
    """Canonical shape -> {dotted path: value}.

    Line items are keyed by their printed position n, so
    'line_items[3].expires_on' means the third row on the page regardless of
    the order the model happened to emit them in. Slots the shape defines but
    the object lacks come out as None, so a missing key and an explicit null
    score the same way — the contract says null is the assertion.
    """
    expected = strip_annotations(expected)
    flat: dict[str, object] = {}
    for section, fields in DOCUMENT_LEVEL.items():
        block = expected.get(section) or {}
        for f in fields:
            flat[f"{section}.{f}"] = _clean(block.get(f))
    items = expected.get("line_items") or []
    for i, item in enumerate(items):
        n = item.get("n") or (i + 1)
        for f in LINE_ITEM_FIELDS:
            flat[f"line_items[{n}].{f}"] = _clean(item.get(f))
    return flat


def line_item_count(expected: dict) -> int:
    return len(strip_annotations(expected).get("line_items") or [])


def _clean(v):
    """Normalise only what no transcription could be blamed for: surrounding
    whitespace and runs of internal whitespace. Case and punctuation are the
    page's and are compared as written."""
    if v is None:
        return None
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        v = str(v)
    if isinstance(v, str):
        v = " ".join(v.split())
        return v if v != "" else None
    return v


def parse_path(path: str) -> tuple[str | None, str]:
    """'line_items[7].expires_on' -> ('7', 'expires_on'); 'line_items[].x' -> ('', 'x');
    'patient.color' -> (None, 'patient.color')."""
    m = _LI_PATH.match(path)
    if m:
        return m.group(1), m.group(2)
    return None, path


def expand_path(path: str, n_items: int) -> list[str]:
    """A key path may address every row ('line_items[].x'). Expand it to the
    concrete slots it covers."""
    idx, field = parse_path(path)
    if idx is None:
        return [path]
    if idx == "":
        return [f"line_items[{n}].{field}" for n in range(1, n_items + 1)]
    return [f"line_items[{idx}].{field}"]
