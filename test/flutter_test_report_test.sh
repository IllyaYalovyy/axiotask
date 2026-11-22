#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import importlib.util
import json
import pathlib
import tempfile

spec = importlib.util.spec_from_file_location('checker', 'scripts/check_flutter_test_report.py')
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)
start = {'type': 'testStart', 'test': {'id': 1}}
passed = {'type': 'testDone', 'testID': 1, 'result': 'success', 'hidden': False, 'skipped': False}
done = {'type': 'done', 'success': True}
with tempfile.TemporaryDirectory() as directory:
    path = pathlib.Path(directory) / 'report.jsonl'
    cases = [
        ([start, passed, done], True),
        ([start], False),  # interrupted, even if the subprocess exits zero
        ([start, done], False),  # success claimed while a test is unfinished
        ([start, passed, {'type': 'done', 'success': False}], False),
        ([start, {**passed, 'result': 'failure'}, done], False),
        ([start, {'type': 'error'}, passed, done], False),
        ([], False),
    ]
    for events, valid in cases:
        path.write_text(''.join(json.dumps(event) + '\n' for event in events))
        try:
            checker.validate(path)
        except ValueError:
            assert not valid, events
        else:
            assert valid, events
    path.write_text('{"type":')
    try:
        checker.validate(path)
    except ValueError:
        pass
    else:
        raise AssertionError('truncated report accepted')
print('Flutter test completion report regressions passed')
PY

# Reproduce the actual failure mode at the command boundary: Flutter returns
# zero but leaves an incomplete report. The wrapper must still fail.
fake_dir=$(mktemp -d)
trap 'rm -rf "$fake_dir"' EXIT
cat > "$fake_dir/flutter" <<'SH'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  if [[ $1 == --file-reporter ]]; then
    printf '%s\n' '{"type":"testStart","test":{"id":1}}' > "${2#json:}"
    exit 0
  fi
  shift
done
exit 2
SH
chmod +x "$fake_dir/flutter"
if PATH="$fake_dir:$PATH" bash scripts/verified_flutter_test.sh > "$fake_dir/output" 2>&1; then
  echo 'Incomplete zero-exit Flutter run was accepted' >&2
  exit 1
fi
grep -q 'Flutter test report rejected' "$fake_dir/output"
echo 'Zero-exit incomplete Flutter run rejected by the quality wrapper'
