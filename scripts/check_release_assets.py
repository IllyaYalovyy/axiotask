#!/usr/bin/env python3
"""Fail publication if a distribution package or its checksum is missing."""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
version_line = next(line for line in pathlib.Path("pubspec.yaml").read_text().splitlines() if line.startswith("version: "))
version, build = version_line.split()[1].split("+")
expected = {
    f"axiotask-{version}-{build}.x86_64.rpm",
    f"axiotask_{version}-{build}_amd64.deb",
    f"axiotask-{version}.flatpak",
    f"axiotask-{version}.apk",
    "ANDROID_SIGNING_CERT.txt",
}
actual = {p.name for p in root.iterdir() if p.is_file()}
if actual != expected | {"SHA256SUMS"}:
    raise SystemExit(f"Unexpected release asset set: {sorted(actual)}; expected {sorted(expected | {'SHA256SUMS'})}")
checksummed = {line.split()[1] for line in (root / "SHA256SUMS").read_text().splitlines()}
if checksummed != expected:
    raise SystemExit("SHA256SUMS must cover every package and the signing certificate report")
print("Complete release artifact set verified")
