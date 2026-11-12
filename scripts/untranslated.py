#!/usr/bin/env python3
"""Lists the strings the app shows that Resources/en.lproj does not translate.

The compiler knows every localizable string in the sources, interpolated ones included, with the exact format
specifiers it gives them. This asks it for that list (a build into a throwaway folder, with -emit-localized-strings)
and prints the keys that are in neither Localizable.strings nor Localizable.stringsdict. Run it after adding text:

    python3 scripts/untranslated.py

A key printed here shows in Spanish in an English interface. A count that can be 1 belongs in scripts/make-plurals.py.
"""
import glob, json, pathlib, shutil, subprocess, sys, tempfile

root = pathlib.Path(__file__).resolve().parent.parent
# Keys that are not text: a path placeholder, a host name, an octal example, single letters naming the two sides.
IGNORED = {"A", "B", "%@", "%@: %@", "755", "cloud.o2online.es"}

build = pathlib.Path(tempfile.mkdtemp(prefix="icloudy-strings-"))
try:
    result = subprocess.run(["swift", "build", "--build-path", str(build), "-Xswiftc", "-emit-localized-strings",
                             "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", str(build / "strings")],
                            cwd=root, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(result.stdout + result.stderr)
    keys = {}
    for path in glob.glob(str(build / "**" / "*.stringsdata"), recursive=True):
        for entries in json.load(open(path)).get("tables", {}).values():
            for entry in entries:
                keys.setdefault(entry["key"], pathlib.Path(path).stem)
finally:
    shutil.rmtree(build, ignore_errors=True)

def table(name):
    converted = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(root / "Resources" / "en.lproj" / name)],
                               capture_output=True, text=True, check=True)
    return json.loads(converted.stdout)

translated = set(table("Localizable.strings")) | set(table("Localizable.stringsdict"))
missing = sorted((source, key) for key, source in keys.items() if key.strip() and key not in translated and key not in IGNORED)
for source, key in missing:
    print(f"{source}: {key}")
print(f"{len(keys)} strings, {len(missing)} without an English translation", file=sys.stderr)
sys.exit(1 if missing else 0)
