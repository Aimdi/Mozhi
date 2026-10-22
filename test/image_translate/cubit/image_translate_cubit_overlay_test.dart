import 'dart:async';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_ocr.dart';
import '../helpers/helpers.dart';

const _offline = TranslationEngine(
  id: 'offline',
  kind: EngineKind.offline,
  name: 'On this device',
);

TextParagraph _paragraph(String text, double top) =>
    TextParagraph(text: text, box: Rect.fromLTWH(10, top, 300, 40));

final _layout = TextLayout(
  width: 400,
  height: 300,
  paragraphs: [
    _paragraph('Öffnungszeiten', 10),
    _paragraph('Montag bis Freitag', 60),
    _paragraph('Kasse', 120),
  ],
);

/// A recognizer without language data that reports a layout (like ML Kit
/// in the Play variant).
class _LayoutRecognizer extends FakeTextRecognitionService
    implements TextRecognitionLayout {
  new(this.layout);

  final TextLayout? layout;
  final layoutSources = <Language>[];

  @override
  Future<TextWithConfidence> recognizeLayout(
    PickedImage image, {
    required Language source,
  }) async {
    layoutSources.add(source);
    return TextWithConfidence('raw text', layout: layout);
  }
}

// On-device recognition with a layout: the paragraphs are translated in one
// request and split back for the overlay.
void main() {
  late MockTranslationRepository repository;
  late FakeOcrData data;
  late List<TranslationRequest> requests;

  /// What the engine answers per request text (default: the paragraphs
  /// translated word for word).
  late String Function(String text) answer;

  /// The language the engine reports it detected.
  late String detected;

  setUpAll(registerImageTranslateFallbacks);

  setUp(() {
    repository = MockTranslationRepository();
    data = FakeOcrData(text: 'Öffnungszeiten\nMontag bis\nFreitag\n\nKasse')
      ..installed = {'deu': 1}
      ..layout = _layout;
    requests = [];
    detected = 'de';
    answer = (text) => text
        .replaceAll('Öffnungszeiten', 'Opening hours')
        .replaceAll('Montag bis Freitag', 'Monday to Friday')
        .replaceAll('Kasse', 'Cash desk');
    when(() => repository.translate(any(), any())).thenAnswer((invocation) {
      final engine = invocation.positionalArguments[0] as TranslationEngine;
      final request = invocation.positionalArguments[1] as TranslationRequest;
      requests.add(request);
      return Stream.value(
        TranslationResult(
          engineId: engine.id,
          engineName: engine.name,
          text: answer(request.text),
          detectedSource: detected,
        ),
      );
    });
  });

  ImageTranslateCubit build({
    TranslationEngine engine = deepl,
    Language source = german,
    TextRecognitionService? recognizer,
  }) => ImageTranslateCubit(
    repository: repository,
    picker: FakeImagePickerService(),
    encoder: FakeImageEncoder(),
    recognizer: recognizer ?? data,
    engines: [...allEngines, _offline],
    providers: allProviders,
    translateEngine: engine,
    source: source,
    target: english,
  );

  test('translates the paragraphs in one request and splits them', () async {
    final cubit = build();
    addTearDown(cubit.close);
    await cubit.setImage(jpegImage);
    expect(cubit.state.status, ImageTranslateStatus.success);
    expect(requests.map((r) => r.text), [
      'Öffnungszeiten\n\nMontag bis Freitag\n\nKasse',
    ]);
    final result = cubit.state.result!;
    expect(result.sourceText, _layout.text);
    expect(result.layout, _layout);
    expect(result.translatedParagraphs, [
      'Opening hours',
      'Monday to Friday',
      'Cash desk',
    ]);
    expect(cubit.state.showsOverlay, isTrue);
    expect(cubit.state.resultMode, ImageResultMode.overlay);

    // Text mode shows the text below the plain photo, also for the next one.
    cubit.setResultMode(ImageResultMode.text);
    expect(cubit.state.showsOverlay, isFalse);
    final states = <ImageTranslateState>[];
    final subscription = cubit.stream.listen(states.add);
    addTearDown(subscription.cancel);
    cubit.setResultMode(ImageResultMode.text);
    await pumpEventQueue();
    expect(states, isEmpty);
    await cubit.setImage(jpegImage);
    expect(cubit.state.resultMode, ImageResultMode.text);
    cubit
      ..setShowOriginal(showOriginal: true)
      ..setResultMode(ImageResultMode.overlay);
    expect(cubit.state.showOriginal, isFalse);
    expect(cubit.state.showsOverlay, isTrue);
  });

  test('a network engine that merged paragraphs gets no more requests, '
      'its translation is spread', () async {
    answer = (_) => 'Opening hours\nMonday to Friday\nCash desk';
    final cubit = build();
    addTearDown(cubit.close);
    await cubit.setImage(jpegImage);
    expect(requests, hasLength(1));
    expect(cubit.state.result?.translatedParagraphs, [
      'Opening hours',
      'Monday to Friday',
      'Cash desk',
    ]);
  });

  test('the on-device engine translates paragraphs it merged one by one, '
      'with the detected source', () async {
    var calls = 0;
    answer = (text) =>
        calls++ == 0 ? 'Opening hours Monday to Friday Cash desk' : '$text!';
    final cubit = build(engine: _offline, source: Language.auto);
    addTearDown(cubit.close);
    await cubit.setImage(jpegImage);
    expect(requests.map((r) => r.text), [
      _layout.text,
      'Öffnungszeiten',
      'Montag bis Freitag',
      'Kasse',
    ]);
    expect(requests[0].source, Language.auto);
    expect(requests.skip(1).map((r) => r.source.code), everyElement('de'));

    // A detected language the catalogue does not know is used as it is.
    detected = 'qq';
    calls = 0;
    requests.clear();
    await cubit.translateText(_layout.text);
    expect(requests.skip(1).map((r) => r.source.code), everyElement('qq'));
    expect(cubit.state.result?.translatedParagraphs, [
      'Öffnungszeiten!',
      'Montag bis Freitag!',
      'Kasse!',
    ]);
  });

  test('a failed paragraph request spreads the whole translation', () async {
    var calls = 0;
    when(() => repository.translate(any(), any())).thenAnswer((invocation) {
      final request = invocation.positionalArguments[1] as TranslationRequest;
      requests.add(request);
      if (calls++ > 0) return Stream.error(StateError('engine gone'));
      return Stream.value(
        const TranslationResult(
          engineId: 'offline',
          engineName: 'On this device',
          text: 'Opening hours\nMonday to Friday\nCash desk',
        ),
      );
    });
    final cubit = build(engine: _offline);
    addTearDown(cubit.close);
    await cubit.setImage(jpegImage);
    expect(requests, hasLength(2));
    expect(cubit.state.status, ImageTranslateStatus.success);
    expect(cubit.state.result?.translatedParagraphs, [
      'Opening hours',
      'Monday to Friday',
      'Cash desk',
    ]);
  });

  test('a run replaced during the paragraph requests is dropped', () async {
    final gate = Completer<void>();
    var calls = 0;
    when(() => repository.translate(any(), any())).thenAnswer((invocation) {
      final request = invocation.positionalArguments[1] as TranslationRequest;
      requests.add(request);
      if (calls++ == 0) {
        return Stream.value(
          const TranslationResult(
            engineId: 'offline',
            engineName: 'On this device',
            text: 'everything',
          ),
        );
      }
      return Stream.fromFuture(
        gate.future.then(
          (_) => const TranslationResult(
            engineId: 'offline',
            engineName: 'On this device',
            text: 'late',
          ),
        ),
      );
    });
    final cubit = build(engine: _offline);
    addTearDown(cubit.close);
    final run = cubit.setImage(jpegImage);
    await pumpEventQueue();
    expect(requests, hasLength(2));
    cubit.cancel();
    gate.complete();
    await run;
    expect(cubit.state.status, ImageTranslateStatus.ready);
    expect(cubit.state.result?.translatedParagraphs, isEmpty);
    // The layout stays with the recognised text.
    expect(cubit.state.result?.layout, _layout);
    expect(requests, hasLength(2));
  });

  test('a paragraph request failing after a replaced run is ignored', () async {
    final gate = Completer<void>();
    var calls = 0;
    when(() => repository.translate(any(), any())).thenAnswer((invocation) {
      if (calls++ == 0) {
        return Stream.value(
          const TranslationResult(
            engineId: 'offline',
            engineName: 'On this device',
            text: 'everything',
          ),
        );
      }
      return Stream.fromFuture(
        gate.future.then<TranslationResult>((_) => throw StateError('gone')),
      );
    });
    final cubit = build(engine: _offline);
    addTearDown(cubit.close);
    final run = cubit.setImage(jpegImage);
    await pumpEventQueue();
    cubit.cancel();
    gate.complete();
    await run;
    expect(cubit.state.status, ImageTranslateStatus.ready);
  });

  test('edited text keeps the overlay while the paragraphs match', () async {
    final cubit = build();
    addTearDown(cubit.close);
    await cubit.setImage(jpegImage);
    await cubit.translateText('Öffnungszeit\n\nMontag bis Freitag\n\nKasse');
    expect(cubit.state.result?.layout?.paragraphs.first.text, 'Öffnungszeit');
    expect(cubit.state.result?.translatedParagraphs.first, 'Öffnungszeit');
    expect(cubit.state.showsOverlay, isTrue);

    await cubit.translateText('Öffnungszeiten Montag bis Freitag');
    expect(cubit.state.result?.layout, isNull);
    expect(cubit.state.result?.translatedParagraphs, isEmpty);
    expect(cubit.state.showsOverlay, isFalse);
    expect(
      cubit.state.result?.translatedText,
      'Opening hours Monday to Friday',
    );
  });

  test('a new target translates the paragraphs again', () async {
    final cubit = build();
    addTearDown(cubit.close);
    await cubit.setImage(jpegImage);
    await cubit.setTarget(french);
    expect(requests, hasLength(2));
    expect(requests.last.text, _layout.text);
    expect(requests.last.target, french);
    expect(cubit.state.result?.layout, _layout);
    expect(cubit.state.showsOverlay, isTrue);
  });

  test('a failed translation keeps the layout with the text', () async {
    when(() => repository.translate(any(), any()))
        .thenAnswer((_) => Stream.error(StateError('offline')));
    final cubit = build();
    addTearDown(cubit.close);
    await cubit.setImage(jpegImage);
    expect(cubit.state.status, ImageTranslateStatus.failure);
    expect(cubit.state.result?.sourceText, _layout.text);
    expect(cubit.state.result?.layout, _layout);
    expect(cubit.state.showsOverlay, isFalse);
  });

  test('a layout without paragraphs means no text (specks only)', () async {
    data.layout = const TextLayout(width: 4, height: 4, paragraphs: []);
    final cubit = build();
    addTearDown(cubit.close);
    await cubit.setImage(jpegImage);
    expect(
      cubit.state.error,
      const ImageTranslateException(ImageTranslateErrorKind.noText),
    );
    expect(requests, isEmpty);
  });

  test('a recognizer without language data can report a layout', () async {
    final recognizer = _LayoutRecognizer(_layout);
    final cubit = build(recognizer: recognizer);
    addTearDown(cubit.close);
    await cubit.setImage(jpegImage);
    expect(recognizer.layoutSources, [german]);
    expect(recognizer.sources, isEmpty);
    expect(requests.single.text, _layout.text);
    expect(cubit.state.showsOverlay, isTrue);

    final plain = build(recognizer: _LayoutRecognizer(null));
    addTearDown(plain.close);
    await plain.setImage(jpegImage);
    expect(requests.last.text, 'raw text');
    expect(plain.state.result?.layout, isNull);
  });
}
