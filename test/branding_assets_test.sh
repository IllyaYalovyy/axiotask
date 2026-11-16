#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
from pathlib import Path
import hashlib
import struct
import xml.etree.ElementTree as ET

root = Path('.')
manifest = {}
for line in Path('assets/branding/icons.sha256').read_text().splitlines():
    if not line.strip() or line.startswith('#'):
        continue
    digest, name = line.split(maxsplit=1)
    manifest[name] = digest
    assert hashlib.sha256(Path(name).read_bytes()).hexdigest() == digest, name
assert Path('assets/branding/axiotask.svg').read_bytes() == Path(
    'linux/packaging/icons/hicolor/scalable/apps/io.github.IllyaYalovyy.axiotask.svg'
).read_bytes()
ns = '{http://schemas.android.com/apk/res/android}'
application = ET.parse('android/app/src/main/AndroidManifest.xml').getroot().find('application')
assert application.get(ns + 'icon') == '@mipmap/ic_launcher'
assert application.get(ns + 'roundIcon') == '@mipmap/ic_launcher_round'
for name in ('ic_launcher', 'ic_launcher_round'):
    icon = ET.parse(f'android/app/src/main/res/mipmap-anydpi-v26/{name}.xml').getroot()
    assert icon.tag == 'adaptive-icon'
    for layer in ('foreground', 'background', 'monochrome'):
        assert icon.find(layer).get(ns + 'drawable') == '@mipmap/ic_launcher_' + layer
for density, legacy, adaptive in [('mdpi',48,108),('hdpi',72,162),('xhdpi',96,216),('xxhdpi',144,324),('xxxhdpi',192,432)]:
    for name in ('ic_launcher','ic_launcher_round','ic_launcher_foreground','ic_launcher_background','ic_launcher_monochrome'):
        path = f'android/app/src/main/res/mipmap-{density}/{name}.png'
        assert path in manifest, path
        data = Path(path).read_bytes()
        size = legacy if name in ('ic_launcher','ic_launcher_round') else adaptive
        assert data[:8] == b'\x89PNG\r\n\x1a\n', path
        assert struct.unpack('>II', data[16:24]) == (size,size), path
print('Branding asset contract passed')
PY
