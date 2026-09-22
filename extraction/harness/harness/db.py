"""Load a run into the database, and record how it scored.

What lands, in one transaction:

  document                 one per (owner, sha256) — the per-owner dedupe branch
  extraction               one per run × document, raw_response unmodified
  extraction_field         document-level fields, dotted path, line_item_id NULL
  extraction_line_item     one per printed row
  extraction_field         line-item fields, bare name, line_item_id set
  eval_run                 one per run × ruler version (section 17)
  eval_document_result     one per document, linked to its extraction
  eval_field_result        one per scored slot, values AFTER the PII map
  eval_trap_result         one per must_not_produce entry

Loading is idempotent. The same run loaded twice reuses its extractions
(matched on document, prompt version and the run's own timestamp) and refuses
a second identical evaluation. The same run loaded after a key correction
reuses its extractions and records a NEW evaluation — which is how the effect
of fixing a key becomes a row you can query.

Nothing here writes a vaccination_record. That is Layer 3, and it happens
after a human confirms — see v_extraction_line_item.can_create_record and
v_field_review_priority.

Every non-text parameter carries an explicit cast in the SQL, so the result
does not depend on how the driver types a Python string.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path

from . import keys as K
from . import score as S


@dataclass
class LineItemPlan:
    n: int
    source_region: str | None
    fields: list[tuple[str, str | None]]          # (field_name, extracted_value)


@dataclass
class DocumentPlan:
    document_id: str                              # the corpus id, for reporting
    owner_id: str
    dog_id: str | None
    document: dict                                # columns for `document`
    extraction: dict                              # columns for `extraction`
    fields: list[tuple[str, str | None]] = field(default_factory=list)   # document-level
    line_items: list[LineItemPlan] = field(default_factory=list)
    record: dict = field(default_factory=dict)    # the run file, for scoring

    @property
    def field_count(self) -> int:
        return len(self.fields) + sum(len(li.fields) for li in self.line_items)


def plan_document(rec: dict, doc: K.CorpusDoc, key: dict) -> DocumentPlan:
    meta = key["meta"]
    plan = DocumentPlan(
        document_id=rec["document_id"],
        owner_id=doc.owner_id,
        dog_id=doc.dog_id,
        document=dict(
            object_key=f"private/{rec['source_file']}",
            mime_type=rec["mime_type"],
            byte_size=rec["byte_size"],
            sha256=rec["sha256"],
            doc_class=meta["doc_class"],
            source=meta["source"],
            page_count=meta.get("page_count"),
        ),
        extraction=dict(
            model_name=rec["model_requested"],
            model_version=rec["model_name"],        # what actually answered
            prompt_version=rec["prompt_version"],
            raw_response=json.dumps({"text": rec["raw_response"],
                                     "stop_reason": rec.get("stop_reason"),
                                     "usage": rec.get("usage")}),
            status="rejected" if rec.get("output") is None else "needs_review",
            extracted_at=rec["extracted_at"],
        ),
        record=rec,
    )
    if rec.get("output") is None:
        return plan

    out = K.strip_annotations(rec["output"])
    for section, fields in K.DOCUMENT_LEVEL.items():
        block = out.get(section) or {}
        for f in fields:
            plan.fields.append((f"{section}.{f}", _text(block.get(f))))
    for i, item in enumerate(out.get("line_items") or []):
        n = item.get("n") or (i + 1)
        li = LineItemPlan(n=int(n), source_region=_text(item.get("source_region")), fields=[])
        for f in K.LINE_ITEM_FIELDS:
            li.fields.append((f, _text(item.get(f))))
        plan.line_items.append(li)
    return plan


def plan_run(run_dir: Path, corpus: dict[str, K.CorpusDoc], keys: dict[str, dict]) -> list[DocumentPlan]:
    plans = []
    for rec_path in sorted(run_dir.glob("*.json")):
        if rec_path.name == "score.json":
            continue
        rec = json.loads(rec_path.read_text(encoding="utf-8"))
        plans.append(plan_document(rec, corpus[rec["document_id"]], keys[rec["document_id"]]))
    return plans


def _text(v) -> str | None:
    v = K._clean(v)
    return None if v is None else str(v)


# ---------------------------------------------------------------- execution

def connect():
    import psycopg
    url = os.environ.get("DATABASE_URL")
    if not url:
        raise SystemExit("DATABASE_URL is not set. Put it in .env — see .env.example.")
    return psycopg.connect(url)


def load_run(run_dir: Path, corpus: dict[str, K.CorpusDoc], keys: dict[str, dict],
             scores: dict[str, S.DocScore], ruler: str, pii_entries: int) -> list[str]:
    """Returns one line per document, and one for the evaluation."""
    plans = plan_run(run_dir, corpus, keys)
    lines = []
    with connect() as conn, conn.cursor() as cur:
        cur.execute("SET search_path = groom, public")
        extraction_ids = {}
        for plan in plans:
            line, xid = execute_plan(cur, plan)
            extraction_ids[plan.document_id] = xid
            lines.append(line)
        lines.append(record_eval(cur, run_dir.name, plans, scores, extraction_ids, ruler, pii_entries))
        conn.commit()
    return lines


def execute_plan(cur, plan: DocumentPlan) -> tuple[str, str]:
    """Execute one plan on a DB-API cursor with %s placeholders. Returns a
    report line and the extraction id."""
    d = plan.document
    cur.execute("SELECT id FROM document WHERE owner_id = %s::uuid AND sha256 = %s",
                (plan.owner_id, d["sha256"]))
    row = cur.fetchone()
    if row:
        document_id, doc_state = str(row[0]), "existing"
    else:
        cur.execute(
            """INSERT INTO document (owner_id, object_key, mime_type, byte_size, sha256,
                                     doc_class, source, page_count)
               VALUES (%s::uuid, %s, %s, %s, %s, %s::document_class, %s::document_source, %s)
               RETURNING id""",
            (plan.owner_id, d["object_key"], d["mime_type"], d["byte_size"], d["sha256"],
             d["doc_class"], d["source"], d["page_count"]))
        document_id, doc_state = str(cur.fetchone()[0]), "new"
        if plan.dog_id:
            cur.execute("INSERT INTO document_dog (document_id, dog_id) VALUES (%s::uuid, %s::uuid)",
                        (document_id, plan.dog_id))

    e = plan.extraction
    # The run's own timestamp identifies the extraction: loading the same run
    # file twice must not create a second copy of the same model output.
    cur.execute(
        """SELECT id FROM extraction
            WHERE document_id = %s::uuid AND prompt_version = %s AND extracted_at = %s::timestamptz""",
        (document_id, e["prompt_version"], e["extracted_at"]))
    row = cur.fetchone()
    if row:
        return (f"{plan.document_id:<38} document {doc_state:<8} extraction existing     (already loaded)",
                str(row[0]))

    cur.execute(
        """INSERT INTO extraction (document_id, model_name, model_version, prompt_version,
                                   raw_response, status, extracted_at)
           VALUES (%s::uuid, %s, %s, %s, %s::jsonb, %s::extraction_status, %s::timestamptz)
           RETURNING id""",
        (document_id, e["model_name"], e["model_version"], e["prompt_version"],
         e["raw_response"], e["status"], e["extracted_at"]))
    extraction_id = str(cur.fetchone()[0])

    for name, value in plan.fields:
        cur.execute("INSERT INTO extraction_field (extraction_id, field_name, extracted_value) "
                    "VALUES (%s::uuid, %s, %s)",
                    (extraction_id, name, value))
    for li in plan.line_items:
        cur.execute("INSERT INTO extraction_line_item (extraction_id, n, source_region) "
                    "VALUES (%s::uuid, %s, %s) RETURNING id",
                    (extraction_id, li.n, li.source_region))
        li_id = str(cur.fetchone()[0])
        for name, value in li.fields:
            cur.execute(
                "INSERT INTO extraction_field (extraction_id, line_item_id, field_name, extracted_value) "
                "VALUES (%s::uuid, %s::uuid, %s, %s)",
                (extraction_id, li_id, name, value))

    return (f"{plan.document_id:<38} document {doc_state:<8} extraction {e['status']:<12} "
            f"line items {len(plan.line_items):>2}  fields {plan.field_count:>3}",
            extraction_id)


def record_eval(cur, run_label: str, plans: list[DocumentPlan], scores: dict[str, S.DocScore],
                extraction_ids: dict[str, str], ruler: str, pii_entries: int) -> str:
    models = {p.extraction["model_name"] for p in plans}
    versions = {p.extraction["model_version"] for p in plans}
    prompts = {p.extraction["prompt_version"] for p in plans}
    if len(models) != 1 or len(prompts) != 1 or len(versions) != 1:
        raise SystemExit(f"run {run_label} mixes models or prompts ({models} {versions} {prompts}); "
                         "an evaluation scores exactly one of each.")

    cur.execute(
        """INSERT INTO eval_run (run_label, model_name, model_version, prompt_version,
                                 ruler_version, contract_version, pii_map_entries)
           VALUES (%s, %s, %s, %s, %s, %s, %s)
           ON CONFLICT (run_label, ruler_version) DO NOTHING
           RETURNING id""",
        (run_label, models.pop(), versions.pop(), prompts.pop(), ruler, K.CONTRACT_VERSION, pii_entries))
    row = cur.fetchone()
    if row is None:
        return (f"{'evaluation':<38} already recorded for {run_label} under ruler {ruler} "
                "— change a key or the PII map to record a new one")
    eval_run_id = str(row[0])

    n_fields = n_traps = 0
    for plan in plans:
        ds = scores[plan.document_id]
        cur.execute(
            """INSERT INTO eval_document_result (eval_run_id, extraction_id, corpus_document_id,
                                                 expected_items, got_items, parse_error)
               VALUES (%s::uuid, %s::uuid, %s, %s, %s, %s) RETURNING id""",
            (eval_run_id, extraction_ids[plan.document_id], plan.document_id,
             ds.expected_items, ds.got_items, ds.parse_error))
        edr_id = str(cur.fetchone()[0])
        for f in ds.fields:
            cur.execute(
                """INSERT INTO eval_field_result (eval_document_result_id, field_path, outcome,
                                                  expected_value, got_value, pii_mapped, accepted_alternate)
                   VALUES (%s::uuid, %s, %s::eval_field_outcome, %s, %s, %s, %s)""",
                (edr_id, f.path, f.outcome, _text(f.expected), _text(f.got), f.pii_mapped, f.accepted_alternate))
            n_fields += 1
        for t in ds.traps:
            cur.execute(
                """INSERT INTO eval_trap_result (eval_document_result_id, trap_id, field_path, wrong_value,
                                                 outcome, got, note)
                   VALUES (%s::uuid, %s, %s, %s, %s::eval_trap_outcome, %s, %s)""",
                (edr_id, t.id, t.field, _text(t.wrong_value), t.outcome, t.got, t.note or None))
            n_traps += 1

    return (f"{'evaluation':<38} recorded under ruler {ruler}: "
            f"{len(plans)} documents, {n_fields} field results, {n_traps} trap results")
