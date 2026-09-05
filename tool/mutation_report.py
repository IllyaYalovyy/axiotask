#!/usr/bin/env python3
"""Summarise mutation_test reports and enforce the per-file survivor ratchet.

`tool/mutation.sh` leaves one markdown report per source file under `mutation/`.
This turns that pile into (a) one table a human can read, (b) `survivors.tsv` —
every mutant the suite did not notice, as `file / line / original / mutated` —
and (c) a pass/fail verdict against `tool/mutation_baseline.tsv`.

The baseline is a RATCHET seeded from the 2026-09-02/03 pilot: a file may never
grow more survivors than it had. Lower it when survivors are killed; raising it
means a mutant went unnoticed that used to be caught, which is a regression in
the SUITE even when the product code is fine.

Usage:
  tool/mutation_report.py mutation/                  # table + verdict
  tool/mutation_report.py -v mutation/dates.md       # + every survivor
  tool/mutation_report.py --tsv mutation/survivors.tsv mutation/

Exit status: 0 = every file at or below its baseline, 1 = a file exceeded it
(or a report could not be parsed), 2 = usage error.
"""

from __future__ import annotations

import argparse
import html
import os
import re
import sys
from dataclasses import dataclass, field

# The report is markdown with inline HTML: an outer span holds the whole line,
# coloured red (the original) or green (the mutated text), and a nested span
# highlights the changed characters inside it. The outer span always ends at
# "</span><br>" — the nested one never does, whether it closes mid-line
# ("<=</span> 0 ? a : b;") or runs to the end of a multi-line mutant
# ("</span></span><br>"). Mutants spanning source lines carry real newlines, so
# the search is DOTALL.
_ORIGINAL = re.compile(r"rgb\(255, 200, 200\);\">(.*?)</span><br>", re.S)
_MUTATED = re.compile(r"rgb\(200, 255, 200\);\">(.*?)</span><br>", re.S)
_LINE_MARK = re.compile(r"^Line (\d+):<br>$", re.M)
# Only the report's own markup. A blunt `<[^>]+>` would eat Dart operators:
# "<=</span>" starts with a "<" and ends with a ">", so the whole thing —
# comparison included — would vanish from the survivor text.
_TAG = re.compile(r"</?(?:span|br|b|i)\b[^>]*>", re.I)
_SECTION = re.compile(r"^## Undetected mutations in file : (.+)$", re.M)
_STAT = re.compile(r"^\| ([^|]+?) *\| *([^|]*?) *\|$", re.M)


@dataclass
class Survivor:
    line: int
    original: str
    mutated: str


@dataclass
class Report:
    path: str
    source: str
    mutants: int = 0
    survived: int = 0
    uncovered: int = 0
    timeouts: int = 0
    elapsed: str = ""
    survivors: list[Survivor] = field(default_factory=list)


def _flatten(text: str) -> str:
    """One report snippet as one TSV-safe line ("\\n" marks a real newline)."""
    text = _TAG.sub("", text)
    text = html.unescape(text.replace("&nbsp;", " "))
    text = text.strip()
    text = re.sub(r"^[-+] ?", "", text)
    return "\\n".join(part.strip() for part in text.split("\n"))


def _int(stats: dict[str, str], key: str) -> int:
    try:
        return int(stats.get(key, "0"))
    except ValueError:
        return 0


def parse_report(path: str) -> Report:
    with open(path, encoding="utf-8") as handle:
        text = handle.read()

    stats = {k.strip(): v.strip() for k, v in _STAT.findall(text)}
    section = _SECTION.search(text)
    if section:
        source = section.group(1).strip()
    else:
        # A report with zero undetected mutations may carry no section header;
        # the config mutation.sh wrote next to it still names the source.
        source = _source_from_config(path)

    report = Report(
        path=path,
        source=source,
        mutants=_int(stats, "Mutations"),
        survived=_int(stats, "Undetected"),
        uncovered=_int(stats, "Not covered by tests"),
        timeouts=_int(stats, "Timeouts"),
        elapsed=stats.get("Elapsed", ""),
    )

    body = text[section.end():] if section else ""
    marks = list(_LINE_MARK.finditer(body))
    for index, mark in enumerate(marks):
        end = marks[index + 1].start() if index + 1 < len(marks) else len(body)
        block = body[mark.end():end]
        original = _ORIGINAL.search(block)
        mutated = _MUTATED.search(block)
        if not original or not mutated:
            continue
        report.survivors.append(
            Survivor(
                line=int(mark.group(1)),
                original=_flatten(original.group(1)),
                mutated=_flatten(mutated.group(1)),
            )
        )
    return report


def _source_from_config(report_path: str) -> str:
    config = os.path.splitext(report_path)[0] + ".xml"
    if os.path.exists(config):
        with open(config, encoding="utf-8") as handle:
            match = re.search(r"<file>\s*([^<\s]+)", handle.read())
            if match:
                return match.group(1)
    return os.path.splitext(os.path.basename(report_path))[0]


def read_baseline(path: str) -> dict[str, int]:
    baseline: dict[str, int] = {}
    with open(path, encoding="utf-8") as handle:
        for number, raw in enumerate(handle, start=1):
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            fields = line.split("\t")
            if len(fields) != 2 or not fields[1].strip().isdigit():
                raise SystemExit(
                    f"{path}:{number}: expected '<lib/path.dart><TAB><max survivors>'"
                )
            baseline[fields[0].strip()] = int(fields[1].strip())
    return baseline


def collect(paths: list[str]) -> list[str]:
    reports: list[str] = []
    for path in paths:
        if os.path.isdir(path):
            reports += [
                os.path.join(path, name)
                for name in sorted(os.listdir(path))
                if name.endswith(".md")
            ]
        else:
            reports.append(path)
    return reports


def write_tsv(path: str, reports: list[Report]) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("file\tline\toriginal\tmutated\n")
        for report in reports:
            for survivor in report.survivors:
                handle.write(
                    f"{report.source}\t{survivor.line}\t"
                    f"{survivor.original}\t{survivor.mutated}\n"
                )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Summarise mutation_test reports and check the survivor ratchet."
    )
    parser.add_argument("reports", nargs="+", help="report .md files or a directory")
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="list every surviving mutant"
    )
    parser.add_argument("--baseline", help="per-file survivor ratchet (TSV)")
    parser.add_argument("--tsv", help="write the survivor list here")
    args = parser.parse_args(argv)

    paths = collect(args.reports)
    if not paths:
        print("no mutation reports found (run tool/mutation.sh first)", file=sys.stderr)
        return 2
    reports = sorted((parse_report(p) for p in paths), key=lambda r: r.source)

    width = max([len(r.source) for r in reports] + [len("source")])
    print(
        f"{'source':<{width}}  mutants  survived  uncovered  timeouts  "
        f"baseline  elapsed"
    )
    baseline = read_baseline(args.baseline) if args.baseline else {}
    over: list[tuple[Report, int]] = []
    unlisted: list[Report] = []
    # A survivor is judged by reading it. Two kinds are counted but never
    # listed: mutants no test covers, and mutants that HUNG the suite (the tool
    # kills the command at the timeout and has no result text to quote).
    # Anything beyond those two gaps means the extraction lost mutants — a
    # silent parse failure would show survivors nobody can see.
    unreadable = [
        r
        for r in reports
        if len(r.survivors) + r.uncovered + r.timeouts < r.survived
    ]
    for report in reports:
        cap = baseline.get(report.source)
        if args.baseline and cap is None:
            unlisted.append(report)
        elif cap is not None and report.survived > cap:
            over.append((report, cap))
        print(
            f"{report.source:<{width}}  {report.mutants:>7}  {report.survived:>8}  "
            f"{report.uncovered:>9}  {report.timeouts:>8}  "
            f"{'-' if cap is None else cap:>8}  {report.elapsed.split('.')[0]}"
        )
    total = sum(r.survived for r in reports)
    print(
        f"{'TOTAL':<{width}}  {sum(r.mutants for r in reports):>7}  {total:>8}  "
        f"{sum(r.uncovered for r in reports):>9}  "
        f"{sum(r.timeouts for r in reports):>8}"
    )

    if args.verbose:
        for report in reports:
            if not report.survivors:
                continue
            print(f"\n{report.source}")
            for survivor in report.survivors:
                print(f"  L{survivor.line}  {survivor.original}")
                print(f"  {' ' * len(str(survivor.line))}  -> {survivor.mutated}")

    if args.tsv:
        write_tsv(args.tsv, reports)
        print(f"\nsurvivors -> {args.tsv} ({total} mutant(s) no test noticed)")

    for report in unlisted:
        print(
            f"note: {report.source} has no baseline entry — add "
            f"'{report.source}\t{report.survived}' to {args.baseline} to ratchet it"
        )
    for report in unreadable:
        print(
            f"CANNOT READ {report.path}: {report.survived} undetected mutants "
            f"but only {len(report.survivors)} could be read from the report "
            f"({report.uncovered} covered by no test, {report.timeouts} timed "
            f"out). The report format changed or the parser broke — fix it "
            f"before trusting a number."
        )
    for report, cap in over:
        print(
            f"RATCHET FAILED: {report.source} has {report.survived} survivors, "
            f"baseline {cap}. A survivor is closed by an ASSERTION that fails "
            f"on the mutant — never by excluding the line or raising the cap."
        )
    return 1 if over or unreadable else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
