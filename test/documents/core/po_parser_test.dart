import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/core/parsers/po_parser.dart';

import '../helpers/document_helpers.dart';

const _template = r'''
# Translation template for Mozhi.
# Copyright (C) 2026
#
#, fuzzy
msgid ""
msgstr ""
"Project-Id-Version: mozhi 1.0\n"
"Report-Msgid-Bugs-To: \n"
"Language-Team: LANGUAGE <LL@li.org>\n"
"Language: \n"
"MIME-Version: 1.0\n"
"Content-Type: text/plain; charset=CHARSET\n"
"Content-Transfer-Encoding: 8bit\n"
"Plural-Forms: nplurals=INTEGER; plural=EXPRESSION;\n"

#. Shown on the start screen
#: lib/main.c:12
#, c-format
msgid "Hello, %s!"
msgstr ""

#: lib/main.c:20
msgctxt "menu"
msgid "Open"
msgstr ""

#: lib/files.c:5
#, c-format
msgid "%d file"
msgid_plural "%d files"
msgstr[0] ""
msgstr[1] ""

msgid ""
"A long text that "
"spans lines.\n"
"Second \"paragraph\"."
msgstr ""

#, fuzzy, python-format
msgid "Saved %(name)s"
msgstr ""

msgid "Already done"
msgstr "Schon erledigt"

#~ msgid "Old"
#~ msgstr "Alt"
''';

void main() {
  group('parsePo', () {
    test('round-trips and lists the untranslated entries', () {
      final document = parsePo(_template, targetLanguage: 'de');
      expect(document.format, DocumentFormat.po);
      expectRoundTrip(document, _template);
      expect(texts(document), [
        'Hello, ⟨1⟩!',
        'Open',
        '⟨1⟩ file',
        '⟨1⟩ files',
        'A long text that spans lines.\nSecond "paragraph".',
        'Saved ⟨1⟩',
      ]);
      expect(document.segments[1].label, 'menu');
    });

    test('writes msgstr, plural forms and the header', () {
      final document = parsePo(_template, targetLanguage: 'de');
      final output = document.render([
        'Hallo, ⟨1⟩! 100%',
        'Öffnen',
        '⟨1⟩ Datei',
        '⟨1⟩ Dateien',
        'Ein langer Text.\nZweiter "Absatz".',
        '⟨1⟩ gespeichert',
      ]);
      expect(
        output,
        contains('msgid "Hello, %s!"\nmsgstr "Hallo, %s! 100%%"\n'),
      );
      expect(output, contains('msgid "Open"\nmsgstr "Öffnen"\n'));
      expect(
        output,
        contains(
          'msgid_plural "%d files"\n'
          'msgstr[0] "%d Datei"\n'
          'msgstr[1] "%d Dateien"\n',
        ),
      );
      expect(
        output,
        contains('msgstr ""\n"Ein langer Text.\\n"\n"Zweiter \\"Absatz\\"."\n'),
      );
      // fuzzy is removed from the entry that was untranslated.
      expect(
        output,
        contains(
          '#, python-format\nmsgid "Saved %(name)s"\n'
          'msgstr "%(name)s gespeichert"\n',
        ),
      );
      expect(output, contains('msgstr "Schon erledigt"'));
      expect(output, contains('#~ msgid "Old"'));
      expect(output, contains('"Language: de\\n"\n'));
      expect(output, contains(r'charset=UTF-8\n"'));
      expect(
        output,
        contains(r'"Plural-Forms: nplurals=2; plural=(n != 1);\n"'),
      );
      // The header keeps its own fuzzy flag.
      expect(output, startsWith('# Translation template for Mozhi.\n'));
      expect(output, contains('#, fuzzy\nmsgid ""\nmsgstr ""\n'));
    });

    test('uses the plural rule of the target language', () {
      final document = parsePo(_template, targetLanguage: 'ru');
      final output = document.render([
        null,
        null,
        '⟨1⟩ файл',
        '⟨1⟩ файлов',
        null,
        null,
      ]);
      expect(
        output,
        contains(
          'msgstr[0] "%d файл"\nmsgstr[1] "%d файлов"\nmsgstr[2] "%d файлов"\n',
        ),
      );
      expect(output, contains('nplurals=3;'));

      final japanese = parsePo(_template, targetLanguage: 'ja');
      expect(
        japanese.render([null, null, '⟨1⟩ 個', '⟨1⟩ 個のファイル', null, null]),
        contains('msgid_plural "%d files"\nmsgstr[0] "%d 個のファイル"\n\n'),
      );
    });

    test('keeps translations of the same language, redoes other ones', () {
      const catalogue =
          'msgid ""\n'
          'msgstr ""\n'
          '"Language: de_DE\\n"\n'
          '"Plural-Forms: nplurals=2; plural=(n != 1);\\n"\n'
          '\n'
          'msgid "Yes"\n'
          'msgstr "Ja"\n'
          '\n'
          'msgid "No"\n'
          'msgstr ""\n';
      final same = parsePo(catalogue, targetLanguage: 'de');
      expect(texts(same), ['No']);
      final other = parsePo(catalogue, targetLanguage: 'fr');
      expect(texts(other), ['Yes', 'No']);
      final output = other.render(['Oui', 'Non']);
      expect(output, contains('msgid "Yes"\nmsgstr "Oui"\n'));
      expect(output, contains(r'"Language: fr\n"'));
      expect(output, contains('nplurals=2; plural=(n > 1);'));
    });

    test('adds a header when there is none, keeps CRLF', () {
      const catalogue = 'msgid "Hello"\r\nmsgstr ""\r\n';
      final document = parsePo(catalogue, targetLanguage: 'pt-BR');
      expectRoundTrip(document, catalogue);
      final output = document.render(['Olá']);
      expect(
        output,
        startsWith(
          'msgid ""\r\nmsgstr ""\r\n"Language: pt_BR\\n"\r\n'
          '"MIME-Version: 1.0\\n"\r\n',
        ),
      );
      expect(output, endsWith('msgid "Hello"\r\nmsgstr "Olá"\r\n'));
    });

    test('rejects lines that are not PO', () {
      expect(
        () => parsePo('msgid "a"\nmsgstr ""\nhello\n'),
        throwsA(isA<DocumentParseException>()),
      );
      expect(
        () => parsePo('msgid "a\n'),
        throwsA(isA<DocumentParseException>()),
      );
      expect(
        () => parsePo('msgid "a"\n'),
        throwsA(isA<DocumentParseException>()),
      );
      expect(
        () => parsePo('msgid "a"\nmsgstr[0] ""\n'),
        throwsA(isA<DocumentParseException>()),
      );
    });
  });

  group('parsePo (more)', () {
    test('decodes escapes and keeps entries without blank lines apart', () {
      const catalogue =
          '\uFEFFmsgid "Tab\\there \\x41\\101 \\a\\b\\f\\v\\q\\x"\n'
          'msgstr ""\n'
          '# comment right after\n'
          'msgid "Second"\n'
          'msgstr ""\n'
          'msgctxt "ctx"\n'
          'msgid "Third"\n'
          'msgstr ""\n';
      final document = parsePo(catalogue);
      expectRoundTrip(document, catalogue);
      expect(texts(document), ['Tab\there AA \x07\b\f\vqx', 'Second', 'Third']);
      final output = document.render(['Tab\tda', 'Zweite', 'Dritte']);
      // A header is added after the byte order mark.
      expect(output, startsWith('\uFEFFmsgid ""\nmsgstr ""\n'));
      expect(output, isNot(contains('Language:')));
      expect(output, contains('msgstr "Tab\\tda"\n# comment right after\n'));
      expect(
        output,
        contains('msgctxt "ctx"\nmsgid "Third"\nmsgstr "Dritte"\n'),
      );
    });

    test('handles Qt and brace formats and catalogues keyed by ids', () {
      const catalogue =
          'msgid ""\n'
          'msgstr "Language: en\\nContent-Type: text/plain; charset=UTF-8\\n"\n'
          '\n'
          '#, qt-format\n'
          'msgid "Copy %1 to %2"\n'
          'msgstr ""\n'
          '\n'
          '#, python-brace-format\n'
          'msgid "Hello {name}"\n'
          'msgstr ""\n'
          '\n'
          'msgid "app.title"\n'
          'msgstr "My application"\n';
      final document = parsePo(catalogue, targetLanguage: 'de');
      expectRoundTrip(document, catalogue);
      expect(texts(document), [
        'Copy ⟨1⟩ to ⟨2⟩',
        'Hello ⟨1⟩',
        'My application',
      ]);
      final output = document.render([
        'Kopiere ⟨1⟩ nach ⟨2⟩',
        'Hallo ⟨1⟩ {sic}',
        'Meine Anwendung',
      ]);
      expect(output, contains('msgstr "Kopiere %1 nach %2"'));
      expect(output, contains('msgstr "Hallo {name} {{sic}}"'));
      expect(output, contains('msgid "app.title"\nmsgstr "Meine Anwendung"'));
      // A header written on one line is rewritten one field per line.
      expect(
        output,
        startsWith(
          'msgid ""\nmsgstr ""\n"Language: de\\n"\n'
          '"Content-Type: text/plain; charset=UTF-8\\n"\n'
          '"Plural-Forms: nplurals=2; plural=(n != 1);\\n"\n\n',
        ),
      );
    });

    test('inserts a missing Language field after the team', () {
      const catalogue =
          'msgid ""\n'
          'msgstr ""\n'
          '"Language-Team: German\\n"\n'
          '"MIME-Version: 1.0\\n"\n'
          '\n'
          'msgid "Hi"\n'
          'msgstr ""';
      final document = parsePo(catalogue, targetLanguage: 'de');
      final output = document.render(['Hallo']);
      expect(
        output,
        contains(
          '"Language-Team: German\\n"\n"Language: de\\n"\n'
          '"MIME-Version: 1.0\\n"\n',
        ),
      );
      expect(output, endsWith('msgid "Hi"\nmsgstr "Hallo"'));
    });

    test('rejects more malformed catalogues', () {
      for (final bad in [
        '"orphan string"\n',
        'msgstr ""\n',
        'msgid "a"\nmsgstr "b"\nmsgid_plural "c"\n',
        'msgid "a\\"\nmsgstr ""\n',
        'msgid "a"b"\nmsgstr ""\n',
        'msgid "a" "b"\nmsgstr ""\n',
      ]) {
        expect(
          () => parsePo(bad),
          throwsA(isA<DocumentParseException>()),
          reason: bad,
        );
      }
    });
  });

  test('changes the header only when something is translated', () {
    const done =
        'msgid ""\n'
        'msgstr ""\n'
        '"Language: de\\n"\n'
        '\n'
        'msgid "Yes\\r"\n'
        'msgstr "Ja"\n';
    final translated = parsePo(done, targetLanguage: 'fr-FR');
    expect(translated.isEmpty, isFalse);
    final keep = parsePo(done, targetLanguage: 'de');
    expect(keep.isEmpty, isTrue);
    expect(keep.render(), done);
    const current =
        'msgid ""\n'
        'msgstr ""\n'
        '"Language: de\\n"\n'
        '"Content-Type: text/plain; charset=UTF-8\\n"\n'
        '"Plural-Forms: nplurals=2; plural=(n != 1);\\n"\n'
        '\n'
        'msgid "No"\n'
        'msgstr ""\n';
    final document = parsePo(current, targetLanguage: 'de');
    expect(
      document.render(['Nein']),
      current
          .replaceFirst('msgstr ""\n', 'msgstr ""\n')
          .replaceFirst(RegExp(r'msgstr ""\n$'), 'msgstr "Nein"\n'),
    );
    expect(
      () => parsePo('msgid "a"\nmsgstr[0] ""\nmsgid_plural "b"\n'),
      throwsA(isA<DocumentParseException>()),
    );
  });
}
