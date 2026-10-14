import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/conversation/conversation.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

class _MockUsageTracker extends Mock implements UsageTracker;

/// A machine translation service with its own key.
const _deeplApi = TranslationEngine(
  id: 'mt:deepl-key',
  kind: EngineKind.mt,
  name: 'DeepL API',
  providerId: 'deepl-key',
);

/// A translation-only AI model (MT prompt profile) with its own key.
const _translateGemma = TranslationEngine(
  id: 'ai:gemma',
  kind: EngineKind.ai,
  name: 'TranslateGemma',
  providerId: 'gemma',
  promptProfile: PromptProfile.translateGemma,
);

void main() {
  setUpAll(registerConversationFallbacks);

  late MockTranslationRepository repository;
  late MockSpeechService speech;
  late StreamController<String?> speaking;
  late _MockUsageTracker tracker;
  late TranslationEngine engine;
  var options = const TranslationOptions();

  setUp(() {
    repository = MockTranslationRepository();
    speech = MockSpeechService();
    speaking = stubSpeech(speech);
    tracker = _MockUsageTracker();
    when(
      () => tracker.recordText(
        any(),
        input: any(named: 'input'),
        output: any(named: 'output'),
      ),
    ).thenAnswer((_) async => const UsageStats(requests: 1));
    engine = claude;
    options = const TranslationOptions();
  });

  tearDown(() => speaking.close());

  ConversationCubit build({
    UsageTracker? usageTracker,
    bool withTracker = true,
  }) {
    final cubit = ConversationCubit(
      repository: repository,
      speech: speech,
      engine: () => engine,
      options: () => options,
      languageA: english,
      languageB: spanish,
      clock: () => sentAt,
      usageTracker: withTracker ? usageTracker ?? tracker : null,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  void stubTranslate(Stream<TranslationResult> Function() stream) {
    when(() => repository.translate(any(), any())).thenAnswer((_) => stream());
  }

  List<TranslationRequest> requests() =>
      verify(() => repository.translate(any(), captureAny())).captured
          .cast<TranslationRequest>();

  /// (provider, input, output) of every recorded request.
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

  group('ConversationCubit usage', () {
    test(
      'counts an AI translation once, with the conversation context',
      () async {
        stubTranslate(
          () => Stream.fromIterable([
            resultOf('Ho', engine: claude, isComplete: false),
            resultOf('Hola', engine: claude),
          ]),
        );
        final cubit = build();

        await cubit.submit(ConversationSide.a, ' Hello ');

        expect(cubit.state.turns.single.isComplete, isTrue);
        final request = requests().single;
        expect(request.options.context, contains('live spoken conversation'));
        expect(recorded(), [
          ('claude', 'Hello\n${request.options.context}', 'Hola'),
        ]);
      },
    );

    test('counts previous messages sent as context', () async {
      stubTranslate(() => Stream.value(resultOf('Hola', engine: claude)));
      final cubit = build();
      await cubit.submit(ConversationSide.a, 'Hello');
      stubTranslate(() => Stream.value(resultOf('Fine', engine: claude)));
      await cubit.submit(ConversationSide.b, 'Bien');

      final last = recorded().last;
      expect(last.$2, startsWith('Bien\n'));
      expect(last.$2, contains('English speaker: Hello'));
      expect(last.$3, 'Fine');
    });

    test('counts only the message for machine translation services', () async {
      engine = _deeplApi;
      options = const TranslationOptions(context: 'A business meeting');
      stubTranslate(() => Stream.value(resultOf('Hola', engine: _deeplApi)));
      final cubit = build();

      await cubit.submit(ConversationSide.a, 'Hello');

      expect(cubit.state.turns.single.isComplete, isTrue);
      expect(recorded(), [('deepl-key', 'Hello', 'Hola')]);
    });

    test('counts only the message for translation-only AI models, which '
        'get no options or context', () async {
      engine = _translateGemma;
      options = const TranslationOptions(context: 'A business meeting');
      stubTranslate(
        () => Stream.value(resultOf('Hola', engine: _translateGemma)),
      );
      final cubit = build();
      await cubit.submit(ConversationSide.a, 'Hello');
      stubTranslate(
        () => Stream.value(resultOf('Fine', engine: _translateGemma)),
      );
      await cubit.submit(ConversationSide.b, 'Bien');

      expect(cubit.state.turns.every((turn) => turn.isComplete), isTrue);
      expect(recorded(), [
        ('gemma', 'Hello', 'Hola'),
        ('gemma', 'Bien', 'Fine'),
      ]);
      // The conversation context is not built for them either.
      expect(
        requests().map((request) => request.options.context),
        everyElement(isNot(contains('live spoken conversation'))),
      );
    });

    test('does not count results from the cache', () async {
      stubTranslate(
        () => Stream.value(
          resultOf('Hola', engine: claude).copyWith(fromCache: true),
        ),
      );
      final cubit = build();

      await cubit.submit(ConversationSide.a, 'Hello');

      expect(cubit.state.turns.single.isComplete, isTrue);
      verifyNothingRecorded();
    });

    test('does not count a stream without a complete result', () async {
      stubTranslate(
        () => Stream.value(resultOf('Ho', engine: claude, isComplete: false)),
      );
      final cubit = build();

      await cubit.submit(ConversationSide.a, 'Hello');

      verifyNothingRecorded();
    });

    test('does not count engines without a provider id', () async {
      engine = deepl;
      stubTranslate(() => Stream.value(resultOf('Hola')));
      final cubit = build();

      await cubit.submit(ConversationSide.a, 'Hello');

      expect(cubit.state.turns.single.isComplete, isTrue);
      verifyNothingRecorded();
    });

    test('does not count failed translations; counts the retry', () async {
      stubTranslate(
        () => Stream<TranslationResult>.fromIterable([
          resultOf('Ho', engine: claude, isComplete: false),
        ]).followedBy(const LlmApiException('Overloaded')),
      );
      final cubit = build();

      await cubit.submit(ConversationSide.a, 'Hello');
      expect(cubit.state.turns.single.isFailed, isTrue);
      verifyNothingRecorded();

      stubTranslate(() => Stream.value(resultOf('Hola', engine: claude)));
      await cubit.retry(cubit.state.turns.single.id);

      expect(cubit.state.turns.single.isComplete, isTrue);
      expect(recorded().map((entry) => entry.$3), ['Hola']);
    });

    test('does not count removed or cleared turns', () async {
      final results = StreamController<TranslationResult>.broadcast();
      addTearDown(results.close);
      stubTranslate(() => results.stream);
      final cubit = build();

      final first = cubit.submit(ConversationSide.a, 'Hello');
      final second = cubit.submit(ConversationSide.b, 'Adiós');
      await pumpEventQueue();
      results.add(resultOf('Ho', engine: claude, isComplete: false));
      await cubit.removeTurn(cubit.state.turns.first.id);
      await cubit.clear();
      await Future.wait([first, second]);
      results.add(resultOf('Hola', engine: claude));
      await results.close();
      await pumpEventQueue();

      expect(cubit.state.turns, isEmpty);
      verifyNothingRecorded();
    });

    test('works without a tracker', () async {
      stubTranslate(() => Stream.value(resultOf('Hola', engine: claude)));
      final cubit = build(withTracker: false);

      await cubit.submit(ConversationSide.a, 'Hello');

      expect(cubit.state.turns.single.isComplete, isTrue);
      verifyNothingRecorded();
    });

    test('ignores tracker errors', () async {
      stubTranslate(() => Stream.value(resultOf('Hola', engine: claude)));
      final throwing = _MockUsageTracker();
      when(
        () => throwing.recordText(
          any(),
          input: any(named: 'input'),
          output: any(named: 'output'),
        ),
      ).thenThrow(StateError('broken'));
      final cubit = build(usageTracker: throwing);
      await cubit.submit(ConversationSide.a, 'Hello');
      expect(cubit.state.turns.single.isComplete, isTrue);

      final failing = _MockUsageTracker();
      when(
        () => failing.recordText(
          any(),
          input: any(named: 'input'),
          output: any(named: 'output'),
        ),
      ).thenAnswer((_) async => throw StateError('disk full'));
      final other = build(usageTracker: failing);
      await other.submit(ConversationSide.a, 'Hello');
      await pumpEventQueue();
      expect(other.state.turns.single.isComplete, isTrue);
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
