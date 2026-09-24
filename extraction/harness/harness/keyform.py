"""Read, edit and write answer keys without hand-editing JSON.

The labelling tool (extraction/review/app.py) is a form over these functions.
They live in the harness because they are about keys, not about screens, and
because the self-check proves them: every key in the corpus must survive a
load and a save byte for byte.

The working copy IS the key dict. Nothing is rebuilt from a form; each edit
touches one slot, so the human annotations a key carries (every `_note`,
`_reasoning`, `_index_corrected`) stay where they were. The only structural
edits — adding, deleting and moving rows — renumber every path that points at
a row, so an absence or a trap keeps pointing at the same printed line.
"""
from __future__ import annotations

import copy
import json
import re
from datetime import date
from pathlib import Path

from . import keys as K
from . import pii as P
from . import score as S

DRAFTS_DIR = K.EXTRACTION_DIR.parent / "private" / "drafts"   # gitignored with private/
PRIVATE_DIR = K.EXTRACTION_DIR.parent / "private"
CONTRACT_LINE = (f"answer_key_contract.md {K.CONTRACT_VERSION} — `expected` and `also_accept` are "
                 "canonical and compared; keys beginning with `_` are never compared.")

DOC_CLASSES = ["rabies_certificate", "vet_invoice", "form51", "handwritten_note", "unknown"]   # sql enum document_class
SOURCES = ["upload", "email_reply", "scan"]                                                    # sql enum document_source
MEDIA_TYPES = {".pdf": "application/pdf", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
               ".png": "image/png", ".heic": "image/heic"}
TRAP_LAYERS = ["extraction", "resolution"]
# caught_by_plausibility_check is true, false, or "partially" in the corpus.
PLAUSIBILITY = {"yes": True, "no": False, "partially": "partially"}

DOC_PATHS = [f"{sec}.{f}" for sec, fields in K.DOCUMENT_LEVEL.items() for f in fields]
DATE_PAIRS = {"administered_on": "administered_on_raw", "expires_on": "expires_on_raw"}
_ISO = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_SLUG = re.compile(r"^[a-z0-9][a-z0-9_\-.]*$")


# ------------------------------------------------------------------ files

def dumps(key: dict) -> str:
    """The exact bytes every key in the corpus is stored as."""
    return json.dumps(key, indent=2, ensure_ascii=False) + "\n"


def write(path: Path, obj: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(dumps(obj), encoding="utf-8", newline="\n")


def published_path(document_id: str) -> Path:
    return K.KEYS_DIR / f"{document_id}.key.json"


def draft_path(document_id: str) -> Path:
    return DRAFTS_DIR / f"{document_id}.key.json"


def private_files() -> list[Path]:
    """Every document in private/ — not the PII map, not the drafts."""
    return sorted(p for p in PRIVATE_DIR.iterdir()
                  if p.is_file() and p.suffix.lower() in MEDIA_TYPES)


def load_corpus_json() -> dict:
    return json.loads(K.CORPUS_FILE.read_text(encoding="utf-8"))


def upsert_corpus(entry: dict) -> None:
    """Add or replace one document in corpus.json, keeping everything else."""
    data = load_corpus_json()
    docs = data["documents"]
    for i, d in enumerate(docs):
        if d["document_id"] == entry["document_id"]:
            docs[i] = {**d, **entry}
            break
    else:
        docs.append(entry)
    write(K.CORPUS_FILE, data)


# -------------------------------------------------------------- new keys

def skeleton(document_id: str, source_file: str) -> dict:
    """A key with every slot present and null. The contract: do not prune
    slots the page lacks — null is the assertion."""
    suffix = Path(source_file).suffix.lower()
    return {
        "_contract": CONTRACT_LINE,
        "meta": {
            "document_id": document_id,
            "source_file": source_file,
            "format_family": None,
            "doc_class": "unknown",
            "source": "upload",
            "mime_type": MEDIA_TYPES.get(suffix),
            "page_count": 1,
            "dog": None,
            "household": None,
            "capture_quality": {"medium": None},
            "pii": {"substituted": []},
        },
        "expected": {
            **{sec: {f: None for f in fields} for sec, fields in K.DOCUMENT_LEVEL.items()},
            "line_items": [],
        },
        "also_accept": {},
        "absent": {c: [] for c in K.ABSENT_CATEGORIES},
        "must_not_produce": [],
        "annotations": {},
    }


START_FROM_BLOCKS = {
    "meta":        "Format, document type, source, household",
    "clinic":      "Clinic block (name, phone, address…)",
    "owner":       "Owner block",
    "patient":     "Patient block",
    "row_terms":   "Row terms only — every date, lot and vet left blank",
    "absent_rules": "Absences that apply to every row (line_items[]…)",
}


def start_from(template: dict, document_id: str, source_file: str, blocks: set[str]) -> dict:
    """A new key that borrows chosen parts of an existing one — for a second
    copy of a known format. Traps are never copied: a trap is a prediction
    about THIS page, and it has to be written by someone looking at it.

    Every value copied is listed in meta._unchecked until the labeller has
    checked it against THIS page. A copied key records what the OTHER page
    said; a photo of the same document may be unreadable exactly where the
    original was clear, and then the honest value here is `illegible`."""
    new = _start_from(template, document_id, source_file, blocks)
    new["meta"]["_started_from"] = template.get("meta", {}).get("document_id")
    new["meta"]["_unchecked"] = copied_paths(new)
    return new


def copied_paths(key: dict) -> list[str]:
    paths = [p for p in DOC_PATHS if get(key, p) is not None]
    paths += [f"line_items[{r['n']}].term" for r in rows(key) if r.get("term")]
    return paths


def _start_from(template: dict, document_id: str, source_file: str, blocks: set[str]) -> dict:
    new = skeleton(document_id, source_file)
    t = copy.deepcopy(template)
    if "meta" in blocks:
        for f in ("format_family", "doc_class", "source", "dog", "household"):
            if f in t.get("meta", {}):
                new["meta"][f] = t["meta"][f]
    for sec in ("clinic", "owner", "patient"):
        if sec in blocks:
            new["expected"][sec] = {f: t["expected"][sec].get(f) for f in K.DOCUMENT_LEVEL[sec]}
    if "row_terms" in blocks:
        for i, row in enumerate(t["expected"].get("line_items") or []):
            r = blank_row(i + 1)
            r["term"] = row.get("term")
            r["source_region"] = row.get("source_region")
            new["expected"]["line_items"].append(r)
    if "absent_rules" in blocks:
        for cat in K.ABSENT_CATEGORIES:
            for e in (t.get("absent") or {}).get(cat) or []:
                if isinstance(e, dict) and str(e.get("field", "")).startswith("line_items[]."):
                    new["absent"][cat].append({"field": e["field"]})
    return new


def preview_copy(template: dict, blocks: set[str]) -> list[dict]:
    """What start_from would copy, as table rows, before anything is created."""
    k = _start_from(template, "preview", "preview.pdf", blocks)
    out = [{"slot": p, "value": str(get(k, p))} for p in copied_paths(k)]
    out += [{"slot": e["field"], "value": f"(every row: {cat})"}
            for cat in K.ABSENT_CATEGORIES for e in k["absent"].get(cat) or []]
    return out


# ------------------------------------------------------- copied values

def unchecked(key: dict) -> list[str]:
    return list(key.get("meta", {}).get("_unchecked") or [])


def mark_checked(key: dict, path: str) -> None:
    """A copied value has been compared with this page — kept, changed, or
    marked as a kind of nothing. Once the list is empty it is removed."""
    meta = key.get("meta", {})
    if path in (meta.get("_unchecked") or []):
        meta["_unchecked"].remove(path)
        if not meta["_unchecked"]:
            del meta["_unchecked"]


def blank_row(n: int) -> dict:
    return {"n": n, **{f: None for f in K.LINE_ITEM_FIELDS}}


# ------------------------------------------------- review priority
#
# Not every copied value deserves the same attention. A wrong date on a rabies
# row ends up on a vaccination record; a wrong date on a fecal test ends up
# nowhere. So the labelling tool lets the unimportant ones be checked a section
# at a time, and keeps the important ones one by one.
#
# "Important" is read from the database's own seed files — the document_term
# vocabulary and the vaccine_type tracking flags — never from a list kept here.
# It orders a human's review and is written into no key: the model still
# transcribes, and the database still classifies.

SQL_DIR = K.EXTRACTION_DIR.parent / "sql"
_TERM_ROW = re.compile(r"\(\s*'((?:[^']|'')*)',\s*(?:\(SELECT id FROM vaccine_type WHERE code='(\w+)'\)|NULL)")
_VACCINE_ROW = re.compile(r"\(\s*'(\w+)',\s*'[^']*',\s*(true|false),\s*(true|false),")


def normalize_term(term: str) -> str:
    """sql/15_document_term.sql normalize_term(), line for line."""
    s = re.sub(r"\s*([-/])\s*", r"\1", term.lower())
    s = re.sub(r"\s+", " ", s).strip()
    return s.rstrip(".")


def load_vocabulary(sql_dir: Path = SQL_DIR) -> tuple[dict[str, str | None], set[str]]:
    """({normalized term: vaccine code or None}, {tracked vaccine codes})."""
    terms: dict[str, str | None] = {}
    seed = (sql_dir / "15_document_term.sql").read_text(encoding="utf-8")
    block = seed[seed.index("INSERT INTO document_term"):]
    for raw, code in _TERM_ROW.findall(block):
        terms[normalize_term(raw.replace("''", "'"))] = code or None
    schema = (sql_dir / "grooming_platform_schema.sql").read_text(encoding="utf-8")
    vt = schema[schema.index("INSERT INTO vaccine_type"):]
    vt = vt[:vt.index(";")]
    tracked = {code for code, reg, pol in _VACCINE_ROW.findall(vt) if reg == "true" or pol == "true"}
    return terms, tracked


PRIORITY_TRACKED, PRIORITY_UNKNOWN, PRIORITY_OTHER = "tracked", "unknown", "other"


def row_priority(term: str | None, vocab: tuple[dict, set]) -> str:
    """tracked: a vaccine the shop tracks. unknown: a term with no ruling —
    fails closed, like resolve_term(), because it might be one. other: ruled
    not a vaccine, or a vaccine the shop does not track."""
    terms, tracked = vocab
    if not term:
        return PRIORITY_UNKNOWN
    n = normalize_term(term)
    if n not in terms:
        return PRIORITY_UNKNOWN
    return PRIORITY_TRACKED if terms[n] in tracked else PRIORITY_OTHER


def bulk_checkable(key: dict, vocab: tuple[dict, set]) -> dict[str, list[str]]:
    """Unchecked paths that may be checked a group at a time, by group:
    each header section, and every row that is not a tracked vaccine or an
    unknown term. What is left out must be checked one by one."""
    groups: dict[str, list[str]] = {}
    low_rows = {r["n"] for r in rows(key) if row_priority(r.get("term"), vocab) == PRIORITY_OTHER}
    for p in unchecked(key):
        idx, _ = K.parse_path(p)
        if idx is None:
            groups.setdefault(p.split(".", 1)[0], []).append(p)
        elif int(idx) in low_rows:
            groups.setdefault("rows", []).append(p)
    return groups


def mark_all_checked(key: dict, paths: list[str]) -> None:
    for p in list(paths):
        mark_checked(key, p)


# ----------------------------------------------------------- slot access

def get(key: dict, path: str):
    """Read one slot by dotted path: 'owner.city' or 'line_items[3].expires_on'."""
    idx, f = K.parse_path(path)
    exp = key["expected"]
    if idx is None:
        sec, name = path.split(".", 1)
        return (exp.get(sec) or {}).get(name)
    row = row_by_n(key, int(idx))
    return None if row is None else row.get(f)


def set_value(key: dict, path: str, value) -> None:
    value = K._clean(value)
    idx, f = K.parse_path(path)
    exp = key["expected"]
    if idx is None:
        sec, name = path.split(".", 1)
        exp.setdefault(sec, {})[name] = value
    else:
        row_by_n(key, int(idx))[f] = value


def rows(key: dict) -> list[dict]:
    return key["expected"].setdefault("line_items", [])


def row_by_n(key: dict, n: int) -> dict | None:
    for r in rows(key):
        if r.get("n") == n:
            return r
    return None


# ------------------------------------------------------------- absences

def absent_block(key: dict) -> dict:
    return key.setdefault("absent", {})


def absence_of(key: dict, path: str) -> tuple[str | None, dict | None]:
    """The category a concrete path is recorded under, and its entry."""
    for cat in K.ABSENT_CATEGORIES:
        for e in absent_block(key).get(cat) or []:
            if isinstance(e, dict) and e.get("field") == path:
                return cat, e
    return None, None


def set_absence(key: dict, path: str, category: str | None) -> None:
    """Mark one slot as a kind of nothing, or unmark it. The entry keeps its
    notes when it moves between categories. Marking clears the value: an
    absence and a value in the same slot contradict each other."""
    current, entry = absence_of(key, path)
    if current == category:
        return
    block = absent_block(key)
    if current is not None:
        block[current].remove(entry)
    if category is not None:
        block.setdefault(category, []).append(entry or {"field": path})
        set_value(key, path, None)


def note_text(obj) -> str:
    """A `_note` may be a string or a list of lines; the form shows text."""
    if obj is None:
        return ""
    return "\n".join(obj) if isinstance(obj, list) else str(obj)


def set_note(holder: dict, text: str, field: str = "_note") -> None:
    """Write a note back only if it changed, so a list-of-lines note that
    nobody touched keeps its shape."""
    if text == note_text(holder.get(field)):
        return
    if text.strip():
        holder[field] = text
    else:
        holder.pop(field, None)


def row_rules(key: dict) -> list[dict]:
    """Absence entries that are not one concrete slot: rules for every row
    (line_items[].x) and printed questions the shape has no slot for.
    Returned as table rows; `_ref` finds the entry again on save."""
    out = []
    for cat in K.ABSENT_CATEGORIES:
        for i, e in enumerate(absent_block(key).get(cat) or []):
            if isinstance(e, dict) and not _is_concrete(e.get("field", "")):
                out.append({"category": cat, "field": e.get("field", ""),
                            "note": note_text(e.get("_note")), "_ref": f"{cat}#{i}"})
    return out


def rule_originals(key: dict) -> dict[str, dict]:
    """The rule entries by `_ref`, copied. The form takes this snapshot when a
    key is opened and matches every later edit against it, so re-applying the
    same table is always the same edit."""
    out = {}
    for cat in K.ABSENT_CATEGORIES:
        for i, e in enumerate(absent_block(key).get(cat) or []):
            if isinstance(e, dict) and not _is_concrete(e.get("field", "")):
                out[f"{cat}#{i}"] = copy.deepcopy(e)
    return out


def set_row_rules(key: dict, table: list[dict], originals: dict[str, dict] | None = None) -> None:
    """Replace the rule entries with the edited table, keeping every other key
    of an entry that survived (a `_source_text`, a `correct_value`)."""
    block = absent_block(key)
    old = rule_originals(key) if originals is None else originals
    kept = {cat: [e for e in (block.get(cat) or []) if not (isinstance(e, dict) and not _is_concrete(e.get("field", "")))]
            for cat in K.ABSENT_CATEGORIES if cat in block}
    rebuilt: dict[str, list] = {}
    for r in table:
        field, cat = (r.get("field") or "").strip(), r.get("category")
        if not field or cat not in K.ABSENT_CATEGORIES:
            continue
        entry = copy.deepcopy(old.get(r.get("_ref") or "", {}))
        entry["field"] = field
        entry = {"field": field, **{k: v for k, v in entry.items() if k != "field"}}
        set_note(entry, r.get("note") or "")
        rebuilt.setdefault(cat, []).append(entry)
    # Put rules back where they were relative to concrete entries: rules first
    # if the original list started with one, otherwise after. Only order
    # changes here, and order is never compared — but an untouched key must
    # come back byte for byte.
    for cat in K.ABSENT_CATEGORIES:
        if cat not in block and cat not in rebuilt:
            continue
        orig = block.get(cat) or []
        new_rules, concrete = rebuilt.get(cat, []), kept.get(cat, [])
        merged, ri, ci = [], 0, 0
        for e in orig:
            is_rule = isinstance(e, dict) and not _is_concrete(e.get("field", ""))
            if is_rule and ri < len(new_rules):
                merged.append(new_rules[ri]); ri += 1
            elif not is_rule and ci < len(concrete):
                merged.append(concrete[ci]); ci += 1
        merged += new_rules[ri:] + concrete[ci:]
        block[cat] = merged


def _is_concrete(path: str) -> bool:
    if path in DOC_PATHS:
        return True
    idx, f = K.parse_path(path)
    return idx not in (None, "") and f in K.LINE_ITEM_FIELDS


def rule_field_options(key: dict) -> list[str]:
    """What the Absences table may name: every row-wide slot, plus anything a
    key already names (printed questions the shape has no slot for)."""
    opts = [f"line_items[].{f}" for f in K.LINE_ITEM_FIELDS if f != "source_region"]
    for r in row_rules(key):
        if r["field"] not in opts:
            opts.append(r["field"])
    return opts


# ------------------------------------------------------------ also_accept

def also_accept_table(key: dict) -> list[dict]:
    out = []
    for path, vals in (key.get("also_accept") or {}).items():
        if path.startswith("_"):
            continue
        for v in vals:
            out.append({"field": path, "also_accept": v})
    return out


def set_also_accept(key: dict, table: list[dict]) -> None:
    had = "also_accept" in key
    old = key.get("also_accept") or {}
    new = {k: v for k, v in old.items() if k.startswith("_")}
    for r in table:
        path, v = (r.get("field") or "").strip(), K._clean(r.get("also_accept"))
        if path and v is not None:
            new.setdefault(path, []).append(v)
    if new or had:
        key["also_accept"] = new


# ------------------------------------------------------------------ traps

TRAP_COLUMNS = ["id", "layer", "field", "wrong_value", "source_of_error", "why_tempting",
                "caught_by_plausibility_check", "note"]


def trap_table(key: dict) -> list[dict]:
    out = []
    for t in key.get("must_not_produce") or []:
        out.append({"id": t.get("id"), "layer": t.get("layer", "extraction"), "field": t.get("field"),
                    "wrong_value": None if t.get("wrong_value") is None else str(t.get("wrong_value")),
                    "source_of_error": t.get("source_of_error"), "why_tempting": t.get("why_tempting"),
                    "caught_by_plausibility_check": _plaus_label(t.get("caught_by_plausibility_check")),
                    "note": note_text(t.get("_note"))})
    return out


def _plaus_label(v) -> str | None:
    for label, val in PLAUSIBILITY.items():
        if v is val or v == val and type(v) is type(val):
            return label
    return None


def trap_originals(key: dict) -> dict:
    return {t.get("id"): copy.deepcopy(t) for t in key.get("must_not_produce") or []}


def _as_id(v) -> int | None:
    try:
        return int(v) if v not in (None, "") and float(v) == int(float(v)) else None
    except (TypeError, ValueError):
        return None


def set_traps(key: dict, table: list[dict], originals: dict | None = None) -> None:
    """Traps are matched to their originals by id, so an entry's other
    annotations (`_arithmetic`, `_index_corrected`) survive an edit. A new
    trap gets the next free id — the same id however often the table is
    re-applied, because the numbering starts from the snapshot, not the draft."""
    old = trap_originals(key) if originals is None else originals
    out, used = [], set()
    next_id = max([t.get("id") or 0 for t in old.values()]
                  + [_as_id(r.get("id")) or 0 for r in table] + [0]) + 1
    for r in table:
        if not (r.get("field") or "").strip():
            continue
        tid = _as_id(r.get("id"))
        if tid is None or tid in used:
            tid, next_id = next_id, next_id + 1
        used.add(tid)
        t = copy.deepcopy(old.get(tid, {}))
        orig_wrong = t.get("wrong_value")
        wrong = r.get("wrong_value")
        if orig_wrong is not None and wrong == str(orig_wrong):
            wrong = orig_wrong          # keep a numeric wrong_value numeric
        t.update({"id": tid, "layer": r.get("layer") or "extraction", "field": r["field"].strip(),
                  "wrong_value": wrong})
        for f in ("source_of_error", "why_tempting"):
            if r.get(f) or f in t:
                t[f] = r.get(f)
        caught = r.get("caught_by_plausibility_check")
        if caught in PLAUSIBILITY:
            t["caught_by_plausibility_check"] = PLAUSIBILITY[caught]
        set_note(t, r.get("note") or "")
        # Keep the original key order for a surviving trap.
        ordered = {k: t[k] for k in old.get(tid, {}) if k in t}
        ordered.update({k: v for k, v in t.items() if k not in ordered})
        out.append(ordered)
    key["must_not_produce"] = out


# ------------------------------------------------------------------- rows

def insert_row(key: dict, after_n: int | None) -> int:
    """Insert a blank row after row `after_n` (None = at the end). Returns its n."""
    rs = rows(key)
    pos = len(rs) if after_n is None else after_n
    order = [r["n"] for r in rs]
    rs.insert(pos, blank_row(0))
    _renumber(key, order[:pos] + [None] + order[pos:])
    return pos + 1


def delete_row(key: dict, n: int) -> None:
    rs = rows(key)
    order = [r["n"] for r in rs]
    rs.pop(order.index(n))
    order.remove(n)
    _renumber(key, order, deleted=n)


def move_row(key: dict, n: int, delta: int) -> int:
    rs = rows(key)
    order = [r["n"] for r in rs]
    i = order.index(n)
    j = max(0, min(len(rs) - 1, i + delta))
    if i == j:
        return n
    rs.insert(j, rs.pop(i))
    order.insert(j, order.pop(i))
    _renumber(key, order)
    return j + 1


def _renumber(key: dict, old_order: list, deleted: int | None = None) -> None:
    """Rows are numbered by printed position. After a structural edit, give
    every row its new n and rewrite every path that named the old one."""
    mapping = {old: i + 1 for i, old in enumerate(old_order) if old is not None}
    for i, r in enumerate(rows(key)):
        # n first, as in every key in the corpus
        items = [(k, v) for k, v in r.items() if k != "n"]
        r.clear()
        r["n"] = i + 1
        r.update(items)

    def remap(path: str) -> str | None:
        idx, f = K.parse_path(path)
        if idx in (None, ""):
            return path
        if deleted is not None and int(idx) == deleted:
            return None
        return f"line_items[{mapping.get(int(idx), int(idx))}].{f}"

    block = absent_block(key)
    for cat in list(block):
        if cat.startswith("_") or not isinstance(block[cat], list):
            continue
        kept = []
        for e in block[cat]:
            if isinstance(e, dict) and "field" in e:
                p = remap(e["field"])
                if p is None:
                    continue
                e["field"] = p
            kept.append(e)
        block[cat] = kept
    for t in key.get("must_not_produce") or []:
        p = remap(t.get("field", ""))
        if p is not None:
            t["field"] = p      # a trap on a deleted row stays, and validate() flags it
    meta = key.get("meta", {})
    if meta.get("_unchecked"):
        meta["_unchecked"] = [q for q in (remap(p) for p in meta["_unchecked"]) if q is not None]
    aa = key.get("also_accept") or {}
    for path in list(aa):
        p = remap(path)
        vals = aa.pop(path)
        if p is not None:
            aa[p] = vals


# ------------------------------------------------------------- validation

_MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]


def raw_supports_iso(raw: str | None, iso: str | None) -> bool | None:
    """Does the printed form state all three of year, month and day that the
    ISO slot claims? None when there is nothing to compare. This is the
    labeller's version of the model's worst mistake: '03-28' is a month, and
    an ISO date written next to it has invented a day."""
    if not raw or not iso or not _ISO.match(iso):
        return None
    y, m, d = (int(x) for x in iso.split("-"))
    nums = [int(t) for t in re.findall(r"\d+", raw)]
    words = [w.lower()[:3] for w in re.findall(r"[A-Za-z]+", raw)]
    for yv in (y, y % 100):
        if yv in nums:
            nums.remove(yv)
            break
    else:
        return False
    if _MONTHS[m - 1] not in words:
        if m in nums:
            nums.remove(m)
        else:
            return False
    return d in nums


def validate(key: dict, pii: P.PiiMap = P.EMPTY) -> tuple[list[str], list[str]]:
    """(errors, warnings). An error blocks publishing; a warning is a question
    worth a second look at the page."""
    errors, warns = [], []
    meta = key.get("meta") or {}
    doc_id = meta.get("document_id") or ""
    if not _SLUG.match(doc_id):
        errors.append(f"document_id {doc_id!r}: use lower-case letters, digits, _ - . only")
    if not meta.get("source_file"):
        errors.append("meta.source_file is empty — which file in private/ is this?")
    elif not (PRIVATE_DIR / meta["source_file"]).exists():
        warns.append(f"meta.source_file {meta['source_file']!r} is not in private/")

    left = unchecked(key)
    if left:
        errors.append(f"{len(left)} value(s) copied from {meta.get('_started_from')} not yet checked against "
                      f"this page: {', '.join(left[:6])}{'…' if len(left) > 6 else ''}")

    rs = rows(key)
    ns = [r.get("n") for r in rs]
    if ns != list(range(1, len(rs) + 1)):
        errors.append(f"rows must be numbered 1..{len(rs)} in page order; found {ns}")
    for r in rs:
        if not r.get("term"):
            errors.append(f"row {r.get('n')}: no term. Every row is a printed line, and the term is what it says.")

    # Dates
    for path in ["document.as_of_date", "patient.date_of_birth"] + \
                [f"line_items[{r['n']}].{f}" for r in rs for f in DATE_PAIRS]:
        v = get(key, path)
        if v is None:
            continue
        if not _ISO.match(str(v)):
            errors.append(f"{path} = {v!r}: an ISO slot takes YYYY-MM-DD. Put the printed form in the _raw slot.")
            continue
        try:
            date.fromisoformat(v)
        except ValueError:
            errors.append(f"{path} = {v!r}: not a real date")
    for r in rs:
        for iso_f, raw_f in DATE_PAIRS.items():
            iso, raw = r.get(iso_f), r.get(raw_f)
            ok = raw_supports_iso(raw, iso)
            if ok is False:
                warns.append(f"row {r['n']}: {iso_f} = {iso} but the page prints {raw!r}. "
                             "Does the printed form really state the year, month and day?")
            if iso and not raw:
                warns.append(f"row {r['n']}: {iso_f} is filled but {raw_f} is empty — copy the date as printed too.")

    # Absences contradict values
    n_rows = len(rs)
    for cat in K.ABSENT_CATEGORIES:
        for e in absent_block(key).get(cat) or []:
            if not isinstance(e, dict):
                continue
            path = e.get("field", "")
            for p in K.expand_path(path, n_rows):
                if (p in DOC_PATHS or K.parse_path(p)[0] not in (None,)) and get(key, p) is not None:
                    errors.append(f"{p} is marked {cat} but has the value {get(key, p)!r}")

    # also_accept
    for path, vals in (K.strip_annotations(key.get("also_accept")) or {}).items():
        e = get(key, path) if _is_concrete(path) else None
        if not _is_concrete(path):
            errors.append(f"also_accept names {path!r}, which is not one slot")
        elif e is None:
            errors.append(f"also_accept for {path}: the key's value is null. also_accept is another printed form of a value, never of nothing.")
        elif e in vals:
            warns.append(f"also_accept for {path} repeats the key's own value")

    # Traps
    ids = [t.get("id") for t in key.get("must_not_produce") or []]
    if len(ids) != len(set(ids)):
        errors.append(f"trap ids repeat: {ids}")
    for t in key.get("must_not_produce") or []:
        f, tid = t.get("field", ""), t.get("id")
        idx, name = K.parse_path(f)
        if f != "any date field" and t.get("layer", "extraction") == "extraction":
            if idx not in (None, "") and int(idx) > n_rows:
                errors.append(f"trap {tid} points at {f}, but the page has {n_rows} rows")
            elif idx is None and f not in DOC_PATHS:
                warns.append(f"trap {tid}: {f!r} is outside the canonical shape, so it cannot be scored")
        if t.get("wrong_value") in (None, ""):
            warns.append(f"trap {tid}: no wrong_value")

    # The key must score perfectly against itself (the self-check, per key).
    ds = S.score_document(key, K.strip_annotations(key["expected"]), doc_id)
    for f in ds.fields:
        if f.outcome not in ("correct", "unscored"):
            errors.append(f"self-score: {f.path} {f.outcome}")
    for a in ds.absent_violations:
        errors.append(f"self-score: {a.path} is marked {a.outcome} but the key gives it a value")
    for t in ds.traps:
        if t.outcome == "hit":
            errors.append(f"trap {t.id} predicts {t.wrong_value!r} for {t.field} — which is the key's own value. "
                          "A trap names a WRONG answer; check the row number.")

    # PII leak: a real value from the map, sitting in a file that is committed.
    # In a compared block it is an error — the key would expect the real name.
    # In a note it is a warning: prose about the corpus names things on purpose
    # sometimes, and that is the author's call. meta.source_file is exempt; it
    # has to match the file in private/.
    compared = json.dumps({b: K.strip_annotations(key.get(b)) for b in K.COMPARED_BLOCKS}, ensure_ascii=False)
    rest = copy.deepcopy(key)
    rest.get("meta", {}).pop("source_file", None)
    rest_text = dumps(rest)
    for real, _ in getattr(pii, "_pairs", []):
        if len(real) < 3:
            continue
        if real in compared:
            errors.append(f"a real value from private/pii_map.json is in a compared block: {real[:3]}… — "
                          "the key must hold its pseudonym")
        elif real in rest_text:
            warns.append(f"a real value from private/pii_map.json appears in a note: {real[:3]}… — "
                         "fine if intended; this file is committed")
    return errors, warns


def self_score_line(key: dict) -> str:
    ds = S.score_document(key, K.strip_annotations(key["expected"]), key["meta"]["document_id"])
    return ds.summary_line()


# -------------------------------------------------------------- reconcile

def adopt_model_value(key: dict, path: str, value, reason: str, run: str) -> str | None:
    """The key was wrong and the model was right. Returns a refusal message,
    or None. The change is recorded in annotations.relabelled, because a key
    corrected after seeing the model is no longer blind on that slot, and the
    next reader should know which slots those are."""
    if not _is_concrete(path):
        return f"{path} is not a slot in the key"
    idx, _ = K.parse_path(path)
    if idx is not None and row_by_n(key, int(idx)) is None:
        return f"the key has no row {idx}. Add the row on the Label screen, looking at the page."
    cat, entry = absence_of(key, path)
    for c in K.ABSENT_CATEGORIES:
        for e in absent_block(key).get(c) or []:
            if isinstance(e, dict) and idx is not None and e.get("field") == f"line_items[].{K.parse_path(path)[1]}" and value is not None:
                return (f"every row's {K.parse_path(path)[1]} is marked {c}. That rule is wrong if this row has a value — "
                        "change it on the Label screen, looking at the page.")
    was = get(key, path)
    if cat is not None:
        absent_block(key)[cat].remove(entry)
    set_value(key, path, value)
    _record(key, {"field": path, "was": was, "now": K._clean(value),
                  "was_absent": cat, "reason": reason, "run": run})
    return None


def add_also_accept(key: dict, path: str, value, reason: str, run: str) -> str | None:
    if get(key, path) is None:
        return "the key's value is null — also_accept is only for another printed form of a value"
    aa = key.setdefault("also_accept", {})
    vals = aa.setdefault(path, [])
    v = K._clean(value)
    if v not in vals:
        vals.append(v)
    _record(key, {"field": path, "also_accept": v, "reason": reason, "run": run})
    return None


def _record(key: dict, entry: dict) -> None:
    entry["on"] = date.today().isoformat()
    ann = key.setdefault("annotations", {})
    if not isinstance(ann, dict):
        key["annotations"] = ann = {"_previous": ann}
    ann.setdefault("relabelled", []).append(entry)
