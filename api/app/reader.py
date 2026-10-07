"""The AI reading a copy at the counter.

The same reading the extraction harness does for the labelled corpus
(extraction/harness), on one copy, on request: the harness's prompt, model and
field lists, so a counter reading and a corpus run are the same measurement and
the scores can be compared. What differs is only where the document comes from
and that nobody has written an answer key for it: the person checking it at the
counter is the key (sql/27_ai_suggestions.sql).

A PDF goes as a PDF (a text layer reads perfectly; see the README's results).
A copy made from photos goes as its pages, which are already upright, stripped
and downsized (app/paperwork.py does what the harness's prep.py does).

The pages go to Anthropic's API. Configuration is the harness's: ANTHROPIC_API_KEY
and EXTRACTION_MODEL in .env, and EXTRACTION_PROMPT to choose a prompt file.
"""
from __future__ import annotations

import base64
import os
import sys
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HARNESS = REPO / "extraction" / "harness"
if str(HARNESS) not in sys.path:
    sys.path.insert(0, str(HARNESS))

from harness import keys as K                                         # noqa: E402
from harness.extract import MAX_TOKENS, parse_json, prompt_version    # noqa: E402

INSTRUCTION = "Transcribe this document into the JSON shape. Return the JSON object only."


class NotSetUp(RuntimeError):
    """The AI has no model or key configured on this computer."""


class ReadFailed(RuntimeError):
    """The model was reached but gave nothing usable."""


@dataclass
class Reading:
    model_requested: str
    model_version: str
    prompt_version: str
    raw_response: dict            # stored unmodified, as the harness stores it
    output: dict | None           # the parsed JSON, or None if it did not parse
    parse_error: str | None


def prompt_path() -> Path:
    return HARNESS / os.environ.get("EXTRACTION_PROMPT", "prompt_v2.md")


def model() -> str:
    m = os.environ.get("EXTRACTION_MODEL")
    if not m:
        raise NotSetUp("The AI isn't set up on this computer: EXTRACTION_MODEL is missing from .env.")
    return m


def blocks(mime_type: str, copy_file: Path | None, page_files: list[Path]) -> list[dict]:
    """What is sent: the PDF as a document, or each page as an image."""
    def b64(path: Path) -> str:
        return base64.standard_b64encode(path.read_bytes()).decode("ascii")
    if mime_type == "application/pdf" and copy_file is not None:
        return [{"type": "document", "source": {"type": "base64", "media_type": "application/pdf",
                                                "data": b64(copy_file)}}]
    return [{"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": b64(p)}}
            for p in page_files]


def read(content: list[dict]) -> Reading:
    """Send the copy to the model and return what it said, parsed if it parses."""
    name = model()
    path = prompt_path()
    response = call_model(name, path.read_text(encoding="utf-8"), content)
    text = "".join(b.text for b in response.content if getattr(b, "type", "") == "text")
    if response.stop_reason == "refusal":
        raise ReadFailed("The AI declined to read this copy. Type the dates in yourself.")
    parsed, err = parse_json(text)
    if response.stop_reason == "max_tokens":
        parsed, err = None, f"cut off: the model used all {MAX_TOKENS} output tokens before finishing"
    usage = getattr(response, "usage", None)
    return Reading(
        model_requested=name,
        model_version=response.model,
        prompt_version=prompt_version(path),
        raw_response={"text": text, "stop_reason": response.stop_reason,
                      "usage": {"input_tokens": getattr(usage, "input_tokens", None),
                                "output_tokens": getattr(usage, "output_tokens", None)}},
        output=parsed,
        parse_error=err,
    )


def call_model(name: str, system: str, content: list[dict]):
    """One request, streamed so a long thinking pass cannot hit an HTTP timeout.
    The tests replace this function; nothing else here talks to the network."""
    import anthropic
    client = anthropic.Anthropic(timeout=240.0, max_retries=1)
    try:
        # As the harness sends it: no thinking or sampling settings, so a counter
        # reading and a corpus run of the same model and prompt are comparable.
        with client.messages.stream(
            model=name,
            max_tokens=MAX_TOKENS,
            system=system,
            messages=[{"role": "user", "content": [*content, {"type": "text", "text": INSTRUCTION}]}],
        ) as stream:
            return stream.get_final_message()
    except anthropic.AuthenticationError:
        raise NotSetUp("The AI isn't set up on this computer: the API key in .env was not accepted.") from None
    except anthropic.NotFoundError:
        raise NotSetUp(f"The AI model {name!r} named in .env doesn't exist. Check EXTRACTION_MODEL.") from None
    except anthropic.BadRequestError as e:
        raise ReadFailed(f"The AI couldn't take this copy: {e.message}") from None
    except anthropic.RateLimitError:
        raise ReadFailed("The AI is busy right now. Try again in a minute, or type the dates in.") from None
    except anthropic.APIStatusError as e:
        raise ReadFailed(f"The AI service had a problem ({e.status_code}). Try again, or type the dates in.") from None
    except anthropic.APIConnectionError:
        raise ReadFailed("Couldn't reach the AI service. Check the internet connection, or type the dates in.") from None


def flatten(output: dict) -> tuple[dict[str, str | None], list[dict]]:
    """The model's JSON as the database stores it, with the harness's field lists:
    document-level fields by dotted name, and one entry per line item."""
    out = K.strip_annotations(output)
    doc: dict[str, str | None] = {}
    for section, names in K.DOCUMENT_LEVEL.items():
        block = out.get(section) or {}
        for f in names:
            doc[f"{section}.{f}"] = _text(block.get(f))
    items = []
    for i, item in enumerate(out.get("line_items") or []):
        n = item.get("n") or (i + 1)
        try:
            n = int(n)
        except (TypeError, ValueError):
            n = i + 1
        items.append({"n": n, "source_region": _text(item.get("source_region")),
                      "fields": {f: _text(item.get(f)) for f in K.LINE_ITEM_FIELDS}})
    # Two rows the model numbered alike would collide; number them in order instead.
    if len({it["n"] for it in items}) != len(items):
        for i, it in enumerate(items):
            it["n"] = i + 1
    return doc, items


def _text(v) -> str | None:
    v = K._clean(v)
    return None if v is None else str(v)
