#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import pathlib
import subprocess
import tempfile
fingerprint = '1935e06653e69ddaf6e616a6f2c35b53425f14a3e94cd8daaf219338757cb796'
with tempfile.TemporaryDirectory() as work:
    report = pathlib.Path(work) / 'certificate.txt'
    def check(text, valid):
        report.write_text(text)
        result = subprocess.run(['python3', 'scripts/check_android_signing_cert.py', str(report)], capture_output=True)
        assert (result.returncode == 0) == valid, result.stderr.decode()
    check('Signer #1 certificate SHA-256 digest: ' + fingerprint + '\n', True)
    check('V2 Signer: certificate SHA-256 digest: ' + fingerprint + '\n', True)
    check('V2 Signer: certificate SHA-256 digest: ' + fingerprint.upper() + '\nV3 Signer: certificate SHA-256 digest: ' + fingerprint + '\n', True)
    check('Signer #1 certificate SHA-256 digest: ' + '0' * 64 + '\n', False)
    check('Signer #1 certificate SHA-256 digest: ' + fingerprint + '\nSigner #2 certificate SHA-256 digest: ' + '0' * 64 + '\n', False)
    check('No certificate digest\n', False)
print('Android signing certificate report tests passed')
PY
