import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:mozhi/conversation/share/data/share_translations.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:mozhi/usage/models/usage_stats.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers.dart';

class MockUsageTracker extends Mock implements UsageTracker;

final offline = TranslationEngine.offline();

ConversationTurn _turn({
  int id = 0,
  String original = 'Hello',
  ConversationTurnStatus status = ConversationTurnStatus.complete,
  String translation = 'Hola',
  Language source = english,
  Language target = spanish,
}) => ConversationTurn(
  id: id,
  side: source == english ? ConversationSide.a : ConversationSide.b,
  original: original,
  source: source,
  target: target,
  createdAt: sentAt,
  translation: translation,
  status: status,
);

void main() {
  setUpAll(() {
    registerConversationFallbacks();
    registerFallbackValue(
      const ConsentRequiredException(
        kind: ConsentKind.pair,
        destination: PublicInstanceDestination(''),
        engineId: '',
      ),
    );
  });

  late MockTranslationRepository repository;
  late TranslationEngine? engine;
  late List<TranslationEngine> engines;
  late Map<String, StreamController<TranslationResult>> streams;
  late ShareTranslations translations;
  late MockUsageTracker usage;

  /// The translation of [text] by [engine] into [target] (started).
  StreamController<TranslationResult> streamOf(
    TranslationEngine engine,
    Language target, {
    String text = 'Hello',
  }) => streams['${engine.id}>${target.code}:$text']!;

  setUp(() {
    repository = MockTranslationRepository();
    engine = deepl;
    engines = [deepl, claude];
    streams = {};
    usage = MockUsageTracker();
    when(
      () => usage.recordText(
        any(),
        input: any(named: 'input'),
        output: any(named: 'output'),
      ),
    ).thenAnswer((_) => Completer<UsageStats>().future);
    when(
      () => repository.needsConsent(
        any(),
        source: any(named: 'source'),
        target: any(named: 'target'),
      ),
    ).thenReturn(false);
    when(() => repository.privacyMode).thenReturn(PrivacyMode.offlineFirst);
    when(() => repository.consentedProviders).thenReturn(const {});
    when(() => repository.destinationOf(any()))
        .thenReturn(const PublicInstanceDestination('mozhi.example.org'));
    when(() => repository.translate(any(), any())).thenAnswer((invocation) {
      final engine = invocation.positionalArguments[0] as TranslationEngine;
      final request = invocation.positionalArguments[1] as TranslationRequest;
      final controller = StreamController<TranslationResult>();
      streams['${engine.id}>${request.target.code}:${request.text}'] =
          controller;
      return controller.stream;
    });
    translations = ShareTranslations(
      repository: repository,
      engine: () => engine,
      engines: () => engines,
      options: () => const TranslationOptions(
        context: 'secret context',
        instructions: 'one-off',
        formality: Formality.more,
      ),
      usageTracker: usage,
    );
  });

  tearDown(() => translations.dispose());

  group('textOf', () {
    test('is the original in the language it was said in', () {
      expect(translations.textOf(_turn(), english), (
        text: 'Hello',
        status: ShareTextStatus.original,
      ));
    });

    test('is the conversation translation in its target language', () {
      expect(translations.textOf(_turn(), spanish), (
        text: 'Hola',
        status: ShareTextStatus.translated,
      ));
      expect(
        translations.textOf(
          _turn(status: ConversationTurnStatus.translating, translation: 'Ho'),
          spanish,
        ),
        (text: 'Ho', status: ShareTextStatus.translating),
      );
      expect(
        translations.textOf(
          _turn(status: ConversationTurnStatus.failed, translation: ''),
          spanish,
        ),
        (text: 'Hello', status: ShareTextStatus.untranslated),
      );
    });

    test('waits for a language that is not started yet', () {
      expect(translations.textOf(_turn(), french), (
        text: '',
        status: ShareTextStatus.translating,
      ));
    });
  });

  test('compares languages by normalised code', () {
    expect(
      ShareTranslations.sameLanguage(
        const Language(code: 'EN', name: 'English'),
        english,
      ),
      isTrue,
    );
    expect(ShareTranslations.sameLanguage(english, french), isFalse);
  });

  group('ensure', () {
    test('translates other languages once with the host engine', () async {
      final changes = <void>[];
      translations.changes.listen(changes.add);
      translations
        ..ensure([_turn()], [english, spanish, french])
        ..ensure([_turn()], [french]);

      final request =
          verify(() => repository.translate(deepl, captureAny()))
                  .captured
                  .single
              as TranslationRequest;
      expect(request.text, 'Hello');
      expect(request.source, english);
      expect(request.target, french);
      // No conversation context or one-off instructions for guests.
      expect(request.options.context, isEmpty);
      expect(request.options.instructions, isEmpty);
      expect(request.options.formality, Formality.more);

      streamOf(deepl, french).add(resultOf('Bon', isComplete: false));
      await settle();
      expect(translations.textOf(_turn(), french), (
        text: 'Bon',
        status: ShareTextStatus.translating,
      ));

      streamOf(deepl, french).add(resultOf('Bonjour'));
      await streamOf(deepl, french).close();
      await settle();
      expect(translations.textOf(_turn(), french), (
        text: 'Bonjour',
        status: ShareTextStatus.translated,
      ));
      expect(changes, isNotEmpty);
      expect(translations.languageStates([french]), [
        const ShareLanguageState(
          language: french,
          mode: ShareLanguageMode.engine,
        ),
      ]);
      // Mozhi engines have no provider: nothing is counted.
      verifyNever(
        () => usage.recordText(
          any(),
          input: any(named: 'input'),
          output: any(named: 'output'),
        ),
      );
    });

    test('reports the engine while it translates', () {
      translations.ensure([_turn()], [french]);

      expect(translations.languageStates([french, german]), [
        const ShareLanguageState(
          language: french,
          mode: ShareLanguageMode.engine,
          pending: 1,
        ),
      ]);
    });

    test('counts what a provider translated', () async {
      engine = claude;
      translations.ensure([_turn()], [french]);
      streamOf(claude, french).add(resultOf('Bonjour', engine: claude));
      await streamOf(claude, french).close();
      await settle();

      verify(
        () => usage.recordText('claude', input: 'Hello', output: 'Bonjour'),
      ).called(1);
    });

    test('does not count cached results', () async {
      engine = claude;
      translations.ensure([_turn()], [french]);
      streamOf(claude, french).add(
        const TranslationResult(
          engineId: 'ai:claude',
          engineName: 'Claude',
          text: 'Bonjour',
          fromCache: true,
        ),
      );
      await streamOf(claude, french).close();
      await settle();

      verifyNever(
        () => usage.recordText(
          any(),
          input: any(named: 'input'),
          output: any(named: 'output'),
        ),
      );
    });

    test('runs at most two translations at a time', () async {
      translations.ensure([_turn()], [french, german, ...languages]);
      const italian = Language(code: 'it', name: 'Italian');
      translations.ensure([_turn()], [french, german, italian]);

      expect(streams.keys, ['mozhi:deepl>fr:Hello', 'mozhi:deepl>de:Hello']);
      await streamOf(deepl, french).close();
      await settle();
      expect(streams.keys, contains('mozhi:deepl>it:Hello'));
    });

    test('forgets the translations of removed turns', () async {
      translations.ensure([_turn()], [french]);
      expect(streamOf(deepl, french).hasListener, isTrue);

      translations.ensure([], [french]);
      await settle();
      expect(streamOf(deepl, french).hasListener, isFalse);
      expect(translations.languageStates([french]), isEmpty);
    });

    test('translates on the device when the engine needs consent', () async {
      engines = [deepl, offline];
      when(
        () => repository.needsConsent(
          deepl,
          source: any(named: 'source'),
          target: any(named: 'target'),
        ),
      ).thenReturn(true);

      translations.ensure([_turn()], [french]);
      streamOf(offline, french).add(resultOf('Bonjour', engine: offline));
      await streamOf(offline, french).close();
      await settle();

      verifyNever(() => repository.translate(deepl, any()));
      expect(translations.textOf(_turn(), french).text, 'Bonjour');
      expect(
        translations.languageStates([french]).single.mode,
        ShareLanguageMode.onDevice,
      );
    });

    test('waits for consent when the device cannot translate it', () async {
      engines = [deepl, offline];
      when(
        () => repository.needsConsent(
          deepl,
          source: any(named: 'source'),
          target: any(named: 'target'),
        ),
      ).thenReturn(true);

      translations.ensure([_turn(), _turn(id: 1, original: 'Bye')], [french]);
      streamOf(offline, french).addError(StateError('pair not installed'));
      await settle();
      streamOf(
        offline,
        french,
        text: 'Bye',
      ).addError(StateError('pair not installed'));
      await settle();

      verifyNever(() => repository.translate(deepl, any()));
      expect(translations.textOf(_turn(), french), (
        text: 'Hello',
        status: ShareTextStatus.untranslated,
      ));
      final state = translations.languageStates([french]).single;
      expect(state.mode, ShareLanguageMode.needsConsent);
      expect(state.waiting, 2);
      expect(state.consent?.kind, ConsentKind.pair);
      expect(state.consent?.engineId, deepl.id);
      expect(state.consent?.source, 'en');
      expect(state.consent?.target, 'fr');
      expect(
        state.consent?.destination,
        const PublicInstanceDestination('mozhi.example.org'),
      );
    });

    test('sends nothing without consent and without the device', () {
      when(
        () => repository.needsConsent(
          deepl,
          source: any(named: 'source'),
          target: any(named: 'target'),
        ),
      ).thenReturn(true);

      translations.ensure([_turn()], [french]);

      verifyNever(() => repository.translate(any(), any()));
      expect(
        translations.languageStates([french]).single.mode,
        ShareLanguageMode.needsConsent,
      );
    });

    test('names the consent of a cloud provider and offline only', () {
      when(
        () => repository.needsConsent(
          any(),
          source: any(named: 'source'),
          target: any(named: 'target'),
        ),
      ).thenReturn(true);
      when(() => repository.destinationOf('ai:claude'))
          .thenReturn(const CloudProviderDestination('Claude'));
      engine = claude;
      translations.ensure([_turn()], [french]);
      expect(
        translations.languageStates([french]).single.consent?.kind,
        ConsentKind.cloudProvider,
      );

      when(() => repository.privacyMode).thenReturn(PrivacyMode.offlineOnly);
      translations.ensure([_turn(), _turn(id: 1)], [french]);
      expect(
        translations.languageStates([french]).single.consent?.kind,
        ConsentKind.offlineOnly,
      );
    });

    test('names a public destination for an unknown provider', () {
      when(
        () => repository.needsConsent(
          any(),
          source: any(named: 'source'),
          target: any(named: 'target'),
        ),
      ).thenReturn(true);
      when(() => repository.destinationOf(any())).thenThrow(ArgumentError());

      translations.ensure([_turn()], [french]);

      expect(
        translations.languageStates([french]).single.consent?.destination,
        const PublicInstanceDestination(''),
      );
    });

    test('waits for consent the repository asks for', () async {
      translations.ensure([_turn()], [french]);
      streamOf(deepl, french).addError(
        const ConsentRequiredException(
          kind: ConsentKind.pair,
          destination: PublicInstanceDestination('mozhi.example.org'),
          engineId: 'mozhi:deepl',
          source: 'en',
          target: 'fr',
        ),
      );
      await settle();

      expect(
        translations.languageStates([french]).single.mode,
        ShareLanguageMode.needsConsent,
      );
    });

    test('falls back to the device when the engine fails', () async {
      engines = [deepl, offline];
      translations.ensure([_turn()], [french]);
      streamOf(deepl, french).addError(StateError('offline'));
      await settle();
      streamOf(offline, french).add(resultOf('Bonjour', engine: offline));
      await streamOf(offline, french).close();
      await settle();

      expect(translations.textOf(_turn(), french).text, 'Bonjour');
    });

    test('is unavailable when everything fails', () async {
      translations.ensure([_turn()], [french]);
      streamOf(deepl, french).addError(StateError('down'));
      await settle();

      expect(
        translations.textOf(_turn(), french).status,
        ShareTextStatus.untranslated,
      );
      expect(
        translations.languageStates([french]).single.mode,
        ShareLanguageMode.unavailable,
      );
    });

    test('is unavailable without any engine', () {
      engine = null;
      engines = [];
      translations.ensure([_turn()], [french]);

      verifyNever(() => repository.translate(any(), any()));
      expect(
        translations.languageStates([french]).single.mode,
        ShareLanguageMode.unavailable,
      );
    });

    test('fails an empty translation', () async {
      translations.ensure([_turn()], [french]);
      await streamOf(deepl, french).close();
      await settle();

      expect(
        translations.languageStates([french]).single.mode,
        ShareLanguageMode.unavailable,
      );
    });

    test('translates with the offline engine as the host engine', () async {
      engine = offline;
      engines = [offline];
      translations.ensure([_turn()], [french]);
      streamOf(offline, french).addError(StateError('missing'));
      await settle();

      // No second try with the same engine.
      expect(
        translations.languageStates([french]).single.mode,
        ShareLanguageMode.unavailable,
      );
    });
  });

  group('only what guests read', () {
    final turns = [
      _turn(),
      _turn(id: 1, original: 'Bye'),
      _turn(id: 2, original: 'Thanks'),
    ];

    test('counts what is still to translate', () async {
      translations.ensure(turns, [french]);
      expect(translations.languageStates([french]).single.pending, 3);

      streamOf(deepl, french).add(resultOf('Bonjour'));
      await streamOf(deepl, french).close();
      await settle();
      expect(translations.languageStates([french]).single.pending, 2);
    });

    test('stops queued and running work for a language nobody reads', () async {
      final changes = <void>[];
      translations.changes.listen(changes.add);
      translations.ensure(turns, [french, german]);
      expect(streams.keys, ['mozhi:deepl>fr:Hello', 'mozhi:deepl>de:Hello']);

      translations.ensure(turns, [german]);

      expect(streamOf(deepl, french).hasListener, isFalse);
      expect(streamOf(deepl, german).hasListener, isTrue);
      // The freed place went to German, not to a French turn.
      expect(streams.keys, [
        'mozhi:deepl>fr:Hello',
        'mozhi:deepl>de:Hello',
        'mozhi:deepl>de:Bye',
      ]);
      expect(
        [
          for (final state in translations.languageStates([french, german]))
            state.language,
        ],
        [german],
      );
      expect(translations.textOf(turns.first, french).text, isEmpty);

      translations.ensure(turns, []);
      expect(streamOf(deepl, german).hasListener, isFalse);
      expect(streams, hasLength(3));
      expect(translations.languageStates([french, german]), isEmpty);
      await settle();
      expect(changes, isNotEmpty);
    });

    test('keeps the finished translations of a language read before', () async {
      translations.ensure([turns.first], [french]);
      streamOf(deepl, french).add(resultOf('Bonjour'));
      await streamOf(deepl, french).close();
      await settle();

      translations.ensure(turns, [], keep: [french]);
      expect(streams, hasLength(1));
      expect(translations.textOf(turns.first, french).text, 'Bonjour');

      // Read again: only what is missing is translated.
      translations.ensure(turns, [french]);
      expect(streams.keys, [
        'mozhi:deepl>fr:Hello',
        'mozhi:deepl>fr:Bye',
        'mozhi:deepl>fr:Thanks',
      ]);
      expect(translations.textOf(turns.first, french).text, 'Bonjour');

      translations.ensure(turns, []);
      expect(translations.textOf(turns.first, french).text, isEmpty);
    });

    test('keeps nothing unfinished of a language read before', () {
      translations
        ..ensure([turns.first], [french])
        ..ensure([turns.first], [], keep: [french]);

      expect(streamOf(deepl, french).hasListener, isFalse);
      expect(translations.languageStates([french]), isEmpty);
    });

    test('shows the host any language still being translated', () {
      translations.ensure([turns.first], [french]);

      expect(translations.languageStates([german]), [
        const ShareLanguageState(
          language: french,
          mode: ShareLanguageMode.engine,
          pending: 1,
        ),
      ]);
    });
  });

  group('consent', () {
    final fromEnglish = _turn();
    final fromSpanish = _turn(
      id: 1,
      original: 'Hola',
      source: spanish,
      target: english,
    );
    const englishToFrench = ConsentRequiredException(
      kind: ConsentKind.pair,
      destination: PublicInstanceDestination('mozhi.example.org'),
      engineId: 'mozhi:deepl',
      source: 'en',
      target: 'fr',
    );
    const spanishToFrench = ConsentRequiredException(
      kind: ConsentKind.pair,
      destination: PublicInstanceDestination('mozhi.example.org'),
      engineId: 'mozhi:deepl',
      source: 'es',
      target: 'fr',
    );

    void needConsent() => when(
      () => repository.needsConsent(
        deepl,
        source: any(named: 'source'),
        target: any(named: 'target'),
      ),
    ).thenReturn(true);

    bool sameConsent(ConsentRequiredException? a, ConsentRequiredException b) =>
        a != null &&
        a.kind == b.kind &&
        a.engineId == b.engineId &&
        a.destination == b.destination &&
        a.source == b.source &&
        a.target == b.target;

    test('is asked for one language pair at a time', () {
      needConsent();
      translations.ensure(
        [fromEnglish, fromSpanish, _turn(id: 2, original: 'Bye')],
        [french],
      );

      var state = translations.languageStates([french]).single;
      expect(sameConsent(state.consent, englishToFrench), isTrue);
      expect(state.waiting, 2);

      translations.retry(french, consent: state.consent);
      verify(() => repository.translate(deepl, any())).called(2);
      state = translations.languageStates([french]).single;
      expect(sameConsent(state.consent, spanishToFrench), isTrue);
      expect(state.waiting, 1);
      expect(state.pending, 2);
    });

    test('withdraws the approval once its turns all started', () async {
      needConsent();
      translations.ensure([fromEnglish], [french]);
      final consent = translations.languageStates([french]).single.consent!;

      translations.retry(french, consent: consent);

      verify(() => repository.translate(deepl, any())).called(1);
      verify(() => repository.revokeOnce(consent)).called(1);
    });

    test('withdraws what turns dropped before starting did not use', () {
      needConsent();
      final turns = [
        fromEnglish,
        _turn(id: 2, original: 'Bye'),
        _turn(id: 3, original: 'Thanks'),
      ];
      translations.ensure(turns, [french]);
      final consent = translations.languageStates([french]).single.consent!;

      translations.retry(french, consent: consent);
      // Two run, one waits for a place.
      verify(() => repository.translate(deepl, any())).called(2);
      verifyNever(() => repository.revokeOnce(any()));

      // The guest left.
      translations.ensure(turns, []);
      verify(() => repository.revokeOnce(consent)).called(1);
    });

    test('withdraws what is left when disposed', () async {
      needConsent();
      final turns = [
        fromEnglish,
        _turn(id: 2, original: 'Bye'),
        _turn(id: 3, original: 'Thanks'),
      ];
      translations.ensure(turns, [french]);
      final consent = translations.languageStates([french]).single.consent!;
      translations.retry(french, consent: consent);

      await translations.dispose();
      verify(() => repository.revokeOnce(consent)).called(1);
    });

    test('withdraws an approval nothing waits for', () {
      translations.retry(french, consent: englishToFrench);

      verify(() => repository.revokeOnce(englishToFrench)).called(1);
      verifyNever(() => repository.translate(any(), any()));
    });

    test('waits for every retry of the same consent', () async {
      needConsent();
      final turns = [
        fromEnglish,
        _turn(id: 2, original: 'Bye'),
        _turn(id: 3, original: 'Thanks'),
        _turn(id: 4, original: 'Later'),
      ];
      translations
        ..ensure(turns, [french])
        ..retry(french);
      // The approval was used up meanwhile: the first turn waits again,
      // and the host allows it again.
      streamOf(deepl, french).addError(englishToFrench);
      await settle();
      final again = translations.languageStates([french]).single;
      expect(again.waiting, 1);
      translations.retry(french, consent: again.consent);

      await streamOf(deepl, french, text: 'Bye').close();
      await settle();
      // The first retry's turns all started; the second's waits.
      verifyNever(() => repository.revokeOnce(any()));
      await streamOf(deepl, french, text: 'Thanks').close();
      await settle();
      verify(() => repository.revokeOnce(any())).called(1);
    });

    test('sends the turns the host allowed first', () async {
      when(
        () => repository.needsConsent(
          deepl,
          source: any(named: 'source'),
          target: french,
        ),
      ).thenReturn(true);
      translations.ensure(
        [
          fromEnglish,
          _turn(id: 2, original: 'Bye'),
          _turn(id: 3, original: 'Thanks'),
        ],
        [german, french],
      );
      expect(streams.keys, ['mozhi:deepl>de:Hello', 'mozhi:deepl>de:Bye']);

      translations.retry(french);
      await streamOf(deepl, german).close();
      await settle();

      expect(streams.keys.last, 'mozhi:deepl>fr:Hello');
    });

    test('a failed withdrawal does not break the sharing', () {
      when(() => repository.revokeOnce(any())).thenThrow(StateError('x'));

      expect(
        () => translations.retry(french, consent: englishToFrench),
        returnsNormally,
      );
    });
  });

  group('retry', () {
    test('sends what waited once the host consented', () async {
      when(
        () => repository.needsConsent(
          deepl,
          source: any(named: 'source'),
          target: any(named: 'target'),
        ),
      ).thenReturn(true);
      translations.ensure([_turn()], [french]);
      verifyNever(() => repository.translate(any(), any()));

      translations.retry(german);
      verifyNever(() => repository.translate(any(), any()));

      translations.retry(french);
      verify(() => repository.translate(deepl, any())).called(1);
      streamOf(deepl, french).add(resultOf('Bonjour'));
      await streamOf(deepl, french).close();
      await settle();
      expect(translations.textOf(_turn(), french).text, 'Bonjour');

      // A new turn is checked again.
      translations.ensure([_turn(), _turn(id: 1)], [french]);
      expect(
        translations.languageStates([french]).single.mode,
        ShareLanguageMode.needsConsent,
      );
    });
  });

  test('stops everything when disposed', () async {
    translations.ensure([_turn()], [french]);
    final stream = streamOf(deepl, french);

    await translations.dispose();
    translations
      ..ensure([_turn(id: 1)], [french])
      ..retry(french);

    expect(stream.hasListener, isFalse);
    expect(streams, hasLength(1));
  });
}
