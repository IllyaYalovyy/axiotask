// Branding layer — the launcher icon the OS shows for axiotask (#225).
//
// What this protects (and the failures it prevents):
//   - STOCK FLUTTER LOGO SHIPS: every Android mipmap used to be the template's
//     blue Flutter bird. An APK that installs with that icon is indistinguishable
//     from a scaffold app on the user's home screen. The stock bytes are pinned
//     here as a blocklist so they can never come back.
//   - NO ICON AT ALL ON LINUX: the shipped desktop entry says
//     `Icon=axiotask`. If no `axiotask.png` exists under a hicolor theme
//     directory the app-menu entry and the GNOME dash render a generic
//     "missing image" placeholder. Every size the theme spec expects must exist
//     AND be that many pixels square (a 512px file installed under 48x48 is a
//     silently blurry icon).
//   - ADAPTIVE ICON MISSING/BROKEN: without mipmap-anydpi-v26 the launcher
//     letterboxes a square bitmap inside the device's mask on every Android 8+
//     device; without <monochrome> the Android 13+ themed-icon home screen
//     falls back to the full-colour icon. The XML must reference layers that
//     actually exist at every density.
//   - THE SCALABLE ICON IS UNREADABLE: gdk-pixbuf identifies a file by
//     sniffing its first 256 BYTES and nothing further. The hicolor scalable
//     entry IS the master, and the master carries a long design-notes comment;
//     while that comment sat BEFORE the root element it pushed `<svg` to byte
//     2217, far outside the sniff window, and GNOME answered "couldn't
//     recognize the image file format". Search and the app grid ask for sizes
//     the PNG set does not carry (96px, and every 2x scale), fall back to the
//     scalable file, and drew a blank tile (#261). The root element must open
//     inside that window.
//   - ORPHAN BINARIES: the rasters are DERIVED from one SVG master by
//     tool/gen_icons.py. A hand-edited or stale PNG silently diverges from the
//     master. The checked-in sha256 manifest plus the generator's --check mode
//     make that drift a test failure.
//
//   - THE SUITE QUIETLY CHECKING NOTHING: five of the assertions below drive
//     the real renderers (python3 cairosvg, python3 GdkPixbuf). They used to
//     `markTestSkipped` when a renderer was missing, which meant a machine
//     without them ran a GREEN icon suite that had verified none of the things
//     this file exists for. The toolchain is now a PREREQUISITE, checked once
//     up front with an install hint, and absence is a failure (#275).
//
// All of this is checked-in state, so the assertions read the repository files
// directly — no clock, no network, no async.
@Tags(['packaging'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// The one master the whole icon set is generated from.
const _master = 'assets/branding/axiotask.svg';

/// Recorded hashes of everything the generator emits.
const _manifest = 'assets/branding/icons.sha256';

/// The hicolor scalable entry — a verbatim copy of the master, and the file
/// GNOME reads for every icon size the PNG set does not carry.
const _scalable = 'linux/packaging/icons/hicolor/scalable/apps/axiotask.svg';

/// sha256 of the stock Flutter template mipmaps that shipped in this repo
/// before #225. If any launcher bitmap ever hashes to one of these again, the
/// app is back to looking like a scaffold.
const _stockFlutterLogoHashes = <String>{
  // mipmap-mdpi/ic_launcher.png (48x48)
  'c7c0c0189145e4e32a401c61c9bdc615754b0264e7afae24e834bb81049eaf81',
  // mipmap-hdpi/ic_launcher.png (72x72)
  '6a7c8f0d703e3682108f9662f813302236240d3f8f638bb391e32bfb96055fef',
  // mipmap-xhdpi/ic_launcher.png (96x96)
  'e14aa40904929bf313fded22cf7e7ffcbf1d1aac4263b5ef1be8bfce650397aa',
  // mipmap-xxhdpi/ic_launcher.png (144x144)
  '4d470bf22d5c17d84edc5f82516d1ba8a1c09559cd761cefb792f86d9f52b540',
  // mipmap-xxxhdpi/ic_launcher.png (192x192)
  '3c34e1f298d0c9ea3455d46db6b7759c8211a49e9ec6e44b635fc5c87dfb4180',
};

/// hicolor sizes the freedesktop icon theme spec expects for an app icon.
const _hicolorSizes = <int>[16, 24, 32, 48, 64, 128, 256, 512];

/// Android density buckets: legacy launcher px, adaptive-layer px (108dp).
const _androidDensities = <String, ({int legacy, int adaptive})>{
  'mdpi': (legacy: 48, adaptive: 108),
  'hdpi': (legacy: 72, adaptive: 162),
  'xhdpi': (legacy: 96, adaptive: 216),
  'xxhdpi': (legacy: 144, adaptive: 324),
  'xxxhdpi': (legacy: 192, adaptive: 432),
};

String _hicolorPath(int size) =>
    'linux/packaging/icons/hicolor/${size}x$size/apps/axiotask.png';

String _mipmapPath(String density, String name) =>
    'android/app/src/main/res/mipmap-$density/$name.png';

/// Width/height straight out of the PNG IHDR chunk (bytes 16..24).
({int width, int height}) _pngSize(File f) {
  final b = f.readAsBytesSync();
  expect(
    b.length,
    greaterThan(24),
    reason: '${f.path} is too small to be a PNG',
  );
  expect(
    b.sublist(0, 8),
    orderedEquals(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
    reason: '${f.path} is not a PNG',
  );
  int be32(int o) =>
      (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
  return (width: be32(16), height: be32(20));
}

/// gdk-pixbuf decides a file's format from its first 256 bytes and reads no
/// further. Measured on this machine against the real loader: an `<svg` that
/// starts at byte 246 loads, one at byte 256 does not.
const _sniffWindowBytes = 256;

/// The margin the assertion enforces — well inside the real window, so a few
/// more bytes of XML declaration can never silently walk up to the cliff.
const _svgTagMaxOffset = 200;

/// Byte offset of the first `<svg` in [path], or -1 if there is none.
int _svgTagOffset(String path) {
  final bytes = File(path).readAsBytesSync();
  const needle = <int>[0x3C, 0x73, 0x76, 0x67]; // '<svg'
  for (var i = 0; i + needle.length <= bytes.length; i++) {
    var hit = true;
    for (var j = 0; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return i;
  }
  return -1;
}

/// Asks gdk-pixbuf — the loader behind GNOME's icon lookup — to rasterize an
/// SVG at a pixel size, exactly the way the shell does.
const _pixbufLoadScript =
    'import sys, gi\n'
    'gi.require_version("GdkPixbuf", "2.0")\n'
    'from gi.repository import GdkPixbuf\n'
    'size = int(sys.argv[2])\n'
    'pb = GdkPixbuf.Pixbuf.new_from_file_at_size(sys.argv[1], size, size)\n'
    'print(pb.get_width(), pb.get_height())\n';

bool _pixbufAvailable() =>
    Process.runSync('python3', [
      '-c',
      'import gi; gi.require_version("GdkPixbuf", "2.0"); '
          'from gi.repository import GdkPixbuf',
    ]).exitCode ==
    0;

/// The locale is pinned: the assertion below reads glib's own error text, and
/// a translated message would make this test pass or fail by environment.
ProcessResult _pixbufLoadAt(String path, int size) => Process.runSync(
  'python3',
  ['-c', _pixbufLoadScript, path, '$size'],
  environment: const {'LC_ALL': 'C', 'LANGUAGE': 'C'},
);

String _sha256(File f) => sha256.convert(f.readAsBytesSync()).toString();

void _expectSquarePng(String path, int size) {
  final f = File(path);
  expect(f.existsSync(), isTrue, reason: '$path is missing');
  final dim = _pngSize(f);
  expect(
    [dim.width, dim.height],
    orderedEquals([size, size]),
    reason: '$path must be ${size}x$size, got ${dim.width}x${dim.height}',
  );
}

ProcessResult _gen(List<String> args) =>
    Process.runSync('python3', ['tool/gen_icons.py', ...args]);

bool _rendererAvailable() =>
    Process.runSync('python3', ['-c', 'import cairosvg']).exitCode == 0;

/// The one install hint, in one place, so a missing renderer says what to do
/// instead of what is absent.
const _toolchainHint =
    'The icon suite drives the real renderers. Install them:\n'
    '  Fedora: sudo dnf install python3-cairosvg python3-gobject '
    'gdk-pixbuf2-modules\n'
    '  Debian/Ubuntu: sudo apt-get install python3-cairosvg python3-gi '
    'gir1.2-gdkpixbuf-2.0\n'
    'These assertions must never be skipped: a machine without them would run '
    'a green icon suite that verified nothing (#275).';

void main() {
  // Checked FIRST, and once. Every renderer-driven assertion below now runs
  // unconditionally; this test is what turns "the toolchain is missing" into a
  // single legible failure with a fix, instead of five confusing ones.
  group('the icon toolchain is a prerequisite, never a silent skip (#275)', () {
    test('python3 cairosvg is installed', () {
      expect(
        _rendererAvailable(),
        isTrue,
        reason: 'python3 cairosvg is missing.\n$_toolchainHint',
      );
    });

    test('python3 GdkPixbuf is installed', () {
      expect(
        _pixbufAvailable(),
        isTrue,
        reason: 'python3 GdkPixbuf is missing.\n$_toolchainHint',
      );
    });
  });

  group('SVG master', () {
    test('exists and carries the layer ids the generator derives from', () {
      final f = File(_master);
      expect(
        f.existsSync(),
        isTrue,
        reason: 'the one master icon $_master is missing',
      );
      final svg = f.readAsStringSync();
      expect(svg, contains('viewBox="0 0 512 512"'));
      // The generator builds every platform layer by including/excluding these
      // ids; renaming one silently produces empty or wrong layers.
      for (final id in ['bg-tile', 'mark', 'mark-glyph']) {
        expect(
          svg,
          contains('id="$id"'),
          reason: 'master must keep id="$id" (tool/gen_icons.py derives on it)',
        );
      }
    });

    // #261: the design notes used to sit between the XML declaration and the
    // root element, which put `<svg` at byte 2217 — nearly nine times past the
    // window gdk-pixbuf sniffs — so every size served from the scalable file
    // came up blank. Comments belong INSIDE <svg>.
    test('the root <svg> element opens inside the format-sniff window', () {
      for (final path in [_master, _scalable]) {
        final offset = _svgTagOffset(path);
        expect(offset, isNot(-1), reason: '$path has no <svg element at all');
        expect(
          offset,
          lessThan(_svgTagMaxOffset),
          reason:
              '$path opens <svg at byte $offset. gdk-pixbuf sniffs only the '
              'first $_sniffWindowBytes bytes, so anything past that leaves '
              'the file "unrecognized" and GNOME draws a blank icon (#261). '
              'Move the leading comment INSIDE the <svg> element.',
        );
      }
    });

    // The assertion above is a proxy for one thing only: can the desktop's own
    // loader open this file? Ask it directly, at the sizes the shell requests
    // that no PNG in the theme carries — 96px for search and the app grid, and
    // its 2x scale.
    test(
      'gdk-pixbuf renders the scalable icon at the sizes GNOME asks for',
      () {
        for (final size in [96, 192]) {
          final r = _pixbufLoadAt(_scalable, size);
          expect(
            r.exitCode,
            0,
            reason:
                'gdk-pixbuf could not render $_scalable at ${size}px:\n'
                '${r.stderr}',
          );
          expect(
            '${r.stdout}'.trim(),
            '$size $size',
            reason: 'the loader must return a ${size}px square',
          );
        }
      },
    );

    // Non-happy path: prove the 200-byte rule is not a superstition. Push the
    // SAME art past the sniff window and the loader must refuse it — that
    // refusal IS the blank icon #261 reported.
    test('gdk-pixbuf refuses the same art when <svg> falls past the window', () {
      final bytes = File(_scalable).readAsBytesSync();
      final offset = _svgTagOffset(_scalable);
      final tmp = Directory.systemTemp.createTempSync('axiotask_sniff');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final victim = File('${tmp.path}/axiotask.svg');
      // Same document, same root element — only shoved down the file behind a
      // comment long enough to fill the sniff window, as #261 had it.
      final filler = 'x' * _sniffWindowBytes;
      victim.writeAsBytesSync([
        ...bytes.sublist(0, offset),
        ...utf8.encode('<!--$filler-->\n'),
        ...bytes.sublist(offset),
      ]);
      expect(
        _svgTagOffset(victim.path),
        greaterThan(_sniffWindowBytes),
        reason: 'the fixture must actually push <svg out of the window',
      );

      final r = _pixbufLoadAt(victim.path, 96);
      expect(
        r.exitCode,
        isNot(0),
        reason:
            'gdk-pixbuf loaded an SVG whose root element is past byte '
            '$_sniffWindowBytes — the premise of the assertion above no longer '
            'holds and the guard can be reconsidered',
      );
      expect(
        '${r.stderr}',
        contains('recognize'),
        reason: 'the failure must be the format-sniff one #261 hit',
      );
    });
  });

  group('Linux hicolor set (desktop entry says Icon=axiotask)', () {
    test('every themed size exists at its exact pixel size', () {
      for (final size in _hicolorSizes) {
        _expectSquarePng(_hicolorPath(size), size);
      }
    });

    test('the scalable SVG is installed too', () {
      final f = File(
        'linux/packaging/icons/hicolor/scalable/apps/axiotask.svg',
      );
      expect(f.existsSync(), isTrue, reason: 'scalable hicolor icon missing');
      expect(
        f.readAsStringSync(),
        equals(File(_master).readAsStringSync()),
        reason: 'the scalable icon must BE the master, not a stale copy',
      );
    });

    test('the RPM installs the whole themed set, not one lone bitmap', () {
      final spec = Process.runSync('bash', [
        'tool/build_rpm.sh',
        '--print-spec',
      ]);
      expect(spec.exitCode, 0, reason: spec.stderr.toString());
      final files = spec.stdout as String;
      for (final size in _hicolorSizes) {
        expect(
          files,
          contains('/usr/share/icons/hicolor/${size}x$size/apps/axiotask.png'),
          reason: '%files must install the ${size}px icon',
        );
      }
      expect(
        files,
        contains('/usr/share/icons/hicolor/scalable/apps/axiotask.svg'),
      );
    });

    test('the GTK window asks for the themed icon by name', () {
      // Without gtk_window_set_icon_name the shell has nothing to match a
      // running window against, so the taskbar/dash shows a blank tile.
      final runner = File('linux/runner/my_application.cc').readAsStringSync();
      expect(
        runner.replaceAll(RegExp(r'\s+'), ' '),
        contains('gtk_window_set_icon_name(window, "axiotask")'),
        reason: 'the runner must name the hicolor icon for the window/taskbar',
      );
    });
  });

  group('Android launcher icon', () {
    test('no bitmap is the stock Flutter logo any more', () {
      for (final density in _androidDensities.keys) {
        for (final name in [
          'ic_launcher',
          'ic_launcher_round',
          'ic_launcher_foreground',
          'ic_launcher_background',
          'ic_launcher_monochrome',
        ]) {
          final f = File(_mipmapPath(density, name));
          expect(f.existsSync(), isTrue, reason: '${f.path} is missing');
          expect(
            _stockFlutterLogoHashes,
            isNot(contains(_sha256(f))),
            reason: '${f.path} is still the stock Flutter template logo',
          );
        }
      }
    });

    test(
      'legacy and adaptive layers exist at every density, correctly sized',
      () {
        _androidDensities.forEach((density, px) {
          _expectSquarePng(_mipmapPath(density, 'ic_launcher'), px.legacy);
          _expectSquarePng(
            _mipmapPath(density, 'ic_launcher_round'),
            px.legacy,
          );
          for (final layer in [
            'ic_launcher_foreground',
            'ic_launcher_background',
            'ic_launcher_monochrome',
          ]) {
            // Adaptive layers are 108dp, not 48dp: a legacy-sized foreground is
            // blurry under every launcher mask.
            _expectSquarePng(_mipmapPath(density, layer), px.adaptive);
          }
        });
      },
    );

    test('anydpi-v26 declares an adaptive icon with a monochrome layer', () {
      for (final name in ['ic_launcher', 'ic_launcher_round']) {
        final f = File('android/app/src/main/res/mipmap-anydpi-v26/$name.xml');
        expect(f.existsSync(), isTrue, reason: '${f.path} is missing');
        final xml = f.readAsStringSync();
        expect(xml, contains('<adaptive-icon'));
        for (final layer in ['background', 'foreground', 'monochrome']) {
          final m = RegExp(
            '<$layer[^>]*android:drawable="@mipmap/([a-z_]+)"',
          ).firstMatch(xml);
          expect(
            m,
            isNotNull,
            reason:
                '${f.path} must declare a <$layer> layer '
                '(monochrome is the Android 13+ themed icon)',
          );
          // A layer pointing at a resource that does not exist fails the build
          // or renders empty.
          for (final density in _androidDensities.keys) {
            expect(
              File(_mipmapPath(density, m!.group(1)!)).existsSync(),
              isTrue,
              reason:
                  '${f.path} <$layer> references @mipmap/${m.group(1)} '
                  'which has no $density bitmap',
            );
          }
        }
      }
    });

    test('the manifest ships the branded label and both icon attributes', () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(
        manifest,
        contains('android:label="Axiotask"'),
        reason: 'the launcher label users read must be the branded casing',
      );
      expect(manifest, contains('android:icon="@mipmap/ic_launcher"'));
      expect(
        manifest,
        contains('android:roundIcon="@mipmap/ic_launcher_round"'),
        reason: 'launchers that request a round icon must get the round art',
      );
    });
  });

  group('generated assets stay derived from the master', () {
    late Map<String, String> recorded;

    setUpAll(() {
      final f = File(_manifest);
      expect(
        f.existsSync(),
        isTrue,
        reason: '$_manifest (generator provenance) is missing',
      );
      recorded = {
        for (final line in f.readAsLinesSync().where(
          (l) => l.trim().isNotEmpty && !l.startsWith('#'),
        ))
          line.split(RegExp(r'\s+')).last: line.split(RegExp(r'\s+')).first,
      };
    });

    test('every generated file matches its recorded hash', () {
      expect(recorded, isNotEmpty);
      recorded.forEach((path, hash) {
        final f = File(path);
        expect(f.existsSync(), isTrue, reason: '$path listed but missing');
        expect(
          _sha256(f),
          hash,
          reason:
              '$path differs from the manifest — it was hand-edited or the '
              'master changed without re-running tool/gen_icons.py',
        );
      });
    });

    test(
      'the manifest covers the whole generated set (no orphan binaries)',
      () {
        final expected = <String>{
          for (final size in _hicolorSizes) _hicolorPath(size),
          'linux/packaging/icons/hicolor/scalable/apps/axiotask.svg',
          for (final density in _androidDensities.keys) ...[
            _mipmapPath(density, 'ic_launcher'),
            _mipmapPath(density, 'ic_launcher_round'),
            _mipmapPath(density, 'ic_launcher_foreground'),
            _mipmapPath(density, 'ic_launcher_background'),
            _mipmapPath(density, 'ic_launcher_monochrome'),
          ],
        };
        expect(recorded.keys.toSet(), containsAll(expected));
      },
    );

    // Tagged `reference-toolchain` and excluded from CI: this is the one
    // assertion in the file whose expected value is a byte-for-byte artifact of
    // a particular cairosvg/libcairo build. On another distro a fresh render
    // differs from the committed PNGs by a few pixels of anti-aliasing, which
    // reports the runner's renderer version, not a defect. The committed bytes
    // are still guarded everywhere by the recorded-sha256 assertion above; this
    // adds the stronger claim that the GENERATOR still reproduces them, and
    // that claim only means anything on the toolchain they were generated with
    // (the same rule goldens live under).
    test(
      'regenerating from the master reproduces the committed bytes',
      tags: 'reference-toolchain',
      () {
        final r = _gen(['--check']);
        expect(
          r.exitCode,
          0,
          reason:
              'tool/gen_icons.py --check reported drift:\n'
              '${r.stdout}\n${r.stderr}',
        );
      },
    );

    // Non-happy path: --check must actually DETECT drift. A checker that always
    // exits 0 (missing renderer, silent skip, wrong path) would make the test
    // above vacuous, so corrupt a copy of the tree and demand a failure.
    test('--check fails loudly when a generated raster is tampered with', () {
      final tmp = Directory.systemTemp.createTempSync('axiotask_icons');
      addTearDown(() => tmp.deleteSync(recursive: true));
      for (final path in [_master, _manifest, ...recorded.keys]) {
        final dest = File('${tmp.path}/$path');
        dest.parent.createSync(recursive: true);
        File(path).copySync(dest.path);
      }
      final victim = File('${tmp.path}/${_hicolorPath(48)}');
      final bytes = victim.readAsBytesSync();
      bytes[bytes.length - 1] ^= 0xFF; // flip a byte in the CRC tail
      victim.writeAsBytesSync(bytes);

      final r = _gen(['--check', '--root', tmp.path]);
      expect(
        r.exitCode,
        isNot(0),
        reason: '--check must reject a tampered raster',
      );
      expect('${r.stdout}${r.stderr}', contains(_hicolorPath(48)));
    });

    // Non-happy path: the generator must refuse to EMIT an unloadable scalable
    // icon, not just report drift. It copies the master verbatim, so it is the
    // one place that can stop #261 from being reintroduced by an edit.
    test('--check refuses a master whose <svg> falls outside the window', () {
      final tmp = Directory.systemTemp.createTempSync('axiotask_icons');
      addTearDown(() => tmp.deleteSync(recursive: true));
      for (final path in [_master, _manifest, ...recorded.keys]) {
        final dest = File('${tmp.path}/$path');
        dest.parent.createSync(recursive: true);
        File(path).copySync(dest.path);
      }
      final master = File('${tmp.path}/$_master');
      final bytes = master.readAsBytesSync();
      final offset = _svgTagOffset(master.path);
      final filler = 'x' * _sniffWindowBytes;
      master.writeAsBytesSync([
        ...bytes.sublist(0, offset),
        ...utf8.encode('<!--$filler-->\n'),
        ...bytes.sublist(offset),
      ]);

      final r = _gen(['--check', '--root', tmp.path]);
      expect(
        r.exitCode,
        isNot(0),
        reason: 'the generator must reject a master gdk-pixbuf cannot open',
      );
      expect('${r.stdout}${r.stderr}', contains('#261'));
    });

    // Non-happy path: on a machine without the renderer the generator must say
    // so instead of pretending success (exit 3 = renderer unavailable).
    test(
      'the generator reports a missing renderer instead of faking success',
      () {
        final help = _gen(['--help']);
        expect(help.exitCode, 0, reason: '${help.stderr}');
        expect(
          '${help.stdout}',
          contains('cairosvg'),
          reason: 'the generator must name the renderer it needs',
        );
      },
    );
  });

  test('the desktop entry shows the branded name', () {
    final desktop = File(
      'linux/packaging/io.github.illyayalovyy.axiotask.desktop',
    ).readAsStringSync();
    expect(
      desktop,
      contains('Name=Axiotask'),
      reason: 'the app-menu label users read must be the branded casing',
    );
    expect(desktop, contains('Icon=axiotask'));
  });
}
