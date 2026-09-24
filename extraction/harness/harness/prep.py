"""Prepare a photographed page before anyone looks at it — model or human.

A phone photo arrives with three problems the page itself does not have:

  rotation   the camera stores the pixels sideways and records the turn as an
             EXIF flag. The API reads pixels, not flags, so an unprepared
             photo is read on its side.
  EXIF       make, model, timestamp — and GPS. A photo taken at the counter
             carries the shop's coordinates; one taken at home carries the
             owner's. None of it is on the page, and none of it leaves here.
  size       a 4000 x 3000 phone JPEG is over the API's per-image limit once
             base64-encoded. Sonnet 5 reads up to 2576 px on the long edge,
             so downscaling to that loses nothing the model would have used.

The labelling tool renders pages through the same function, so the human
labels exactly the image the model is sent. PDFs pass through untouched: they
carry no camera orientation, and a text layer is worth more than any resize.
"""
from __future__ import annotations

import hashlib
import io
from dataclasses import dataclass, field
from pathlib import Path

MAX_LONG_EDGE = 2576
JPEG_QUALITY = 90
_GPS_IFD = 0x8825
_ORIENTATION = 0x0112


@dataclass
class Prepared:
    data: bytes
    media_type: str
    notes: dict = field(default_factory=dict)   # what was done, for the run record


def prepare_image(path: Path, max_long_edge: int = MAX_LONG_EDGE) -> Prepared:
    from PIL import Image, ImageOps   # imported here so `score` and `selfcheck` need no Pillow

    with Image.open(path) as im:
        exif = im.getexif()
        notes = {
            "original_size": list(im.size),
            "exif_orientation": exif.get(_ORIENTATION),
            "had_gps": _GPS_IFD in exif,
            "had_exif": len(exif) > 0,
        }
        if not notes["had_exif"] and max(im.size) <= max_long_edge:
            # Nothing to fix: send the original bytes, so a clean screenshot
            # is sent exactly as it was in runs made before this step existed.
            data = path.read_bytes()
            notes.update({"sent_size": list(im.size), "sent_bytes": len(data),
                          "sent_sha256": hashlib.sha256(data).hexdigest(),
                          "exif_stripped": False, "unchanged": True, "max_long_edge": max_long_edge})
            return Prepared(data, Image.MIME.get(im.format, "image/jpeg"), notes)
        upright = ImageOps.exif_transpose(im)
        if upright.mode not in ("RGB", "L"):
            upright = upright.convert("RGB")
        w, h = upright.size
        scale = min(1.0, max_long_edge / max(w, h))
        if scale < 1.0:
            upright = upright.resize((round(w * scale), round(h * scale)), Image.LANCZOS)
        buf = io.BytesIO()
        # Re-encoding without passing exif= is what strips it: Pillow writes
        # only what it is given. PNGs are re-encoded too, which drops text chunks.
        if path.suffix.lower() == ".png":
            upright.save(buf, format="PNG", optimize=True)
            media = "image/png"
        else:
            upright.save(buf, format="JPEG", quality=JPEG_QUALITY, optimize=True)
            media = "image/jpeg"

    data = buf.getvalue()
    notes.update({
        "sent_size": list(upright.size),
        "sent_bytes": len(data),
        "sent_sha256": hashlib.sha256(data).hexdigest(),
        "exif_stripped": True,
        "max_long_edge": max_long_edge,
    })
    return Prepared(data, media, notes)
