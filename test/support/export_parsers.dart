// Independent readers for current-view exports, so tests compare what a
// consumer would parse back rather than re-implementing the writer.

/// Parses RFC 4180 [text] into records of fields. Quoted fields may hold
/// commas, doubled quotes and line breaks. Throws [FormatException] on a
/// malformed document, including a stray quote in a bare field.
List<List<String>> parseCsv(String text) {
  final records = <List<String>>[];
  var record = <String>[];
  final field = StringBuffer();
  var index = 0;
  var quoted = false;
  var fieldStarted = false;
  while (index < text.length) {
    final char = text[index];
    if (quoted) {
      if (char == '"') {
        if (index + 1 < text.length && text[index + 1] == '"') {
          field.write('"');
          index += 2;
          continue;
        }
        quoted = false;
        index += 1;
        if (index < text.length && !',\n\r'.contains(text[index])) {
          throw FormatException('Text after a closing quote', text, index);
        }
        continue;
      }
      field.write(char);
      index += 1;
      continue;
    }
    switch (char) {
      case '"':
        if (fieldStarted) {
          throw FormatException('Quote inside a bare field', text, index);
        }
        quoted = true;
        fieldStarted = true;
        index += 1;
      case ',':
        record.add(field.toString());
        field.clear();
        fieldStarted = false;
        index += 1;
      case '\r' || '\n':
        record.add(field.toString());
        field.clear();
        fieldStarted = false;
        records.add(record);
        record = <String>[];
        index +=
            char == '\r' && index + 1 < text.length && text[index + 1] == '\n'
            ? 2
            : 1;
      default:
        field.write(char);
        fieldStarted = true;
        index += 1;
    }
  }
  if (quoted) throw FormatException('Unterminated quoted field', text);
  if (fieldStarted || record.isNotEmpty) {
    record.add(field.toString());
    records.add(record);
  }
  return records;
}

/// One checklist item read back from an exported Markdown document.
final class MarkdownExportItem {
  MarkdownExportItem({
    required this.depth,
    required this.checked,
    required this.title,
    required this.dueLabel,
  });

  /// 0 for a top-level task, 1 for a subtask.
  final int depth;
  final bool checked;

  /// The title after removing backslash escapes.
  final String title;

  /// The absolute date label after ` — `, if any.
  final String? dueLabel;

  /// Notes lines after removing backslash escapes and indentation.
  final List<String> notes = <String>[];

  @override
  String toString() =>
      '${'  ' * depth}[${checked ? 'x' : ' '}] $title'
      '${dueLabel == null ? '' : ' — $dueLabel'} $notes';
}

/// A Markdown export read back: its heading, items and whether it declared
/// itself empty.
final class MarkdownExport {
  MarkdownExport(this.heading, this.items, {required this.declaredEmpty});

  final String heading;
  final List<MarkdownExportItem> items;
  final bool declaredEmpty;
}

final _item = RegExp(r'^( *)- \[( |x)\] (.*)$');

/// Reads an exported Markdown checklist. Fails on any line that is not the
/// heading, a blank, an item, an item's indented note, or the empty marker,
/// so stray markup or an unindented note is caught.
MarkdownExport parseMarkdownExport(String text) {
  final lines = text.split('\n');
  if (!lines.first.startsWith('# ')) {
    throw FormatException('Missing heading', text);
  }
  final heading = unescapeMarkdown(lines.first.substring(2));
  final items = <MarkdownExportItem>[];
  var declaredEmpty = false;
  for (final line in lines.skip(1)) {
    if (line.isEmpty) continue;
    if (line == '_No tasks._') {
      declaredEmpty = true;
      continue;
    }
    final match = _item.firstMatch(line);
    if (match != null) {
      final indent = match[1]!.length;
      if (indent != 0 && indent != 2) {
        throw FormatException('Unexpected nesting', line);
      }
      final content = match[3]!;
      final split = content.lastIndexOf(' — ');
      items.add(
        MarkdownExportItem(
          depth: indent ~/ 2,
          checked: match[2] == 'x',
          title: unescapeMarkdown(
            split < 0 ? content : content.substring(0, split),
          ),
          dueLabel: split < 0 ? null : content.substring(split + 3),
        ),
      );
      continue;
    }
    if (items.isEmpty) throw FormatException('Text before any item', line);
    final indent = '  ' * (items.last.depth + 1);
    if (!line.startsWith(indent) ||
        line.substring(indent.length).startsWith(' ')) {
      throw FormatException('Note not indented under its item', line);
    }
    items.last.notes.add(unescapeMarkdown(line.substring(indent.length)));
  }
  return MarkdownExport(heading, items, declaredEmpty: declaredEmpty);
}

/// Removes CommonMark backslash escapes (a backslash before ASCII
/// punctuation).
String unescapeMarkdown(String value) => value.replaceAllMapped(
  RegExp(r'''\\([!"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~])'''),
  (match) => match[1]!,
);

/// Characters that are markup when they appear unescaped in inline text.
final unescapedMarkup = RegExp(r'(?<!\\)(?:\\\\)*[`*_\[\]<>&~|!]');
