import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

class _MockUsageTracker extends Mock implements UsageTracker;

/// An AI engine without a provider id (vision found through its id).
const _keyless = TranslationEngine(
  id: 'ai:keyless',
  kind: EngineKind.ai,
  name: 'Keyless',
);

const _keylessProvider = AiProviderConfig(
  id: 'keyless',
  name: 'Keyless',
  provider: LlmProvider.openAiCompatible,
  baseUrl: 'http://localhost:8080/v1',
  model: 'vision',
  supportsVision: true,
);

void main() {
  late MockTranslationRepository repository;
  late FakeImagePickerService picker;
  late FakeImageEncoder encoder;
  late FakeTextRecognitionService recognizer;
  late _MockUsageTracker tracker;

  setUpAll(registerImageTranslateFallbacks);

  setUp(() {
    repository = MockTranslationRepository();
    picker = FakeImagePickerService();
    encoder = FakeImageEncoder();
    recognizer = FakeTextRecognitionService(text: ' Hola ');
    tracker = _MockUsageTracker();
    when(
      () => tracker.recordText(
        any(),
        input: any(named: 'input'),
        output: any(named: 'output'),
      ),
    ).thenAnswer((_) async => const UsageStats(requests: 1));
  });

  ImageTranslateCubit build({
    TranslationEngine? translateEngine = claude,
    List<TranslationEngine> engines = const [google, deepl, claude, _keyless],
    TranslationOptions options = const TranslationOptions(),
    UsageTracker? usageTracker,
    bool withTracker = true,
  }) {
    final cubit = ImageTranslateCubit(
      repository: repository,
      picker: picker,
      encoder: encoder,
      recognizer: recognizer,
      engines: engines,
      providers: const [...allProviders, _keylessProvider],
      translateEngine: translateEngine,
      target: french,
      options: options,
      slowThreshold: const Duration(minutes: 1),
      usageTracker: withTracker ? usageTracker ?? tracker : null,
    );
    addTearDown(cubit.close);
    // These tests are about the uploading methods: the translator's AI
    // vision method, else Mozhi (on-device recognition comes first).
    final methods = cubit.state.methods;
    final upload =
        methods
            .where(
              (m) =>
                  m.kind == ImageTranslateMethodKind.aiVision &&
                  m.engine?.id == translateEngine?.id,
            )
            .firstOrNull ??
        methods
            .where((m) => m.kind == ImageTranslateMethodKind.mozhiLens)
            .firstOrNull;
    if (upload != null) unawaited(cubit.selectMethod(upload));
    return cubit;
  }

  /// Shows [image] and asks for the translation (the user's Translate).
  Future<void> load(ImageTranslateCubit cubit, PickedImage image) {
    unawaited(cubit.setImage(image));
    return cubit.translate();
  }

  void stubImage(Future<ImageTranslationResult> Function() answer) => when(
    () => repository.translateImage(
      any(),
      any(),
      mimeType: any(named: 'mimeType'),
      source: any(named: 'source'),
      target: any(named: 'target'),
      options: any(named: 'options'),
    ),
  ).thenAnswer((_) => answer());

  void stubText(Stream<TranslationResult> Function() answer) =>
      when(() => repository.translate(any(), any()))
          .thenAnswer((_) => answer());

  TranslationResult text(
    String value, {
    TranslationEngine engine = claude,
    bool complete = true,
    bool fromCache = false,
  }) => TranslationResult(
    engineId: engine.id,
    engineName: engine.name,
    text: value,
    isComplete: complete,
    fromCache: fromCache,
  );

  /// (provider, input, output) of every recorded request, in order.
  List<(String, String, String)> recorded() {
    final captured = verify(
      () => tracker.recordText(
        captureAny(),
        input: captureAny(named: 'input'),
        output: captureAny(named: 'output'),
      ),
    ).captured;
    return [
      for (var i = 0; i < captured.length; i += 3)
        (
          captured[i] as String,
          captured[i + 1] as String,
          captured[i + 2] as String,
        ),
    ];
  }

  void verifyNothingRecorded() => verifyNever(
    () => tracker.recordText(
      any(),
      input: any(named: 'input'),
      output: any(named: 'output'),
    ),
  );

  /// The prompt text of a vision request for [jpegImage] auto -> French.
  String promptText({
    TranslationOptions options = const TranslationOptions(),
  }) => TranslationPrompts.translateImage(
    jpegImage.bytes,
    mimeType: jpegImage.mimeType,
    source: Language.auto,
    target: french,
    options: options,
  ).map((message) => message.content).join('\n');

  group('visionUsageInput', () {
    test('is the text the model read from the image, if any', () {
      expect(
        ImageTranslateCubit.visionUsageInput(
          const ImageTranslationResult(
            sourceText: ' Hola ',
            translatedText: 'x',
          ),
          jpegImage.bytes,
          mimeType: 'image/jpeg',
          source: Language.auto,
          target: french,
        ),
        'Hola',
      );
    });

    test('else the text of the prompt (the image is not estimated)', () {
      const options = TranslationOptions(context: 'A restaurant menu');
      final input = ImageTranslateCubit.visionUsageInput(
        const ImageTranslationResult(translatedText: 'x'),
        jpegImage.bytes,
        mimeType: 'image/jpeg',
        source: Language.auto,
        target: french,
        options: options,
      );
      expect(input, promptText(options: options));
      expect(input, contains('Translate all text in this image.'));
      expect(input, contains('A restaurant menu'));
    });
  });

  group('AI vision', () {
    test('counts an answered request once: prompt in, text out', () async {
      const options = TranslationOptions(context: 'A menu');
      stubImage(
        () async => const ImageTranslationResult(
          translatedText: ' Bonjour ',
          notes: ' A sign ',
        ),
      );
      final cubit = build(options: options);
      expect(cubit.state.method, claudeMethod);

      await load(cubit, jpegImage);
      await pumpEventQueue();

      expect(cubit.state.status, ImageTranslateStatus.success);
      expect(recorded(), [
        ('claude', promptText(options: options), 'Bonjour\nA sign'),
      ]);
    });

    test('counts the text the model read as input when reported', () async {
      stubImage(
        () async => const ImageTranslationResult(
          sourceText: 'Hola',
          translatedText: 'Bonjour',
        ),
      );
      await load(build(), jpegImage);
      await pumpEventQueue();

      expect(recorded(), [('claude', 'Hola', 'Bonjour')]);
    });

    test('counts an answered request that found no text', () async {
      stubImage(() async => const ImageTranslationResult());
      final cubit = build();

      await load(cubit, jpegImage);
      await pumpEventQueue();

      expect(cubit.state.status, ImageTranslateStatus.failure);
      expect(recorded(), [('claude', promptText(), '')]);
    });

    test('does not count failed requests', () async {
      stubImage(() async => throw const LlmApiException('Overloaded'));
      final cubit = build();

      await load(cubit, jpegImage);
      await pumpEventQueue();

      expect(cubit.state.status, ImageTranslateStatus.failure);
      verifyNothingRecorded();
    });

    test('counts a request that is answered after it was cancelled '
        '(it cannot be aborted, so the provider bills it)', () async {
      final answer = Completer<ImageTranslationResult>();
      stubImage(() => answer.future);
      final cubit = build();

      final running = load(cubit, jpegImage);
      await pumpEventQueue();
      cubit.cancel();
      answer.complete(const ImageTranslationResult(translatedText: 'Bonjour'));
      await running;
      await pumpEventQueue();

      expect(cubit.state.status, ImageTranslateStatus.ready);
      expect(cubit.state.result, isNull);
      expect(recorded(), [('claude', promptText(), 'Bonjour')]);
    });

    test('counts a request that is answered after it was replaced', () async {
      final first = Completer<ImageTranslationResult>();
      final second = Completer<ImageTranslationResult>();
      final answers = [first, second];
      stubImage(() => answers.removeAt(0).future);
      final cubit = build();

      final running = load(cubit, jpegImage);
      await pumpEventQueue();
      await cubit.setTarget(german);
      final replacing = cubit.translate();
      await pumpEventQueue();
      first.complete(const ImageTranslationResult(translatedText: 'Bonjour'));
      second.complete(const ImageTranslationResult(translatedText: 'Hallo'));
      await Future.wait([running, replacing]);
      await pumpEventQueue();

      expect(cubit.state.status, ImageTranslateStatus.success);
      expect(cubit.state.result?.translatedText, 'Hallo');
      expect(recorded().map((entry) => entry.$3), ['Bonjour', 'Hallo']);
    });

    test('counts a request that is answered after the page closed', () async {
      final answer = Completer<ImageTranslationResult>();
      stubImage(() => answer.future);
      final cubit = build();

      final running = load(cubit, jpegImage);
      await pumpEventQueue();
      await cubit.close();
      answer.complete(const ImageTranslationResult(translatedText: 'Bonjour'));
      await running;
      await pumpEventQueue();

      expect(recorded(), [('claude', promptText(), 'Bonjour')]);
    });

    test('does not count a cancelled request that fails', () async {
      final answer = Completer<ImageTranslationResult>();
      stubImage(() => answer.future);
      final cubit = build();

      final running = load(cubit, jpegImage);
      await pumpEventQueue();
      cubit.cancel();
      answer.completeError(const LlmApiException('Overloaded'));
      await running;
      await pumpEventQueue();

      expect(cubit.state.status, ImageTranslateStatus.ready);
      verifyNothingRecorded();
    });

    test('does not count engines without a provider id', () async {
      stubImage(
        () async => const ImageTranslationResult(translatedText: 'Bonjour'),
      );
      final cubit = build(translateEngine: _keyless);
      expect(cubit.state.method, const ImageTranslateMethod.aiVision(_keyless));

      await load(cubit, jpegImage);
      await pumpEventQueue();

      expect(cubit.state.status, ImageTranslateStatus.success);
      verifyNothingRecorded();
    });
  });

  group('Mozhi (Google Translate)', () {
    test('is never counted', () async {
      stubImage(
        () async => const ImageTranslationResult(
          sourceText: 'Hola',
          translatedText: 'Bonjour',
        ),
      );
      final cubit = build(translateEngine: deepl);
      expect(cubit.state.method, mozhiMethod);

      await load(cubit, pngImage);
      await pumpEventQueue();

      expect(cubit.state.status, ImageTranslateStatus.success);
      verifyNothingRecorded();
    });
  });

  group('on-device recognition', () {
    Future<ImageTranslateCubit> onDevice({
      TranslationEngine translateEngine = claude,
    }) async {
      final cubit = build(translateEngine: translateEngine);
      await cubit.selectMethod(const ImageTranslateMethod.onDevice());
      return cubit;
    }

    test('counts the translation of the recognised text once', () async {
      stubText(
        () => Stream.fromIterable([
          text('Bon', complete: false),
          text('Bonjour'),
        ]),
      );
      final cubit = await onDevice();

      await cubit.setImage(jpegImage);
      await pumpEventQueue();

      expect(cubit.state.status, ImageTranslateStatus.success);
      expect(cubit.state.result?.translatedText, 'Bonjour');
      expect(recorded(), [('claude', 'Hola', 'Bonjour')]);
    });

    test('counts translations of edited text', () async {
      stubText(() => Stream.value(text('Bonjour')));
      final cubit = await onDevice();
      await cubit.setImage(jpegImage);
      await pumpEventQueue();

      stubText(() => Stream.value(text('Bonsoir')));
      await cubit.translateText(' Buenas noches ');
      await pumpEventQueue();

      expect(recorded(), [
        ('claude', 'Hola', 'Bonjour'),
        ('claude', 'Buenas noches', 'Bonsoir'),
      ]);
    });

    test('does not count results from the cache', () async {
      stubText(() => Stream.value(text('Bonjour', fromCache: true)));
      final cubit = await onDevice();

      await cubit.setImage(jpegImage);
      await pumpEventQueue();

      expect(cubit.state.status, ImageTranslateStatus.success);
      verifyNothingRecorded();
    });

    test('does not count a stream without a complete result', () async {
      stubText(() => Stream.value(text('Bon', complete: false)));
      final cubit = await onDevice();

      await cubit.setImage(jpegImage);
      await pumpEventQueue();

      expect(cubit.state.status, ImageTranslateStatus.success);
      verifyNothingRecorded();
    });

    test('does not count engines without a provider id', () async {
      stubText(() => Stream.value(text('Bonjour', engine: deepl)));
      final cubit = await onDevice(translateEngine: deepl);

      await cubit.setImage(jpegImage);
      await pumpEventQueue();

      expect(cubit.state.status, ImageTranslateStatus.success);
      verifyNothingRecorded();
    });

    test('does not count failed translations', () async {
      stubText(
        () =>
            Stream.fromIterable([text('Bon', complete: false)])
                .followedBy(const LlmApiException('Overloaded')),
      );
      final cubit = await onDevice();

      await cubit.setImage(jpegImage);
      await pumpEventQueue();

      expect(cubit.state.status, ImageTranslateStatus.failure);
      verifyNothingRecorded();
    });

    test('does not count a cancelled translation', () async {
      final results = StreamController<TranslationResult>();
      addTearDown(results.close);
      stubText(() => results.stream);
      final cubit = await onDevice();

      final running = cubit.setImage(jpegImage);
      await pumpEventQueue();
      results.add(text('Bon', complete: false));
      await pumpEventQueue();
      cubit.cancel();
      await running;
      await pumpEventQueue();

      expect(cubit.state.status, ImageTranslateStatus.ready);
      verifyNothingRecorded();
    });
  });

  group('on-device recognition (cancelled after the complete result)', () {
    test('counts the translation the provider already answered', () async {
      final results = StreamController<TranslationResult>();
      addTearDown(results.close);
      stubText(() => results.stream);
      final cubit = build();
      await cubit.selectMethod(const ImageTranslateMethod.onDevice());

      final running = cubit.setImage(jpegImage);
      await pumpEventQueue();
      results.add(text('Bonjour'));
      await pumpEventQueue();
      cubit.cancel();
      await running;
      await pumpEventQueue();

      expect(cubit.state.status, ImageTranslateStatus.ready);
      expect(recorded(), [('claude', 'Hola', 'Bonjour')]);
    });
  });

  group('tracker', () {
    test('is optional', () async {
      stubImage(
        () async => const ImageTranslationResult(translatedText: 'Bonjour'),
      );
      final cubit = build(withTracker: false);

      await load(cubit, jpegImage);

      expect(cubit.state.status, ImageTranslateStatus.success);
      verifyNothingRecorded();
    });

    test('errors are ignored', () async {
      stubImage(
        () async => const ImageTranslationResult(translatedText: 'Bonjour'),
      );
      final throwing = _MockUsageTracker();
      when(
        () => throwing.recordText(
          any(),
          input: any(named: 'input'),
          output: any(named: 'output'),
        ),
      ).thenThrow(StateError('broken'));
      final cubit = build(usageTracker: throwing);
      await load(cubit, jpegImage);
      expect(cubit.state.status, ImageTranslateStatus.success);

      final failing = _MockUsageTracker();
      when(
        () => failing.recordText(
          any(),
          input: any(named: 'input'),
          output: any(named: 'output'),
        ),
      ).thenAnswer((_) async => throw StateError('disk full'));
      final other = build(usageTracker: failing);
      await load(other, jpegImage);
      await pumpEventQueue();
      expect(other.state.status, ImageTranslateStatus.success);
    });
  });
}

extension<T> on Stream<T> {
  /// This stream's events, then [error].
  Stream<T> followedBy(Exception error) async* {
    yield* this;
    throw error;
  }
}
