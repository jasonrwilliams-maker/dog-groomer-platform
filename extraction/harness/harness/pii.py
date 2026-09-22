"""The real-to-pseudonym map.

The answer keys are anonymised at labelling time so they can live in version
control. The documents in private/ are not, and cannot be — they are the real
pages. So a model that reads a page correctly emits the real name, and the key
expects the pseudonym. Without this map, every correct read of a name,
address or phone number scores as `wrong`.

The map lives beside the documents in private/pii_map.json, gitignored with
them. It is applied to the MODEL'S OUTPUT, never to the keys, as plain
substring replacement, longest real value first:

    'Mr. Jason Williams'       -> 'Mr. Marcus Webb'
    '410 W Lombard St #511'    -> '88 Chesterfield Row #511'

The second line is the point of substring replacement over whole-value
replacement. The model left the unit on the street line; after mapping it
still fails against address_line1 = '88 Chesterfield Row', which is correct —
where the model put '#511' is a real finding, and the map must not hide it.
It only undoes the substitution, and nothing else.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

from . import keys as K

PII_MAP_FILE = K.EXTRACTION_DIR.parent / "private" / "pii_map.json"


class PiiMap:
    def __init__(self, replacements: dict[str, str], source: Path | None = None):
        bad = [k for k, v in replacements.items() if not k or not isinstance(v, str)]
        if bad:
            raise ValueError(f"pii_map: empty key or non-string value for {bad!r}")
        # Longest first, so 'Mr. Jason Williams' is not pre-empted by 'Jason'.
        self._pairs = sorted(replacements.items(), key=lambda kv: len(kv[0]), reverse=True)
        self.source = source

    def __len__(self) -> int:
        return len(self._pairs)

    @property
    def digest(self) -> str:
        """Changes whenever the map does. Part of the ruler version, because a
        different map produces a different score for the same run."""
        blob = json.dumps(self._pairs, ensure_ascii=False).encode()
        return hashlib.sha256(blob).hexdigest()[:12]

    def apply_str(self, s: str) -> str:
        for real, pseudo in self._pairs:
            if real in s:
                s = s.replace(real, pseudo)
        return s

    def apply(self, obj):
        """Recursively pseudonymise every string in a model output."""
        if isinstance(obj, str):
            return self.apply_str(obj)
        if isinstance(obj, dict):
            return {k: self.apply(v) for k, v in obj.items()}
        if isinstance(obj, list):
            return [self.apply(v) for v in obj]
        return obj


EMPTY = PiiMap({})


def load(path: Path = PII_MAP_FILE) -> PiiMap:
    if not path.exists():
        return EMPTY
    data = json.loads(path.read_text(encoding="utf-8"))
    return PiiMap({k: v for k, v in data.get("replacements", {}).items()}, source=path)


def status_line(m: PiiMap) -> str:
    if len(m) == 0:
        return ("PII map: none found at private/pii_map.json — keys are anonymised and the pages "
                "are not, so every correct read of a substituted name will score as wrong.")
    return f"PII map: {len(m)} replacements from private/pii_map.json (map {m.digest})"
