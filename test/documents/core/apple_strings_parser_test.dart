// Markup fixtures are built from adjacent strings.
// ignore_for_file: missing_whitespace_between_adjacent_strings
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/core/parsers/apple_strings_parser.dart';

import '../helpers/document_helpers.dart';

void main() {
  group('parseAppleStrings', () {
    const strings = r'''
/* Title of the main window */
"window.title" = "Welcome";

// A greeting
"greeting" = "Hello, %@!";
"count"="%lld items, 100%% done";
"quote" = "Say \"hi\"\nthen leave";
"unicode" = "Caf\U00E9";
unquoted_key = "Open file";
"empty" = "";
"key only";
''';

    test('round-trips and translates the values', () {
      final document = parseAppleStrings(strings);
      expect(document.format, DocumentFormat.appleStrings);
      expectRoundTrip(document, strings);
      expect(texts(document), [
        'Welcome',
        'Hello, ⟨1⟩!',
        '⟨1⟩ items, 100⟨2⟩ done',
        'Say "hi"⟨1⟩then leave',
        'Café',
        'Open file',
      ]);
      expect(document.segments[1].label, 'greeting');
    });

    test('escapes translations', () {
      final document = parseAppleStrings(strings);
      final output = document.render([
        'Bienvenue',
        'Bonjour ⟨1⟩, salut !',
        '⟨1⟩ éléments, 100⟨2⟩ fini (50 %)',
        'Dis "salut"⟨1⟩puis pars',
        'Café',
        r'Ouvrir le fichier C:\',
      ]);
      expect(output, contains('"window.title" = "Bienvenue";'));
      expect(output, contains('"greeting" = "Bonjour %@, salut !";'));
      expect(output, contains('"count"="%lld éléments, 100%% fini (50 %%)";'));
      expect(output, contains(r'"quote" = "Dis \"salut\"\npuis pars";'));
      expect(output, contains(r'"unicode" = "Caf\U00E9";'));
      expect(output, contains(r'unquoted_key = "Ouvrir le fichier C:\\";'));
      expect(output, contains('/* Title of the main window */'));
    });

    test('keeps UTF-16 text with a byte order mark', () {
      const text = '\uFEFF"a" = "Good night";\r\n';
      final document = parseAppleStrings(text);
      expectRoundTrip(document, text);
      expect(document.render(['Bonne nuit']), '\uFEFF"a" = "Bonne nuit";\r\n');
    });

    test('rejects malformed files and property lists', () {
      for (final bad in [
        '"a" "b";',
        '"a" = "b"',
        '"a = "b";',
        '/* open',
        '"a" = ;',
        '<?xml version="1.0"?><plist></plist>',
      ]) {
        expect(
          () => parseAppleStrings(bad),
          throwsA(isA<DocumentParseException>()),
          reason: bad,
        );
      }
    });
  });

  test('keeps unquoted values, invisible and octal escapes', () {
    const text = '"a" = b;\n"c" = "Tab\\U0009here \\012 ok";\n';
    final document = parseAppleStrings(text);
    expectRoundTrip(document, text);
    expect(texts(document), ['Tab⟨1⟩here ⟨2⟩ ok']);
  });
}
