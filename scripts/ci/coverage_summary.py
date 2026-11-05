"""Prints line coverage per folder of Sources/ from an LCOV file, worst first, and the total.

    python3 scripts/ci/coverage_summary.py coverage.lcov

In GitHub Actions the same table is appended to the job summary ($GITHUB_STEP_SUMMARY).
"""
import collections, os, sys


def folder(path):
    parts = path.split("/")
    if "Sources" not in parts:
        return None
    rest = parts[parts.index("Sources") + 1:]
    # Sources/iCloudy/Providers/Mega/x.swift -> iCloudy/Providers/Mega; Sources/iCloudy/x.swift -> iCloudy
    if len(rest) >= 4 and rest[1] == "Providers":
        return "/".join(rest[:3])
    return "/".join(rest[:2]) if len(rest) > 2 else rest[0]


def main(path):
    found = collections.Counter(); hit = collections.Counter()
    current = None
    with open(path, encoding="utf-8") as lcov:
        for line in lcov:
            if line.startswith("SF:"):
                current = folder(line[3:].strip())
            elif line.startswith("LF:") and current:
                found[current] += int(line[3:])
            elif line.startswith("LH:") and current:
                hit[current] += int(line[3:])
            elif line.startswith("end_of_record"):
                current = None
    rows = sorted(found, key=lambda name: hit[name] / found[name] if found[name] else 1)
    lines = ["| Folder | Lines | Covered | % |", "|---|---:|---:|---:|"]
    for name in rows:
        share = 100 * hit[name] / found[name] if found[name] else 100
        lines.append(f"| {name} | {found[name]} | {hit[name]} | {share:.1f} |")
    total_found, total_hit = sum(found.values()), sum(hit.values())
    total = 100 * total_hit / total_found if total_found else 0
    lines.append(f"| **Total** | {total_found} | {total_hit} | **{total:.1f}** |")
    text = "\n".join(lines)
    print(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as out:
            out.write("### Line coverage\n\n" + text + "\n")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "coverage.lcov")
