"""A copy of a dog's paperwork, as it arrives at the counter.

A tablet photo is the usual case, and it arrives with three things the page
itself does not need — the same three the extraction harness deals with
(extraction/harness/harness/prep.py), handled the same way so the model could
read these copies later exactly as a person sees them:

  rotation   the camera stores the pixels sideways and records the turn in
             EXIF. The copy is turned upright before it is saved.
  EXIF       make, model, time — and GPS: the shop's location. None of it is
             on the page, so none of it is kept.
  size       a 12-megapixel photo is 3-6 MB. Downscaled to 2576 px on the long
             edge (still sharper than a page needs), it is a few hundred KB.

An iPhone photo may be HEIC; it is saved as JPEG like the rest. A PDF (an
emailed certificate) is kept as it came: it has no camera rotation, and its
text is worth more than anything resizing would save.

Saved under private/counter/<year-month>/. The same file received twice for
the same owner is one document (the database checks its fingerprint), so it
is written once. private/ is never committed (.gitignore).
"""
from __future__ import annotations

import hashlib
import io
import os
import uuid
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
MAX_LONG_EDGE = 2576
JPEG_QUALITY = 88
MAX_UPLOAD_BYTES = 30 * 1024 * 1024


class NotPaperwork(ValueError):
    """A file that is not a photo or a PDF, or is too big to be one."""


def private_dir() -> Path:
    # The tests point this somewhere temporary, so they never write into private/.
    return Path(os.environ.get("PRIVATE_DIR", REPO / "private"))


@dataclass
class Copy:
    data: bytes
    mime_type: str
    sha256: str
    exif_stripped: bool
    original_bytes: int
    original_size: tuple[int, int] | None = None     # pixels, for a photo
    saved_size: tuple[int, int] | None = None
    # Two owners can hand in the same file; each gets a copy of its own.
    _name: str = field(default_factory=lambda: uuid.uuid4().hex[:12])

    @property
    def extension(self) -> str:
        return ".pdf" if self.mime_type == "application/pdf" else ".jpg"

    @property
    def object_key(self) -> str:
        """Where it is saved, relative to the repo, as the document table records it."""
        return f"private/counter/{date.today():%Y-%m}/{self.sha256[:12]}-{self._name}{self.extension}"


def prepare(raw: bytes) -> Copy:
    if not raw:
        raise NotPaperwork("The file is empty.")
    if len(raw) > MAX_UPLOAD_BYTES:
        raise NotPaperwork(f"The file is {len(raw) // (1024 * 1024)} MB; the most a copy can be is "
                           f"{MAX_UPLOAD_BYTES // (1024 * 1024)} MB.")
    if raw[:5] == b"%PDF-":
        return Copy(raw, "application/pdf", hashlib.sha256(raw).hexdigest(), False, len(raw))
    return _photo(raw)


def _photo(raw: bytes) -> Copy:
    from PIL import Image, ImageOps, UnidentifiedImageError
    from pillow_heif import register_heif_opener
    register_heif_opener()

    try:
        im = Image.open(io.BytesIO(raw))
        im.load()
    except (UnidentifiedImageError, OSError):
        raise NotPaperwork("That file isn't a photo or a PDF. Take a photo of the paperwork, "
                           "or pick the PDF the owner emailed.") from None
    original = im.size
    upright = ImageOps.exif_transpose(im)
    if upright.mode not in ("RGB", "L"):
        upright = upright.convert("RGB")
    w, h = upright.size
    scale = min(1.0, MAX_LONG_EDGE / max(w, h))
    if scale < 1.0:
        upright = upright.resize((round(w * scale), round(h * scale)), Image.LANCZOS)
    buf = io.BytesIO()
    # Saving without exif= is what strips it: Pillow writes only what it is given.
    upright.save(buf, format="JPEG", quality=JPEG_QUALITY, optimize=True)
    data = buf.getvalue()
    return Copy(data, "image/jpeg", hashlib.sha256(data).hexdigest(), True, len(raw),
                original, upright.size)


def save(copy: Copy) -> None:
    path = private_dir() / Path(copy.object_key).relative_to("private")
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        path.write_bytes(copy.data)


def path_of(object_key: str) -> Path | None:
    """The file behind a document row, if it is a copy in private/ on this machine."""
    rel = Path(object_key)
    if not rel.parts or rel.parts[0] != "private":
        return None
    root = private_dir().resolve()
    path = (root / Path(*rel.parts[1:])).resolve()
    if root not in path.parents or not path.is_file():
        return None
    return path
