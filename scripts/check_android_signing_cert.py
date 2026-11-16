#!/usr/bin/env python3
"""Require the exact OAuth-registered APK signer across apksigner versions."""
import pathlib
import re
import sys

expected = '1935e06653e69ddaf6e616a6f2c35b53425f14a3e94cd8daaf219338757cb796'
report = pathlib.Path(sys.argv[1]).read_text()
# SDK versions use either "Signer #1" or "V2 Signer:" prefixes. Multiple
# signing schemes may report the same certificate; a different signer fails.
digests = {
    value.lower()
    for value in re.findall(r'^.*certificate SHA-256 digest: ([0-9a-fA-F]{64})\s*$', report, re.MULTILINE)
}
if digests != {expected}:
    sys.exit('APK signing certificate does not match the OAuth-registered key')
print('OAuth-registered APK signing certificate verified')
