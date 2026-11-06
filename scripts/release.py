#!/usr/bin/env python3
"""Release helpers. Everything here reads the repository; nothing talks to the network.

    python3 scripts/release.py check [--tag v0.9.0]
        VERSION, the newest release heading in CHANGELOG.md and the README badge say the same version, and the tag,
        when given, is that version with a "v" in front. CI runs it on every push; the release workflow, with --tag.

    python3 scripts/release.py notes 0.9.0 [--unsigned]
        Prints that version's section of CHANGELOG.md, the body of the GitHub release.

    python3 scripts/release.py appcast --version 0.9.0 --build 260 --notes notes.md --zip X.zip --dmg X.dmg \
            [--signed] [--repo ruvelro/iCloudy] [--out dist/release]
        Writes appcast.json, which the app's update checker reads, and appcast.xml, the same release in Sparkle's
        format for whoever adopts Sparkle later (see docs/DISTRIBUCION.md).

    python3 scripts/release.py cask --version 0.9.0 --zip X.zip [--signed] [--out dist/release]
        Fills packaging/homebrew/icloudy.rb with the version, the file name and its SHA-256.

The README and CHANGELOG stay written by hand; only VERSION is read by the build (scripts/version.sh).
"""

import argparse
import datetime
import hashlib
import json
import os
import plistlib
import re
import sys
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEMVER = r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?"
DEFAULT_REPO = "ruvelro/iCloudy"


def read(relative):
    with open(os.path.join(ROOT, relative), encoding="utf-8") as handle:
        return handle.read()


def version_file():
    version = read("VERSION").strip()
    if not re.fullmatch(SEMVER, version):
        sys.exit(f"VERSION no contiene una versión SemVer válida: «{version}».")
    return version


def changelog_releases(text):
    """Release headings in file order: "## 0.7.0 — 12 de octubre de 2026" gives "0.7.0"."""
    return re.findall(rf"^## ({SEMVER})(?=\s|$)", text, flags=re.MULTILINE)


def readme_badge(text):
    # shields.io writes a literal "-" inside a value as "--", so "0.9.0-beta.1" appears as "0.9.0--beta.1".
    match = re.search(r"badge/versi%C3%B3n-|badge/versión-", text)
    if not match:
        return None
    rest = text[match.end():]
    value = re.match(r"((?:[^-]|--)+)-", rest)
    return value.group(1).replace("--", "-") if value else None


def command_check(args):
    problems = []
    version = version_file()
    readme = read("README.md")
    changelog = read("CHANGELOG.md")

    releases = changelog_releases(changelog)
    if not releases:
        problems.append("CHANGELOG.md no tiene ningún encabezado de versión («## X.Y.Z — fecha»).")
    elif releases[0] != version:
        problems.append(f"La versión más reciente de CHANGELOG.md es {releases[0]} y VERSION dice {version}.")

    badge = readme_badge(readme)
    if badge is None:
        problems.append("El README no tiene el distintivo de versión (img.shields.io/badge/versión-…).")
    elif badge != version:
        problems.append(f"El distintivo del README dice {badge} y VERSION dice {version}.")

    # The notice under the title names major.minor only ("Versión 0.7").
    notice = re.search(r"\*\*Versión ([0-9]+\.[0-9]+)\*\*", readme)
    major_minor = ".".join(version.split("-")[0].split(".")[:2])
    if notice and notice.group(1) != major_minor:
        problems.append(f"El aviso del README dice «Versión {notice.group(1)}» y VERSION dice {version}.")

    # The Info.plist carries placeholders on purpose: a version typed there would be a second source.
    with open(os.path.join(ROOT, "Resources/Info.plist"), "rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleShortVersionString") != "0.0.0" or info.get("CFBundleVersion") != "0":
        problems.append("Resources/Info.plist debe dejar CFBundleShortVersionString en 0.0.0 y CFBundleVersion en 0: "
                        "los escribe scripts/build-app.sh desde VERSION.")

    if args.tag is not None and args.tag != f"v{version}":
        problems.append(f"La etiqueta {args.tag} no corresponde a VERSION ({version}); debería ser v{version}.")

    if problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        return 1
    print(f"Versión {version}: VERSION, CHANGELOG.md y README.md coinciden"
          + (f", y la etiqueta {args.tag} también." if args.tag else "."))
    return 0


def changelog_section(version):
    text = read("CHANGELOG.md")
    match = re.search(rf"^## {re.escape(version)}(?=\s|$)[^\n]*\n(.*?)(?=^## |\Z)", text, flags=re.MULTILINE | re.DOTALL)
    if not match:
        sys.exit(f"CHANGELOG.md no tiene una sección «## {version}».")
    return match.group(1).strip() + "\n"


UNSIGNED_NOTICE = (
    "> [!WARNING]\n"
    "> **Compilación sin firmar.** Este paquete no lleva firma Developer ID ni notarización de Apple: macOS lo "
    "bloqueará al abrirlo. Para abrirlo, pulsa con el botón derecho sobre iCloudy.app, elige «Abrir» y confirma "
    "(o ve a Ajustes del Sistema › Privacidad y seguridad › «Abrir igualmente»). Comprueba antes la suma SHA-256 "
    "con `shasum -a 256 -c SHA256SUMS.txt`.\n\n"
)


def command_notes(args):
    body = changelog_section(args.version)
    sys.stdout.write((UNSIGNED_NOTICE if args.unsigned else "") + body)
    return 0


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def asset(kind, path, repo, tag):
    name = os.path.basename(path)
    return {
        "kind": kind,
        "name": name,
        "url": f"https://github.com/{repo}/releases/download/{tag}/{name}",
        "size": os.path.getsize(path),
        "sha256": sha256(path),
    }


def minimum_system():
    with open(os.path.join(ROOT, "Resources/Info.plist"), "rb") as handle:
        return plistlib.load(handle).get("LSMinimumSystemVersion", "14.0")


def command_appcast(args):
    tag = f"v{args.version}"
    with open(args.notes, encoding="utf-8") as handle:
        notes = handle.read()
    published = args.date or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    assets = [asset("zip", args.zip, args.repo, tag)]
    if args.dmg:
        assets.append(asset("dmg", args.dmg, args.repo, tag))
    feed = {
        "schemaVersion": 1,
        "version": args.version,
        "build": str(args.build),
        "published": published,
        "minimumSystemVersion": minimum_system(),
        "signed": args.signed,
        "releaseURL": f"https://github.com/{args.repo}/releases/tag/{tag}",
        "notes": notes,
        "assets": assets,
    }
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "appcast.json"), "w", encoding="utf-8") as handle:
        json.dump(feed, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    # Sparkle's RSS dialect. There is no sparkle:edSignature: that needs Sparkle's EdDSA key, which only exists
    # once Sparkle itself is adopted. The checker in the app reads the JSON above.
    zip_asset = assets[0]
    pub_date = datetime.datetime.strptime(published, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    rss_date = pub_date.strftime("%a, %d %b %Y %H:%M:%S +0000")
    xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>iCloudy</title>
    <link>https://github.com/{escape(args.repo)}/releases</link>
    <item>
      <title>iCloudy {escape(args.version)}</title>
      <pubDate>{rss_date}</pubDate>
      <link>{escape(feed["releaseURL"])}</link>
      <sparkle:version>{escape(str(args.build))}</sparkle:version>
      <sparkle:shortVersionString>{escape(args.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(feed["minimumSystemVersion"])}</sparkle:minimumSystemVersion>
      <description><![CDATA[<pre>{notes.replace("]]>", "]]&gt;")}</pre>]]></description>
      <enclosure url="{escape(zip_asset["url"])}" length="{zip_asset["size"]}" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
"""
    with open(os.path.join(args.out, "appcast.xml"), "w", encoding="utf-8") as handle:
        handle.write(xml)
    print(f"appcast.json y appcast.xml escritos en {args.out}")
    return 0


UNSIGNED_CAVEATS = """
  caveats <<~EOS
    Esta versión de iCloudy no está firmada ni notarizada por Apple. La primera vez, ábrela con el botón
    derecho › Abrir, o desde Ajustes del Sistema › Privacidad y seguridad › «Abrir igualmente».
  EOS
"""


def command_cask(args):
    template = read("packaging/homebrew/icloudy.rb")
    filled = (template.replace("@VERSION@", args.version)
              .replace("@SHA256@", sha256(args.zip))
              .replace("@ZIP@", os.path.basename(args.zip).replace(args.version, "#{version}"))
              .replace("@CAVEATS@\n", "" if args.signed else UNSIGNED_CAVEATS))
    leftover = re.findall(r"@[A-Z0-9]+@", filled)
    if leftover:
        sys.exit(f"La plantilla del cask tiene marcadores sin rellenar: {', '.join(leftover)}")
    os.makedirs(args.out, exist_ok=True)
    path = os.path.join(args.out, "icloudy.rb")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(filled)
    print(f"Cask escrito en {path}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    check = commands.add_parser("check", help="VERSION, CHANGELOG.md y README.md coinciden")
    check.add_argument("--tag", help="la etiqueta de Git que se publica, por ejemplo v0.9.0")
    check.set_defaults(run=command_check)

    notes = commands.add_parser("notes", help="la sección de CHANGELOG.md de una versión")
    notes.add_argument("version")
    notes.add_argument("--unsigned", action="store_true", help="antepone el aviso de compilación sin firmar")
    notes.set_defaults(run=command_notes)

    appcast = commands.add_parser("appcast", help="appcast.json y appcast.xml")
    appcast.add_argument("--version", required=True)
    appcast.add_argument("--build", required=True)
    appcast.add_argument("--notes", required=True, help="archivo con las notas de la versión")
    appcast.add_argument("--zip", required=True)
    appcast.add_argument("--dmg")
    appcast.add_argument("--signed", action="store_true")
    appcast.add_argument("--repo", default=DEFAULT_REPO)
    appcast.add_argument("--date", help="fecha ISO 8601 en UTC; por omisión, ahora")
    appcast.add_argument("--out", default=os.path.join(ROOT, "dist/release"))
    appcast.set_defaults(run=command_appcast)

    cask = commands.add_parser("cask", help="el cask de Homebrew relleno")
    cask.add_argument("--version", required=True)
    cask.add_argument("--zip", required=True)
    cask.add_argument("--signed", action="store_true")
    cask.add_argument("--out", default=os.path.join(ROOT, "dist/release"))
    cask.set_defaults(run=command_cask)

    args = parser.parse_args()
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main())
