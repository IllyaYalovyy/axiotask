// Repository and packaging layer — the surfaces that ask people to sponsor
// the project.
//
// What this protects (and the failures it prevents):
//   - NO BUTTON AT ALL: GitHub only renders the Sponsor button when it finds a
//     FUNDING.yml in the repository ROOT, `.github/` or `docs/`. A file tidied
//     into any other directory is silently ignored — the repo looks unfunded and
//     nobody notices, because nothing errors.
//   - WRONG / TYPO'D ACCOUNT: GitHub drops a `github:` entry naming an account
//     that does not exist, again silently. A typo costs the button; a different
//     valid account sends money to a stranger.
//   - HALF-UNCOMMENTED TEMPLATE: GitHub's FUNDING.yml template ships every
//     platform key commented out. Uncommenting one and leaving it blank
//     (`patreon:`) yields an entry with no value — GitHub rejects the file and
//     the button disappears, taking the working `github:` entry with it.
//   - NO DONATE BUTTON IN SOFTWARE CENTRES: GNOME Software and KDE Discover
//     render a native Donate affordance only from `<url type="donation">` in
//     the AppStream metainfo. Without that element the Linux app page has no
//     way to sponsor at all, and — as with FUNDING.yml — nothing errors.
//   - SURFACE DRIFT: the README badge, the Sponsor button and the metainfo
//     donation URL are three separate declarations of the same account.
//     Renaming the account in one place only points some readers at a 404.
//
// Pure file reads — no clock, no network, no build.
@Tags(['packaging'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The account that receives sponsorships: the repository owner
/// (github.com/IllyaYalovyy/axiotask). Stated here so the TEST, not the config,
/// defines truth — a rename must be a deliberate edit in both places.
const String _sponsorAccount = 'IllyaYalovyy';

/// Where the Sponsor button links once GitHub has read the config.
const String _sponsorUrl = 'https://github.com/sponsors/$_sponsorAccount';

/// The AppStream metainfo shipped by the Linux packaging (#226) — installed
/// verbatim by both tool/install.sh and the RPM, so what it declares here is
/// what a software centre shows.
const String _metainfoPath =
    'linux/packaging/io.github.illyayalovyy.axiotask.metainfo.xml';

/// The three locations GitHub searches, in its documented order.
const List<String> _searchedPaths = <String>[
  'FUNDING.yml',
  '.github/FUNDING.yml',
  'docs/FUNDING.yml',
];

void main() {
  group('FUNDING.yml (the GitHub Sponsors button)', () {
    test('lives where GitHub looks for it', () {
      final present = _searchedPaths
          .where((p) => File(p).existsSync())
          .toList();
      expect(
        present,
        contains('.github/FUNDING.yml'),
        reason:
            'GitHub reads FUNDING.yml only from the repo root, .github/ or '
            'docs/. Found: $present',
      );
    });

    test('names the sponsored account', () {
      final entries = _fundingEntries();
      expect(
        entries['github'],
        _sponsorAccount,
        reason:
            'the `github:` entry is what renders the Sponsor button; entries '
            'read: $entries',
      );
    });

    test('declares no platform key without a value', () {
      final entries = _fundingEntries();
      expect(entries, isNotEmpty, reason: 'nothing to check — file missing?');
      final blank = entries.entries
          .where((e) => e.value.isEmpty)
          .map((e) => e.key)
          .toList();
      expect(
        blank,
        isEmpty,
        reason:
            'a key with an empty value (the uncommented template default) '
            'invalidates the whole file and removes the button',
      );
    });
  });

  group('README sponsor badge', () {
    late String readme;

    setUpAll(() => readme = File('README.md').readAsStringSync());

    test('shows a badge image linking to the sponsors page', () {
      final badge = RegExp(
        r'\[!\[[^\]]*\]\([^)]+\)\]\(' + RegExp.escape(_sponsorUrl) + r'\)',
      );
      expect(
        badge.hasMatch(readme),
        isTrue,
        reason:
            'expected a markdown image link (a badge, not bare link text) '
            'pointing at $_sponsorUrl',
      );
    });

    test('points at the same account as FUNDING.yml', () {
      final others = RegExp(
        r'github\.com/sponsors/([A-Za-z0-9-]+)',
      ).allMatches(readme).map((m) => m.group(1)!).toSet();
      expect(others, <String>{
        _fundingEntries()['github']!,
      }, reason: 'README and FUNDING.yml must name one account, not two');
    });
  });

  // #240: the Linux surface. A software centre has no README and no GitHub
  // page — the only sponsorship affordance it can offer comes from the
  // metainfo's donation URL.
  group('AppStream metainfo donation URL', () {
    late String xml;

    setUpAll(() => xml = File(_metainfoPath).readAsStringSync());

    test('declares the sponsors page as the donation url', () {
      expect(
        xml,
        contains('<url type="donation">$_sponsorUrl</url>'),
        reason:
            'GNOME Software / KDE Discover render a Donate button only from '
            '<url type="donation">; it must carry the exact sponsors URL '
            '$_sponsorUrl',
      );
    });

    // Non-happy path: the element is there but names somebody else, or the
    // file grew a second donation URL. Both keep appstreamcli quiet enough to
    // ship while sending money to the wrong page — or to whichever of two
    // entries the centre happens to read first.
    test(
      'declares exactly one donation url, and no other sponsors account',
      () {
        final donations = RegExp(
          r'<url type="donation">([^<]+)</url>',
        ).allMatches(xml).map((m) => m.group(1)!).toList();
        expect(donations, <String>[
          _sponsorUrl,
        ], reason: 'expected one donation url naming $_sponsorAccount');

        final accounts = RegExp(
          r'github\.com/sponsors/([A-Za-z0-9-]+)',
        ).allMatches(xml).map((m) => m.group(1)!).toSet();
        expect(accounts, <String>{
          _fundingEntries()['github']!,
        }, reason: 'metainfo and FUNDING.yml must name one account, not two');
      },
    );
  });
}

/// The uncommented `key: value` pairs of `.github/FUNDING.yml`, values trimmed
/// of quotes and list brackets. Deliberately line-based: FUNDING.yml is a flat
/// one-level mapping, so this needs no YAML dependency.
Map<String, String> _fundingEntries() {
  final file = File('.github/FUNDING.yml');
  if (!file.existsSync()) return const <String, String>{};
  final entries = <String, String>{};
  for (final raw in file.readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final colon = line.indexOf(':');
    expect(
      colon,
      greaterThan(0),
      reason: 'not a `key: value` line in .github/FUNDING.yml: "$raw"',
    );
    entries[line.substring(0, colon).trim()] = line
        .substring(colon + 1)
        .trim()
        .replaceAll(RegExp(r'''^[\['"]+|[\]'"]+$'''), '');
  }
  return entries;
}
