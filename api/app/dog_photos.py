"""A photo of the dog, for its profile.

Taken on the shop tablet, picked from the phone, or snapped on the desktop
webcam, it is handled as the counter handles paperwork photos
(app/paperwork.py): turned upright, its camera details and GPS stripped
(the shop's location, or the owner's), and saved as JPEG. It is kept in the
three sizes the schema plans for:

  original   the photo, no longer than 2576 px on its long edge
  display    1200 px, for the dog's card and the booking form
  thumb      a 256 px square from the middle, for lists

under private/dogs/<year-month>/, which is never committed (.gitignore).
"""
from __future__ import annotations

import io
import uuid
from dataclasses import dataclass
from datetime import date

from . import paperwork

SIZES = {"original": paperwork.MAX_LONG_EDGE, "display": 1200, "thumb": 256}


class NotAPhoto(ValueError):
    """A file that is not a photo, or is too big to be one."""


@dataclass
class Rendition:
    rendition: str
    object_key: str
    data: bytes
    width: int
    height: int


def prepare(raw: bytes) -> list[Rendition]:
    from PIL import Image, ImageOps, UnidentifiedImageError
    from pillow_heif import register_heif_opener
    register_heif_opener()

    if not raw:
        raise NotAPhoto("No photo was sent.")
    if len(raw) > paperwork.MAX_UPLOAD_BYTES:
        raise NotAPhoto(f"That photo is {len(raw) // (1024 * 1024)} MB; the most a photo can be is "
                        f"{paperwork.MAX_UPLOAD_BYTES // (1024 * 1024)} MB.")
    try:
        im = Image.open(io.BytesIO(raw))
        im.load()
    except (UnidentifiedImageError, OSError):
        raise NotAPhoto("That file isn't a photo. Take one with the camera, or pick a photo.") from None
    im = ImageOps.exif_transpose(im)
    if im.mode not in ("RGB", "L"):
        im = im.convert("RGB")

    stem = f"private/dogs/{date.today():%Y-%m}/{uuid.uuid4().hex}"
    out = []
    for name, edge in SIZES.items():
        if name == "thumb":
            sized = ImageOps.fit(im, (edge, edge), Image.LANCZOS)
        else:
            sized = im.copy()
            sized.thumbnail((edge, edge), Image.LANCZOS)
        buf = io.BytesIO()
        # Saving without exif= is what strips it.
        sized.save(buf, format="JPEG", quality=paperwork.JPEG_QUALITY, optimize=True)
        out.append(Rendition(name, f"{stem}-{name}.jpg", buf.getvalue(), *sized.size))
    return out


def save(renditions: list[Rendition]) -> None:
    for r in renditions:
        path = paperwork._disk_path(r.object_key)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(r.data)


def discard(keys: list[str]) -> None:
    """Delete a replaced or removed photo's files. Only ever files under private/dogs/."""
    for key in keys:
        if key.startswith("private/dogs/") and (path := paperwork.path_of(key)) is not None:
            path.unlink(missing_ok=True)
