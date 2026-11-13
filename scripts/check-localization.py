#!/usr/bin/env python3
"""Lists the keys of Resources/en.lproj/Localizable.strings that no string literal in Sources/ can produce any more.

The English table is written by hand and nothing compiles it, so a sentence that is reworded or deleted in the code
leaves its translation behind, where it reads as if it were in use. A key is reachable when some literal in the
sources, with each interpolation `\\(...)` standing for one format specifier, spells it exactly. Keys built at run time
from a literal elsewhere (an enum's raw value, a preset's title) are literals too, so they are found the same way.

    python3 scripts/check-localization.py                 # prints the orphans and exits 1 if there are any
    python3 scripts/check-localization.py --baseline FILE # fails only on orphans FILE does not list (CI)
    python3 scripts/check-localization.py --write-baseline FILE

scripts/localization-orphans.txt lists, one repr() per line, the keys that were already orphaned when this check was
added, so that CI catches new ones without deleting translations nobody has reviewed. Remove a line once its key is
deleted from the table (or used again); the script says which lines no longer apply.
"""
import pathlib, plistlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TABLE = ROOT / "Resources" / "en.lproj" / "Localizable.strings"
PLURALS = ROOT / "Resources" / "en.lproj" / "Localizable.stringsdict"
SOURCES = ROOT / "Sources"
HOLE = "\u0000"  # what an interpolation and a format specifier both become

SPECIFIER = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|f|\.\d+f|u|llu|lu|s)")


def literals(text):
    """Every string literal of a Swift file, interpolations replaced by HOLE, escapes resolved."""
    found, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i); i = n if j < 0 else j; continue
        if text.startswith("/*", i):
            j = text.find("*/", i + 2); i = n if j < 0 else j + 2; continue
        if text.startswith('"""', i):
            j = text.find('"""', i + 3)
            if j < 0: break
            found.append(_unescape(text[i + 3:j])); i = j + 3; continue
        if c == '"':
            out, i = [], i + 1
            while i < n and text[i] != '"' and text[i] != "\n":
                if text[i] == "\\" and i + 1 < n:
                    if text[i + 1] == "(":
                        depth, i = 1, i + 2
                        while i < n and depth:
                            if text[i] == "(": depth += 1
                            elif text[i] == ")": depth -= 1
                            elif text[i] == '"':  # a literal inside the interpolation
                                i += 1
                                while i < n and text[i] != '"':
                                    i += 2 if text[i] == "\\" else 1
                            i += 1
                        out.append(HOLE); continue
                    out.append(text[i:i + 2]); i += 2; continue
                out.append(text[i]); i += 1
            found.append(_unescape("".join(out))); i += 1; continue
        i += 1
    return found


def _unescape(s):
    return (s.replace('\\"', '"').replace("\\n", "\n").replace("\\t", "\t").replace("\\r", "\r")
             .replace("\\\\", "\\"))


def normalise(key):
    return SPECIFIER.sub(HOLE, key.replace("%%", "%"))


def main(argv):
    table = plistlib.loads(TABLE.read_bytes()) if TABLE.read_bytes().lstrip().startswith(b"<") else _strings(TABLE)
    known = set()
    for path in SOURCES.rglob("*.swift"):
        known.update(literals(path.read_text(encoding="utf-8")))
    plural_keys = set(plistlib.loads(PLURALS.read_bytes())) if PLURALS.exists() else set()
    orphans = sorted(key for key in table if key not in known and normalise(key) not in known and key not in plural_keys)
    if "--write-baseline" in argv:
        path = pathlib.Path(argv[argv.index("--write-baseline") + 1])
        path.write_text("".join(repr(key) + "\n" for key in orphans), encoding="utf-8")
        print(f"Wrote {len(orphans)} keys to {path}.")
        return 0
    if "--baseline" in argv:
        import ast
        path = pathlib.Path(argv[argv.index("--baseline") + 1])
        accepted = {ast.literal_eval(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()}
        new = [key for key in orphans if key not in accepted]
        stale = sorted(accepted - set(orphans))
        for key in stale:
            print(f"No longer orphaned, remove from {path.name}: {key!r}")
        for key in new:
            print(f"New orphan in en.lproj/Localizable.strings: {key!r}")
        print(f"{len(orphans)} orphaned keys, {len(accepted)} accepted in {path.name}, {len(new)} new.")
        return 1 if new else 0
    for key in orphans:
        print(repr(key))
    print(f"{len(orphans)} of {len(table)} English keys match no literal in Sources/.", file=sys.stderr)
    return 1 if orphans else 0


def _strings(path):
    """A .strings file in the old-style plist syntax, which plistlib does not read."""
    import subprocess, json
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(path)], check=True, capture_output=True).stdout
    return json.loads(out)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
