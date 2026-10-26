import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show Locale;
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_ocr.dart';
import '../helpers/helpers.dart';

// On-device recognition with downloadable language data (Tesseract, the
// default build): the cubit plans the languages, offers missing data and
// never downloads.
void main() {
  late MockTranslationRepository repository;
  late FakeOcrData data;

  setUpAll(registerImageTranslateFallbacks);

  setUp(() {
    repository = MockTranslationRepository();
    data = FakeOcrData(text: ' Ausgang ');
    when(() => repository.translate(any(), any())).thenAnswer(
      (_) => Stream.value(
        TranslationResult(
          engineId: deepl.id,
          engineName: deepl.name,
          text: 'Exit',
        ),
      ),
    );
  });

  ImageTranslateCubit build({
    Language source = german,
    List<String> preferred = const [],
  }) => ImageTranslateCubit(
    repository: repository,
    picker: FakeImagePickerService(),
    encoder: FakeImageEncoder(),
    recognizer: data,
    engines: allEngines,
    providers: allProviders,
    translateEngine: deepl,
    source: source,
    target: english,
    preferredLanguages: preferred,
  );

  test('prefers on-device recognition', () {
    final cubit = build();
    addTearDown(cubit.close);
    expect(cubit.state.method, onDeviceMethod);
  });

  test('reads with the source data and translates the text', () async {
    data.installed = {'deu': 1};
    final cubit = build();
    addTearDown(cubit.close);
    await cubit.setImage(jpegImage);
    expect(data.recognized, [
      ['deu'],
    ]);
    expect(cubit.state.status, ImageTranslateStatus.success);
    expect(cubit.state.result?.sourceText, 'Ausgang');
    expect(cubit.state.result?.translatedText, 'Exit');
  });

  test('keeps what the personal data shield kept on the device', () async {
    when(() => repository.translate(any(), any())).thenAnswer(
      (_) => Stream.value(
        TranslationResult(
          engineId: deepl.id,
          engineName: deepl.name,
          text: 'Exit',
          maskedPersonalData: 2,
        ),
      ),
    );
    data.installed = {'deu': 1};
    final cubit = build();
    addTearDown(cubit.close);
    await cubit.setImage(jpegImage);
    expect(cubit.state.result?.maskedPersonalData, 2);
  });

  test('offers missing data without downloading it', () async {
    final cubit = build();
    addTearDown(cubit.close);
    await cubit.setImage(jpegImage);
    expect(cubit.state.status, ImageTranslateStatus.failure);
    expect(cubit.state.error, const OcrDataMissingException(deuOcr));
    expect(data.recognized, isEmpty);
    expect(data.downloads, isEmpty);

    // Once the data is there, Retry reads the image.
    data.installed = {'deu': 1};
    await cubit.translate();
    expect(cubit.state.status, ImageTranslateStatus.success);
  });

  test('reports a source language without data', () async {
    final cubit = build(
      source: const Language(code: 'xh', name: 'Xhosa'),
    );
    addTearDown(cubit.close);
    await cubit.setImage(jpegImage);
    expect(
      cubit.state.error,
      const ImageTranslateException(
        ImageTranslateErrorKind.recognitionLanguageUnsupported,
      ),
    );
  });

  test(
    'Detect language reads with the installed data, preferred first',
    () async {
      data.installed = {'eng': 1, 'fra': 1, 'jpn': 1, 'deu': 1};
      final cubit = build(source: Language.auto, preferred: const ['ja', 'de']);
      addTearDown(cubit.close);
      await cubit.setImage(jpegImage);
      expect(data.recognized, [
        ['jpn', 'deu', 'eng'],
      ]);
    },
  );

  group('recognition confidence', () {
    test('is kept with the recognised text', () async {
      data
        ..installed = {'eng': 1}
        ..confidence = 31;
      final cubit = build(source: Language.auto);
      addTearDown(cubit.close);
      await cubit.setImage(jpegImage);
      expect(cubit.state.result?.recognitionConfidence, 31);
      expect(cubit.state.hasLowRecognitionConfidence, isTrue);

      // Another target translates the same text: still read poorly.
      await cubit.setTarget(german);
      expect(cubit.state.result?.translatedText, 'Exit');
      expect(cubit.state.result?.recognitionConfidence, 31);

      // Edited text is the user's.
      await cubit.translateText('Ausgang links');
      expect(cubit.state.result?.recognitionConfidence, isNull);
      expect(cubit.state.hasLowRecognitionConfidence, isFalse);
    });

    test('is kept when the translation fails', () async {
      data
        ..installed = {'eng': 1}
        ..confidence = 20;
      when(() => repository.translate(any(), any())).thenAnswer(
        (_) => Stream.error(const SourceLanguageRequiredException()),
      );
      final cubit = build(source: Language.auto);
      addTearDown(cubit.close);
      await cubit.setImage(jpegImage);
      expect(cubit.state.status, ImageTranslateStatus.failure);
      expect(cubit.state.error, isA<SourceLanguageRequiredException>());
      expect(cubit.state.result?.recognitionConfidence, 20);
    });

    test('is unknown when the recognizer does not report it', () async {
      data
        ..installed = {'eng': 1}
        ..confidence = 10;
      final cubit = ImageTranslateCubit(
        repository: repository,
        picker: FakeImagePickerService(),
        encoder: FakeImageEncoder(),
        recognizer: PlainOcrData(data),
        engines: allEngines,
        providers: allProviders,
        translateEngine: deepl,
        target: english,
      );
      addTearDown(cubit.close);
      await cubit.setImage(jpegImage);
      expect(cubit.state.result?.sourceText, 'Ausgang');
      expect(cubit.state.result?.recognitionConfidence, isNull);
      expect(cubit.state.hasLowRecognitionConfidence, isFalse);
    });

    test('a confident reading is no hint', () async {
      data
        ..installed = {'eng': 1}
        ..confidence = 88;
      final cubit = build(source: Language.auto);
      addTearDown(cubit.close);
      await cubit.setImage(jpegImage);
      expect(cubit.state.hasLowRecognitionConfidence, isFalse);
    });

    test('choosing the language reads again with its data', () async {
      data
        ..installed = {'eng': 1, 'deu': 1}
        ..confidence = 25;
      final cubit = build(source: Language.auto);
      addTearDown(cubit.close);
      await cubit.setImage(jpegImage);
      await cubit.setSource(german);
      expect(data.recognized.last, ['deu']);
      expect(cubit.state.hasLowRecognitionConfidence, isFalse);
    });
  });

  test('Detect language without data offers a guess', () async {
    final cubit = build(source: Language.auto, preferred: const ['fr']);
    addTearDown(cubit.close);
    await cubit.setImage(jpegImage);
    expect(
      cubit.state.error,
      const OcrDataMissingException(fraOcr, guessed: true),
    );
  });

  test(
    'recognition failures are shown with the recognised-text flow',
    () async {
      data
        ..installed = {'deu': 1}
        ..recognizeError = const ImageTranslateException(
          ImageTranslateErrorKind.recognitionFailed,
        );
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.setImage(jpegImage);
      expect(
        cubit.state.error,
        const ImageTranslateException(
          ImageTranslateErrorKind.recognitionFailed,
        ),
      );
    },
  );

  test('a recognizer without language data reads as before', () async {
    final recognizer = FakeTextRecognitionService(text: 'Hola');
    final cubit = ImageTranslateCubit(
      repository: repository,
      picker: FakeImagePickerService(),
      encoder: FakeImageEncoder(),
      recognizer: recognizer,
      engines: allEngines,
      providers: allProviders,
      translateEngine: deepl,
      source: german,
      target: english,
    );
    addTearDown(cubit.close);
    await cubit.setImage(jpegImage);
    expect(recognizer.sources, [german]);
  });

  test('ocrPreferredLanguages lists recent sources, languages, the locale', () {
    const settings = AppSettings(
      recentPairs: [
        LanguagePair(source: french, target: english),
        LanguagePair(source: Language.auto, target: german),
        LanguagePair(source: french, target: german),
      ],
      recentLanguages: [german, english, Language.custom('Pirate')],
    );
    expect(ocrPreferredLanguages(settings, const Locale('ja')), [
      'fr',
      'de',
      'en',
      'ja',
    ]);
    expect(ocrPreferredLanguages(const AppSettings(), null), isEmpty);
  });
}
