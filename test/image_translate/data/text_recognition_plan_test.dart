import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_ocr.dart';
import '../helpers/helpers.dart';

void main() {
  late FakeOcrData data;

  setUp(() => data = FakeOcrData());

  Future<TextRecognitionPlan> plan(
    Language source, {
    List<String> preferred = const [],
  }) => planTextRecognition(data, source: source, preferred: preferred);

  group('a specific source', () {
    test('reads with its data when installed', () async {
      data.installed = {'deu': 1, 'eng': 1};
      expect(await plan(german), const TextRecognitionReady(['deu']));
    });

    test('offers its data when missing', () async {
      expect(
        await plan(german),
        const TextRecognitionNeedsData(OcrDataMissingException(deuOcr)),
      );
    });

    test('is unsupported without data, or for a custom language', () async {
      expect(
        await plan(const Language(code: 'xh', name: 'Xhosa')),
        const TextRecognitionUnsupported(),
      );
      expect(
        await plan(const Language.custom('Pirate speak')),
        const TextRecognitionUnsupported(),
      );
    });
  });

  group('Detect language', () {
    test('reads with the installed languages, preferred first, then '
        'English, at most three', () async {
      data.installed = {'chi_sim': 1, 'deu': 1, 'eng': 1, 'fra': 1, 'jpn': 1};
      expect(
        await plan(Language.auto, preferred: const ['ja', 'fr', 'ja']),
        const TextRecognitionReady(['jpn', 'fra', 'eng']),
      );
      expect(
        await plan(Language.auto),
        const TextRecognitionReady(['eng', 'chi_sim', 'deu']),
      );
    });

    test('skips preferred languages that are not installed', () async {
      data.installed = {'fra': 1};
      expect(
        await plan(Language.auto, preferred: const ['de', 'xx']),
        const TextRecognitionReady(['fra']),
      );
    });

    test('with nothing installed offers a guess', () async {
      expect(
        await plan(Language.auto, preferred: const ['xx', 'de']),
        const TextRecognitionNeedsData(
          OcrDataMissingException(deuOcr, guessed: true),
        ),
      );
      expect(
        await plan(Language.auto),
        TextRecognitionNeedsData(
          OcrDataMissingException(engOcr, guessed: true),
        ),
      );
    });

    test('is unsupported when no data exists at all', () async {
      data.languages = const [];
      expect(await plan(Language.auto), const TextRecognitionUnsupported());
    });
  });

  test('plans compare by value', () {
    expect(
      const TextRecognitionReady(['deu']).hashCode,
      const TextRecognitionReady(['deu']).hashCode,
    );
    expect(
      const TextRecognitionReady(['deu']),
      isNot(const TextRecognitionReady(['eng'])),
    );
    expect(
      const TextRecognitionReady(['deu', 'eng']).toString(),
      'TextRecognitionReady(deu+eng)',
    );
    const missing = TextRecognitionNeedsData(OcrDataMissingException(deuOcr));
    expect(
      missing.hashCode,
      const TextRecognitionNeedsData(OcrDataMissingException(deuOcr)).hashCode,
    );
    expect(missing.toString(), contains('deu'));
    expect(
      const TextRecognitionUnsupported().hashCode,
      const TextRecognitionUnsupported().hashCode,
    );
    expect(
      const OcrDataMissingException(deuOcr, guessed: true).toString(),
      'OcrDataMissingException(deu, guessed)',
    );
    expect(deuOcr.fileName, 'deu.traineddata');
  });
}
