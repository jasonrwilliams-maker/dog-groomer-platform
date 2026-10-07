"""A copy of a dog's paperwork, as it arrives at the counter.

Paperwork rarely arrives as one clean page. A certificate runs to two pages,
the owner's phone needs scrolling, or there is a PDF and a photo of a sticker.
So one handover can be several files, and it is kept as ONE copy with pages:
every photo is a page, and every page of a PDF is a page.

A tablet photo arrives with three things the page itself does not need — the
same three the extraction harness deals with (extraction/harness/harness/prep.py),
handled the same way so the model could read these copies later exactly as a
person sees them:

  rotation   the camera stores the pixels sideways and records the turn in
             EXIF. The page is turned upright before it is saved.
  EXIF       make, model, time — and GPS: the shop's location. None of it is
             on the page, so none of it is kept.
  size       a 12-megapixel photo is 3-6 MB. Downscaled to 2576 px on the long
             edge (still sharper than a page needs), it is a few hundred KB.

An iPhone photo may be HEIC; it is saved as JPEG like the rest. A PDF's pages
are drawn as images at the same size, so the screen can show them beside the
form on any tablet.

What is saved, under private/counter/<year-month>/:

  one photo     the photo (it is its own page)
  one PDF       the PDF as it came (its text is worth keeping), and its pages
  several       one PDF made of all the pages, and the pages

private/ is never committed (.gitignore).
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
MAX_FILES = 12
MAX_PAGES = 24


class NotPaperwork(ValueError):
    """A file that is not a photo or a PDF, or is too big to be one."""


def private_dir() -> Path:
    # The tests point this somewhere temporary, so they never write into private/.
    return Path(os.environ.get("PRIVATE_DIR", REPO / "private"))


@dataclass
class Copy:
    data: bytes                       # the copy itself: a photo or a PDF
    mime_type: str
    pages: list[bytes]                # one JPEG per page, in order
    original_bytes: int
    exif_stripped: bool
    resized: bool                     # was any photo made smaller
    sha256: str = ""
    # Two owners can hand in the same file; each gets a copy of its own.
    _name: str = field(default_factory=lambda: uuid.uuid4().hex[:12])

    def __post_init__(self):
        self.sha256 = hashlib.sha256(self.data).hexdigest()

    @property
    def _stem(self) -> str:
        return f"private/counter/{date.today():%Y-%m}/{self.sha256[:12]}-{self._name}"

    @property
    def object_key(self) -> str:
        """Where the copy is saved, relative to the repo, as the document table records it."""
        return self._stem + (".pdf" if self.mime_type == "application/pdf" else ".jpg")

    @property
    def page_keys(self) -> list[str]:
        # A single photo is its own page: no second file.
        if self.mime_type == "image/jpeg":
            return [self.object_key]
        return [f"{self._stem}-p{n}.jpg" for n in range(1, len(self.pages) + 1)]


def prepare(files: list[bytes]) -> Copy:
    if not files:
        raise NotPaperwork("No file was sent.")
    if len(files) > MAX_FILES:
        raise NotPaperwork(f"That's {len(files)} files; the most one copy can be is {MAX_FILES}.")
    pages: list[bytes] = []
    resized = False
    for raw in files:
        if not raw:
            raise NotPaperwork("One of the files is empty.")
        if len(raw) > MAX_UPLOAD_BYTES:
            raise NotPaperwork(f"One file is {len(raw) // (1024 * 1024)} MB; the most a file can be is "
                               f"{MAX_UPLOAD_BYTES // (1024 * 1024)} MB.")
        if _is_pdf(raw):
            pages += _pdf_pages(raw)
        else:
            page, smaller = _photo(raw)
            pages.append(page)
            resized |= smaller
        if len(pages) > MAX_PAGES:
            raise NotPaperwork(f"That's more than {MAX_PAGES} pages for one copy.")

    total = sum(len(f) for f in files)
    if len(files) == 1 and _is_pdf(files[0]):
        return Copy(files[0], "application/pdf", pages, total, False, False)
    if len(files) == 1:
        return Copy(pages[0], "image/jpeg", pages, total, True, resized)
    return Copy(_as_pdf(pages), "application/pdf", pages, total, True, resized)


def _is_pdf(raw: bytes) -> bool:
    return raw[:5] == b"%PDF-"


def _photo(raw: bytes) -> tuple[bytes, bool]:
    from PIL import Image, ImageOps, UnidentifiedImageError
    from pillow_heif import register_heif_opener
    register_heif_opener()

    try:
        im = Image.open(io.BytesIO(raw))
        im.load()
    except (UnidentifiedImageError, OSError):
        raise NotPaperwork("One of the files isn't a photo or a PDF. Take a photo of the paperwork, "
                           "or pick the PDF the owner emailed.") from None
    upright = ImageOps.exif_transpose(im)
    return _jpeg(upright)


def _pdf_pages(raw: bytes) -> list[bytes]:
    import pypdfium2 as pdfium
    try:
        pdf = pdfium.PdfDocument(raw)
    except pdfium.PdfiumError:
        raise NotPaperwork("That PDF can't be opened. It may be damaged or password-protected.") from None
    if len(pdf) > MAX_PAGES:
        raise NotPaperwork(f"That PDF has {len(pdf)} pages; the most one copy can be is {MAX_PAGES}.")
    pages = []
    for page in pdf:
        w, h = page.get_size()                        # in points
        pages.append(_jpeg(page.render(scale=MAX_LONG_EDGE / max(w, h)).to_pil())[0])
    return pages


def _jpeg(im) -> tuple[bytes, bool]:
    from PIL import Image
    if im.mode not in ("RGB", "L"):
        im = im.convert("RGB")
    w, h = im.size
    scale = min(1.0, MAX_LONG_EDGE / max(w, h))
    if scale < 1.0:
        im = im.resize((round(w * scale), round(h * scale)), Image.LANCZOS)
    buf = io.BytesIO()
    # Saving without exif= is what strips it: Pillow writes only what it is given.
    im.save(buf, format="JPEG", quality=JPEG_QUALITY, optimize=True)
    return buf.getvalue(), scale < 1.0


def _as_pdf(pages: list[bytes]) -> bytes:
    from PIL import Image
    images = [Image.open(io.BytesIO(p)) for p in pages]
    buf = io.BytesIO()
    images[0].save(buf, format="PDF", save_all=True, append_images=images[1:], resolution=200)
    return buf.getvalue()


def _disk_path(key: str) -> Path:
    return private_dir() / Path(key).relative_to("private")


def save(copy: Copy) -> None:
    for key, data in [(copy.object_key, copy.data), *zip(copy.page_keys, copy.pages)]:
        path = _disk_path(key)
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists():
            path.write_bytes(data)


def discard(keys: list[str]) -> None:
    """Delete a removed copy's files. Only ever files under private/counter/."""
    for key in keys:
        if key.startswith("private/counter/") and (path := path_of(key)) is not None:
            path.unlink(missing_ok=True)


def path_of(object_key: str) -> Path | None:
    """The file behind a document or page row, if it is in private/ on this machine."""
    rel = Path(object_key)
    if not rel.parts or rel.parts[0] != "private":
        return None
    root = private_dir().resolve()
    path = (root / Path(*rel.parts[1:])).resolve()
    if root not in path.parents or not path.is_file():
        return None
    return path
