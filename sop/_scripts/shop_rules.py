"""Write the Technical systems manual's list of shop rules, read out of sql/.

Each rule is registered in a comment where it is added, in this shape:

    --   GR021  a counter-entered shot whose dates cannot go on a vaccination
    --          record ...

This gathers those comments, in code order, into systems/_shop-rules-list.md,
which systems/shop-rules.qmd pulls in. Quarto runs it before every build
(pre-render in _quarto.yml), from the sop/ folder.

The list is kept in git: Quarto looks for included files before it runs this,
so the file has to be there on a fresh copy. It is only rewritten when a rule
changes, so it shows up as changed in the same branch as the sql/ file that
added the rule.
"""

import re
from pathlib import Path

SOP = Path(__file__).resolve().parent.parent
SQL = SOP.parent / "sql"
OUT = SOP / "systems" / "_shop-rules-list.md"

START = re.compile(r"^--\s+(GR\d{3})\s{2,}(\S.*)$")
MORE = re.compile(r"^--\s{6,}(\S.*)$")


def gather():
    rules = {}
    for path in sorted(SQL.glob("*.sql")):
        code = None
        for line in path.read_text(encoding="utf-8").splitlines():
            if m := START.match(line):
                code = m.group(1)
                rules[code] = {"text": m.group(2).strip(), "file": path.name}
            elif code and (m := MORE.match(line)):
                rules[code]["text"] += " " + m.group(1).strip()
            else:
                code = None
    return dict(sorted(rules.items()))


def main():
    rules = gather()
    lines = [
        f"{len(rules)} rules.",
        "",
        "| Code | What it refuses | Added in |",
        "|---|---|---|",
    ]
    for code, rule in rules.items():
        text = rule["text"].replace("|", "\\|")
        lines.append(f"| {code} | {text[0].upper() + text[1:]} | `{rule['file']}` |")
    text = "\n".join(lines) + "\n"
    if not OUT.exists() or OUT.read_text(encoding="utf-8") != text:
        OUT.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
