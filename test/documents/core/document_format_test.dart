import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';

void main() {
  group('DocumentFormat', () {
    test('detects formats from file names', () {
      expect(
        DocumentFormat.fromFileName('notes.TXT'),
        DocumentFormat.plainText,
      );
      expect(DocumentFormat.fromFileName('README.md'), DocumentFormat.markdown);
      expect(
        DocumentFormat.fromFileName('a.markdown'),
        DocumentFormat.markdown,
      );
      expect(DocumentFormat.fromFileName('movie.en.srt'), DocumentFormat.srt);
      expect(DocumentFormat.fromFileName('captions.vtt'), DocumentFormat.vtt);
      expect(DocumentFormat.fromFileName('en.json'), DocumentFormat.json);
      expect(DocumentFormat.fromFileName('app_en.arb'), DocumentFormat.json);
      expect(DocumentFormat.fromFileName('photo.png'), isNull);
      expect(DocumentFormat.fromFileName('noextension'), isNull);
      expect(DocumentFormat.fromFileName('trailing.'), isNull);
    });

    test('lists all extensions and flags', () {
      expect(
        DocumentFormat.allExtensions,
        containsAll(['txt', 'md', 'srt', 'vtt', 'json', 'arb']),
      );
      expect(DocumentFormat.srt.isSubtitle, isTrue);
      expect(DocumentFormat.vtt.supportsBilingual, isTrue);
      expect(DocumentFormat.json.supportsBilingual, isFalse);
      expect(DocumentFormat.srt.mimeType, 'application/x-subrip');
      expect(DocumentFormat.markdown.defaultExtension, 'md');
    });

    test('sniffs pasted text', () {
      expect(
        DocumentFormat.sniff('WEBVTT\n\n00:01.000 --> 00:02.000\nHi'),
        DocumentFormat.vtt,
      );
      expect(
        DocumentFormat.sniff('\uFEFF1\r\n00:00:01,000 --> 00:00:02,000\nHi'),
        DocumentFormat.srt,
      );
      expect(DocumentFormat.sniff('{"a": "b"}'), DocumentFormat.json);
      expect(DocumentFormat.sniff('[1, 2]'), DocumentFormat.json);
      expect(DocumentFormat.sniff('{not json'), DocumentFormat.plainText);
      expect(DocumentFormat.sniff('# Title\n\nText'), DocumentFormat.markdown);
      expect(
        DocumentFormat.sniff('Some `code` and a [link](http://x.y).'),
        DocumentFormat.markdown,
      );
      expect(DocumentFormat.sniff('- one\n- two'), DocumentFormat.markdown);
      expect(
        DocumentFormat.sniff('Just a sentence.\n\nAnother - one.'),
        DocumentFormat.plainText,
      );
    });
  });

  group('DocumentFormat.sniff (localisation and web formats)', () {
    test('recognises HTML documents and fragments', () {
      expect(
        DocumentFormat.sniff('<!DOCTYPE html>\n<html><body>Hi</body></html>'),
        DocumentFormat.html,
      );
      expect(
        DocumentFormat.sniff('  <!doctype HTML><p>Hi</p>'),
        DocumentFormat.html,
      );
      expect(
        DocumentFormat.sniff('<html lang="en"><head></head></html>'),
        DocumentFormat.html,
      );
      expect(
        DocumentFormat.sniff(
          '<?xml version="1.0"?>\n<!-- page -->\n'
          '<html xmlns="http://www.w3.org/1999/xhtml"></html>',
        ),
        DocumentFormat.html,
      );
      expect(
        DocumentFormat.sniff('<p>Hello <b>world</b></p>'),
        DocumentFormat.html,
      );
      expect(DocumentFormat.sniff('<div>Line<br>Two'), DocumentFormat.html);
    });

    test('recognises XLIFF, Android strings, PO and string catalogues', () {
      expect(
        DocumentFormat.sniff(
          '\uFEFF<?xml version="1.0" encoding="UTF-8"?>\n'
          '<xliff version="1.2"><file></file></xliff>',
        ),
        DocumentFormat.xliff,
      );
      expect(
        DocumentFormat.sniff(
          '<xliff xmlns="urn:oasis:names:tc:xliff:document:2.0"/>',
        ),
        DocumentFormat.xliff,
      );
      expect(
        DocumentFormat.sniff(
          '<?xml version="1.0" encoding="utf-8"?>\n<!-- strings -->\n'
          '<resources>\n  <string name="a">A</string>\n</resources>',
        ),
        DocumentFormat.androidStrings,
      );
      expect(
        DocumentFormat.sniff(
          '# Comment\n#, fuzzy\nmsgid ""\nmsgstr ""\n"Language: de\\n"\n\n'
          'msgid "Hello"\nmsgstr ""\n',
        ),
        DocumentFormat.po,
      );
      expect(
        DocumentFormat.sniff('msgid "a"\nmsgid_plural "b"\nmsgstr[0] ""'),
        DocumentFormat.po,
      );
      expect(
        DocumentFormat.sniff(
          '{"sourceLanguage": "en", "strings": {"Hi": {}}, "version": "1.0"}',
        ),
        DocumentFormat.xcstrings,
      );
      expect(
        DocumentFormat.sniff('{"strings": {"a": "b"}}'),
        DocumentFormat.json,
      );
    });

    test('recognises Apple strings and pasted spreadsheet cells', () {
      expect(
        DocumentFormat.sniff(
          '/* Title */\n"title" = "Hello";\n// note\n"bye" = "Bye \\"x\\"";\n',
        ),
        DocumentFormat.appleStrings,
      );
      expect(
        DocumentFormat.sniff('Name\tPrice\nChair\t19\nTable\t149\n'),
        DocumentFormat.tsv,
      );
    });

    test('does not mistake Markdown or plain text for them', () {
      for (final text in [
        '# Readme\n\n<p align="center"><img src="logo.png"></p>\n\nText.',
        '<3 you\nsee you soon',
        '<unknown>tag</unknown>',
        '<?xml version="1.0"?><svg></svg>',
        'Use the <b> tag for bold.',
        'The msgid "x" line in a sentence.',
        '"Quoted" = "maybe";\nBut then prose.',
        '\tindented\n\tlines',
        'one\ttwo\nthree',
        'Just a sentence.\n\nAnother - one.',
      ]) {
        expect(
          DocumentFormat.sniff(text),
          anyOf(DocumentFormat.plainText, DocumentFormat.markdown),
          reason: text,
        );
      }
    });

    test('flags the formats that record the target language', () {
      for (final format in [
        DocumentFormat.xliff,
        DocumentFormat.po,
        DocumentFormat.xcstrings,
        DocumentFormat.html,
      ]) {
        expect(format.usesTargetLanguage, isTrue, reason: '$format');
      }
      for (final format in [
        DocumentFormat.androidStrings,
        DocumentFormat.csv,
        DocumentFormat.tsv,
        DocumentFormat.appleStrings,
        DocumentFormat.json,
      ]) {
        expect(format.usesTargetLanguage, isFalse, reason: '$format');
      }
      expect(DocumentFormat.fromFileName('page.xhtml'), DocumentFormat.html);
      expect(DocumentFormat.fromFileName('app.xlf'), DocumentFormat.xliff);
      expect(DocumentFormat.fromFileName('de.po'), DocumentFormat.po);
      expect(DocumentFormat.fromFileName('app.pot'), DocumentFormat.po);
      expect(
        DocumentFormat.fromFileName('strings.xml'),
        DocumentFormat.androidStrings,
      );
      expect(
        DocumentFormat.fromFileName('Localizable.strings'),
        DocumentFormat.appleStrings,
      );
      expect(
        DocumentFormat.fromFileName('Localizable.xcstrings'),
        DocumentFormat.xcstrings,
      );
      expect(DocumentFormat.fromFileName('data.tab'), DocumentFormat.tsv);
    });
  });

  group('translatedFileName', () {
    test('inserts the language code before the extension', () {
      expect(translatedFileName('movie.srt', .srt, 'es'), 'movie.es.srt');
      expect(
        translatedFileName('/a/b/notes.txt', .plainText, 'de'),
        'notes.de.txt',
      );
      expect(translatedFileName(r'C:\docs\x.md', .markdown, 'fr'), 'x.fr.md');
      expect(translatedFileName('README', .markdown, 'fr'), 'README.fr.md');
    });

    test('replaces an existing language code', () {
      expect(
        translatedFileName('movie.en.srt', .srt, 'pt-BR'),
        'movie.pt-BR.srt',
      );
      expect(translatedFileName('app_en.arb', .json, 'pt-BR'), 'app_pt_BR.arb');
      expect(translatedFileName('intl_pt_BR.arb', .json, 'de'), 'intl_de.arb');
      expect(translatedFileName('en.json', .json, 'ja'), 'ja.json');
      expect(
        translatedFileName('en-US.json', .json, 'zh-Hant'),
        'zh-Hant.json',
      );
      expect(translatedFileName('strings.arb', .json, 'de'), 'strings.de.arb');
      expect(translatedFileName('config.json', .json, 'de'), 'config.de.json');
    });

    test('names pasted text and slugs custom languages', () {
      expect(translatedFileName(null, .vtt, 'it'), 'translation.it.vtt');
      expect(translatedFileName('  ', .json, 'it'), 'translation.it.json');
      expect(
        translatedFileName('a.txt', .plainText, 'Pirate speak!'),
        'a.pirate-speak.txt',
      );
      expect(
        translatedFileName('a.txt', .plainText, '???'),
        'a.translated.txt',
      );
    });
  });
}
