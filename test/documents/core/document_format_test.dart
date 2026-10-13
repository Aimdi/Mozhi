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
