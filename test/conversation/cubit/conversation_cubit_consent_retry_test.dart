import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/conversation/conversation.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

const _instance = PublicInstanceDestination('mozhi.example.org');

const _consent = ConsentRequiredException(
  kind: ConsentKind.pair,
  destination: _instance,
  engineId: 'mozhi:deepl',
  source: 'en',
  target: 'es',
);

const _down = MozhiApiException('down');

void main() {
  setUpAll(() {
    registerConversationFallbacks();
    registerFallbackValue(_consent);
  });

  late MockTranslationRepository repository;
  late MockSpeechService speech;
  late StreamController<String?> speaking;
  late List<Stream<TranslationResult> Function()> answers;
  late List<String> grants;
  TranslationEngine? engine;
  late DateTime now;

  setUp(() {
    repository = MockTranslationRepository();
    speech = MockSpeechService();
    speaking = stubSpeech(speech);
    engine = deepl;
    now = sentAt;
    answers = [];
    // What the repository saw: allowOnce and revokeOnce, in order.
    grants = [];
    when(() => repository.translate(any(), any())).thenAnswer(
      (_) => answers.isEmpty
          ? Stream.value(resultOf('Hola'))
          : answers.removeAt(0)(),
    );
    when(() => repository.destinationOf(any())).thenReturn(_instance);
    when(() => repository.allowOnce(any())).thenAnswer((invocation) {
      grants.add('allow');
    });
    when(() => repository.revokeOnce(any())).thenAnswer((invocation) {
      grants.add('revoke');
    });
  });

  tearDown(() => speaking.close());

  ConversationCubit build() => ConversationCubit(
    repository: repository,
    speech: speech,
    engine: () => engine,
    languageA: english,
    languageB: spanish,
    clock: () => now,
  );

  Stream<TranslationResult> Function() fails(Object error) =>
      () => Stream.error(error);

  /// A turn stopped for consent, which the user then gave ("Once"); its
  /// retry failed with [_down].
  Future<ConversationCubit> failedAfterConsent() async {
    answers = [fails(_consent), fails(_down)];
    final cubit = build();
    addTearDown(cubit.close);
    await cubit.submit(ConversationSide.a, 'Hello');
    expect(cubit.state.turns.single.error, _consent);
    // The consent prompt records "Once" (grantConsent), then retries.
    await cubit.retry(0);
    expect(cubit.state.turns.single.error, _down);
    return cubit;
  }

  group('ConversationCubit retry after a one-time consent', () {
    test('the retry after consent leaves no approval behind', () async {
      await failedAfterConsent();
      // The cubit grants nothing itself and withdraws what is left.
      expect(grants, ['revoke']);
      verify(() => repository.revokeOnce(_consent)).called(1);
    });

    test('a retry after another failure uses the approval once', () async {
      final cubit = await failedAfterConsent();
      grants.clear();

      await cubit.retry(0);

      expect(cubit.state.turns.single.isComplete, isTrue);
      expect(cubit.state.turns.single.translation, 'Hola');
      // Granted for this retry only, and withdrawn once it ended.
      expect(grants, ['allow', 'revoke']);
      verify(() => repository.allowOnce(_consent)).called(1);
    });

    test('never twice: the next retry asks again', () async {
      final cubit = await failedAfterConsent();
      answers = [fails(_down), fails(_consent)];

      await cubit.retry(0);
      expect(cubit.state.turns.single.error, _down);
      await cubit.retry(0);

      expect(cubit.state.turns.single.error, _consent);
      verify(() => repository.allowOnce(any())).called(1);
    });

    test('is not used once the approval would have expired', () async {
      final cubit = await failedAfterConsent();
      now = now.add(TranslationRepository.consentOnceLifetime);
      answers = [fails(_consent)];

      await cubit.retry(0);

      verifyNever(() => repository.allowOnce(any()));
      expect(cubit.state.turns.single.error, _consent);
    });

    test('is used until then', () async {
      final cubit = await failedAfterConsent();
      now = now.add(
        TranslationRepository.consentOnceLifetime - const Duration(seconds: 1),
      );

      await cubit.retry(0);

      verify(() => repository.allowOnce(_consent)).called(1);
      expect(cubit.state.turns.single.isComplete, isTrue);
    });

    test('is not used when the clock went back', () async {
      final cubit = await failedAfterConsent();
      now = now.subtract(const Duration(minutes: 1));
      await cubit.retry(0);
      verifyNever(() => repository.allowOnce(any()));
    });

    test('is not used for another engine', () async {
      final cubit = await failedAfterConsent();
      engine = claude;
      await cubit.retry(0);
      verifyNever(() => repository.allowOnce(any()));
    });

    test('is not used when the destination changed', () async {
      final cubit = await failedAfterConsent();
      when(() => repository.destinationOf(any()))
          .thenReturn(const PublicInstanceDestination('other.example.org'));
      await cubit.retry(0);
      verifyNever(() => repository.allowOnce(any()));
    });

    test('is not used when the destination is unknown', () async {
      final cubit = await failedAfterConsent();
      when(() => repository.destinationOf(any()))
          .thenThrow(ArgumentError('gone'));
      await cubit.retry(0);
      verifyNever(() => repository.allowOnce(any()));
    });

    test('is not used while another translation runs', () async {
      final cubit = await failedAfterConsent();
      final other = StreamController<TranslationResult>();
      addTearDown(other.close);
      answers = [() => other.stream];
      unawaited(cubit.submit(ConversationSide.b, 'Hola'));
      await pumpEventQueue();

      await cubit.retry(0);

      verifyNever(() => repository.allowOnce(any()));
    });

    test('is withdrawn when another translation starts', () async {
      final cubit = await failedAfterConsent();
      final retried = StreamController<TranslationResult>();
      addTearDown(retried.close);
      answers = [() => retried.stream];
      grants.clear();
      final retry = cubit.retry(0);
      await pumpEventQueue();
      expect(grants, ['allow']);

      await cubit.submit(ConversationSide.b, 'Gracias');

      // Withdrawn before the other text was sent.
      expect(grants, ['allow', 'revoke']);
      retried
        ..add(resultOf('Hola'))
        ..close().ignore();
      await retry;
      expect(grants, ['allow', 'revoke']);
    });

    test('a retry that succeeds keeps nothing', () async {
      answers = [fails(_consent)];
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.submit(ConversationSide.a, 'Hello');
      await cubit.retry(0);
      expect(cubit.state.turns.single.isComplete, isTrue);
      expect(grants, ['revoke']);
    });

    test('a retry stopped for consent again keeps nothing', () async {
      answers = [fails(_consent), fails(_consent), fails(_down)];
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.submit(ConversationSide.a, 'Hello');
      await cubit.retry(0);
      expect(cubit.state.turns.single.error, _consent);
      // Asked again, and given: this retry fails another way.
      await cubit.retry(0);
      expect(cubit.state.turns.single.error, _down);
      await cubit.retry(0);
      // Only the consent given last is used once more.
      verify(() => repository.allowOnce(any())).called(1);
    });

    test('a retry without consent first grants nothing', () async {
      answers = [fails(_down), fails(_down)];
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.submit(ConversationSide.a, 'Hello');
      await cubit.retry(0);
      await cubit.retry(0);
      expect(grants, isEmpty);
    });

    test('removing the turn or clearing forgets the approval', () async {
      final cubit = await failedAfterConsent();
      await cubit.removeTurn(0);
      answers = [fails(_consent), fails(_down)];
      await cubit.submit(ConversationSide.a, 'Hello');
      final id = cubit.state.turns.single.id;
      await cubit.retry(id);
      await cubit.clear();
      verifyNever(() => repository.allowOnce(any()));
    });

    test('closing withdraws the approval of a running retry', () async {
      final cubit = await failedAfterConsent();
      final retried = StreamController<TranslationResult>();
      addTearDown(retried.close);
      answers = [() => retried.stream];
      grants.clear();
      unawaited(cubit.retry(0));
      await pumpEventQueue();

      await cubit.close();

      expect(grants, ['allow', 'revoke']);
    });
  });
}
