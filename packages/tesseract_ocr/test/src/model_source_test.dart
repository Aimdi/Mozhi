import 'package:flutter_test/flutter_test.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart';

void main() {
  final language = TessdataLanguage(
    code: 'chi_sim',
    name: 'Chinese (Simplified)',
    languages: const ['zh-CN'],
    url: Uri.parse(
      'https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/'
      '0123456789abcdef/chi_sim.traineddata',
    ),
    size: 10,
    sha256: 'a' * 64,
  );

  group(tessdataMirrorUrl, () {
    test('puts the file under tesseract/ with its published name', () {
      for (final base in [
        'https://example.org/models/',
        'https://example.org/models',
      ]) {
        expect(
          tessdataMirrorUrl(Uri.parse(base), language).toString(),
          'https://example.org/models/tesseract/chi_sim.traineddata',
          reason: base,
        );
      }
      expect(
        tessdataMirrorUrl(Uri.parse('http://nas.local'), language).toString(),
        'http://nas.local/tesseract/chi_sim.traineddata',
      );
    });

    test('rejects what is not an http(s) base URL', () {
      for (final base in [
        'ftp://example.org/',
        '//example.org/',
        'https://example.org/?x=1',
        'https://example.org/#x',
      ]) {
        expect(
          () => tessdataMirrorUrl(Uri.parse(base), language),
          throwsArgumentError,
          reason: base,
        );
      }
    });
  });

  group(tessdataDownloadUrls, () {
    final mirror = Uri.parse('https://mirror.test/');
    final copy = tessdataMirrorUrl(mirror, language);

    test('is the catalog URL without a mirror', () {
      expect(tessdataDownloadUrls(language), [language.url]);
      expect(tessdataDownloadUrls(language, fallbackToDefault: true), [
        language.url,
      ]);
    });

    test('is the mirror copy, then the catalog URL with the fallback', () {
      expect(tessdataDownloadUrls(language, mirror: mirror), [copy]);
      expect(
        tessdataDownloadUrls(language, mirror: mirror, fallbackToDefault: true),
        [copy, language.url],
      );
    });
  });

  test('the mirror folder', () => expect(tessdataMirrorFolder, 'tesseract'));
}
