import 'package:axiotask/src/domain/policy/task_links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('task content links', () {
    test('extracts distinct absolute http and https links from plain text', () {
      final links = TaskLinkPolicy.userAuthoredLinks(
        title: 'Read https://docs.example.test/guide.',
        notes:
            'Mirror: http://example.test/a?b=1#part\n'
            'Again https://docs.example.test/guide',
      );

      expect(links, <Uri>[
        Uri.parse('https://docs.example.test/guide'),
        Uri.parse('http://example.test/a?b=1#part'),
      ]);
    });

    test('rejects unsupported schemes and malformed candidates', () {
      final links = TaskLinkPolicy.userAuthoredLinks(
        title: 'mailto:user@example.test javascript:alert(1)',
        notes:
            'file:///tmp/private ftp://example.test '
            'https:///missing-host https://example.test/%zz',
      );

      expect(links, isEmpty);
    });

    test('trims sentence punctuation and balanced presentation delimiters', () {
      final links = TaskLinkPolicy.userAuthoredLinks(
        title: '(https://example.test/inside),',
        notes: 'https://example.test/path_(part).',
      );

      expect(links, <Uri>[
        Uri.parse('https://example.test/inside'),
        Uri.parse('https://example.test/path_(part)'),
      ]);
    });
  });

  group('Google task links', () {
    test('accepts a validated Google Tasks HTTPS webViewLink', () {
      expect(
        TaskLinkPolicy.googleTaskLink(
          Uri.parse('https://tasks.google.com/task/synthetic-task'),
        ),
        Uri.parse('https://tasks.google.com/task/synthetic-task'),
      );
    });

    test('rejects absent, malformed, non-HTTPS, and non-Google links', () {
      expect(TaskLinkPolicy.googleTaskLink(null), isNull);
      expect(
        TaskLinkPolicy.googleTaskLink(Uri.parse('ftp://tasks.google.com/a')),
        isNull,
      );
      expect(
        TaskLinkPolicy.googleTaskLink(Uri.parse('http://tasks.google.com/a')),
        isNull,
      );
      expect(
        TaskLinkPolicy.googleTaskLink(Uri.parse('https:///missing-host')),
        isNull,
      );
      expect(
        TaskLinkPolicy.googleTaskLink(Uri.parse('https://example.test/a')),
        isNull,
      );
      expect(
        TaskLinkPolicy.googleTaskLink(
          Uri.parse('https://tasks.google.com:8443/task/a'),
        ),
        isNull,
      );
    });
  });
}
