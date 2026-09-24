"""Call the model. One document in, one raw response out.

The response is stored exactly as returned, next to the parsed JSON, so a run
can be re-scored later without re-spending the call — and so the `extraction`
table's raw_response column holds what the model actually said, not what we
made of it.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path

from .keys import CorpusDoc

HARNESS_DIR = Path(__file__).resolve().parent.parent      # extraction/harness/
RUNS_DIR = HARNESS_DIR.parent / "runs"                      # extraction/runs/ (gitignored)

MEDIA_TYPES = {
    ".pdf": "application/pdf",
    ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
    ".png": "image/png",
}


def prompt_version(prompt_path: Path) -> str:
    """'p1-3fa9c2e1': the file's own name plus a content hash, so an edited
    prompt can never masquerade as the old one in the extraction table."""
    digest = hashlib.sha256(prompt_path.read_bytes()).hexdigest()[:8]
    stem = prompt_path.stem.replace("prompt_", "p")
    return f"{stem}-{digest}"


def new_run_dir() -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
    d = RUNS_DIR / stamp
    d.mkdir(parents=True, exist_ok=False)
    return d


def content_block(path: Path) -> tuple[dict, dict | None]:
    """The block sent to the API, and what was done to get it there. A photo
    goes through prep.prepare_image first: turned upright, EXIF and GPS
    stripped, downscaled. A PDF goes as it is."""
    media = MEDIA_TYPES.get(path.suffix.lower())
    if media is None:
        raise ValueError(f"{path.name}: unsupported type {path.suffix!r}. "
                         "HEIC needs converting to JPEG first (the schema allows it; the API does not).")
    if media == "application/pdf":
        raw, prep_notes = path.read_bytes(), None
    else:
        from .prep import prepare_image
        prepared = prepare_image(path)
        raw, media, prep_notes = prepared.data, prepared.media_type, prepared.notes
    data = base64.standard_b64encode(raw).decode("ascii")
    kind = "document" if media == "application/pdf" else "image"
    return {"type": kind, "source": {"type": "base64", "media_type": media, "data": data}}, prep_notes


def parse_json(text: str) -> tuple[dict | None, str | None]:
    """The prompt asks for bare JSON. Tolerate a code fence or leading prose,
    but record that it happened — a model that cannot follow the output
    instruction is itself a finding."""
    s = text.strip()
    if s.startswith("```"):
        s = s.strip("`")
        if s.startswith("json"):
            s = s[4:]
    start, end = s.find("{"), s.rfind("}")
    if start == -1 or end == -1:
        return None, "no JSON object in response"
    try:
        return json.loads(s[start:end + 1]), None
    except json.JSONDecodeError as e:
        return None, f"JSON parse failed: {e}"


def extract_one(doc: CorpusDoc, prompt_path: Path, model: str, run_dir: Path, max_tokens: int = 8000) -> Path:
    """Send one document; write <run_dir>/<document_id>.json; return its path."""
    import anthropic   # imported here so `score` and `selfcheck` work without the SDK installed

    client = anthropic.Anthropic()
    system = prompt_path.read_text()
    pv = prompt_version(prompt_path)
    block, prep_notes = content_block(doc.file_path)

    resp = client.messages.create(
        model=model,
        max_tokens=max_tokens,
        # No temperature. The SDK removed sampling parameters from the message
        # methods in 1.0, and current models do not accept them. Reproducibility
        # here does not come from pinning a sampler anyway — it comes from
        # storing raw_response unmodified alongside model_version and
        # prompt_version, so any run can be re-read and re-scored as it was.
        system=system,
        messages=[{
            "role": "user",
            "content": [
                block,
                {"type": "text", "text": "Transcribe this document into the JSON shape. Return the JSON object only."},
            ],
        }],
    )
    text = "".join(b.text for b in resp.content if getattr(b, "type", "") == "text")
    parsed, err = parse_json(text)

    record = {
        "document_id": doc.document_id,
        "source_file": doc.file_path.name,
        "sha256": hashlib.sha256(doc.file_path.read_bytes()).hexdigest(),
        "byte_size": doc.file_path.stat().st_size,
        "mime_type": MEDIA_TYPES[doc.file_path.suffix.lower()],
        "prepared": prep_notes,            # None for a PDF; what prep.py did to a photo
        "model_requested": model,
        "model_name": resp.model,          # what actually answered
        "prompt_version": pv,
        "stop_reason": resp.stop_reason,
        "usage": {"input_tokens": resp.usage.input_tokens, "output_tokens": resp.usage.output_tokens},
        "extracted_at": datetime.now(timezone.utc).isoformat(),
        "raw_response": text,              # unmodified
        "parse_error": err,
        "output": parsed,
    }
    out = run_dir / f"{doc.document_id}.json"
    out.write_text(json.dumps(record, indent=2, ensure_ascii=False) + "\n")
    return out


def default_model() -> str:
    m = os.environ.get("EXTRACTION_MODEL")
    if not m:
        raise SystemExit("EXTRACTION_MODEL is not set. Put it in .env — see .env.example.")
    return m
