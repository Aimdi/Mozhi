import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/translate_link.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

class _MockTranslateCubit extends MockCubit<TranslateState>
    implements TranslateCubit;

const _english = Language(code: 'en', name: 'English');
const _spanish = Language(code: 'es', name: 'Spanish', nativeName: 'Español');
const _brazilian = Language(code: 'pt-BR', name: 'Portuguese (Brazil)');
const _french = Language(code: 'fr', name: 'French');

final _mozhiEngine = TranslationEngine.mozhi('google', 'Google');
const _aiEngine = TranslationEngine(
  id: 'ai:claude',
  kind: EngineKind.ai,
  name: 'Claude',
  providerId: 'claude',
);

TranslateState _ready({TranslationEngine? engine}) => TranslateState(
  enginesStatus: EnginesStatus.ready,
  engine: engine ?? _mozhiEngine,
  sourceLanguages: const [Language.auto, _english, _spanish, _brazilian],
  targetLanguages: const [_english, _spanish, _brazilian, _french],
);

void main() {
  setUpAll(() {
    registerFallbackValue(_english);
  });

  group('TranslateLink.fromUri', () {
    test('reads text, from and to', () {
      expect(
        TranslateLink.fromUri(
          Uri.parse('/translate?text=hola%20mundo&from=es&to=en'),
        ),
        const TranslateLink(text: 'hola mundo', from: 'es', to: 'en'),
      );
    });

    test('accepts Google style aliases', () {
      expect(
        TranslateLink.fromUri(Uri.parse('/?q=hi&sl=en&tl=fr')),
        const TranslateLink(text: 'hi', from: 'en', to: 'fr'),
      );
      expect(
        TranslateLink.fromUri(Uri.parse('/?source=en&target=fr')),
        const TranslateLink(from: 'en', to: 'fr'),
      );
    });

    test('keeps the text untrimmed but trims languages', () {
      final link = TranslateLink.fromUri(
        Uri(path: '/', queryParameters: {'text': ' a\nb ', 'to': ' fr '}),
      );
      expect(link?.text, ' a\nb ');
      expect(link?.to, 'fr');
    });

    test('returns null without known parameters', () {
      expect(TranslateLink.fromUri(Uri.parse('/translate')), isNull);
      expect(TranslateLink.fromUri(Uri.parse('/translate?foo=1')), isNull);
      expect(TranslateLink.fromUri(Uri.parse('/?text=%20&to=')), isNull);
    });

    test('hasText is false for missing or blank text', () {
      expect(const TranslateLink(to: 'fr').hasText, isFalse);
      expect(const TranslateLink(text: '  ').hasText, isFalse);
      expect(const TranslateLink(text: 'x').hasText, isTrue);
    });
  });

  group('matchLanguage', () {
    const languages = [Language.auto, _english, _spanish, _brazilian];

    test('matches codes case-insensitively, with _ or -', () {
      expect(matchLanguage('EN', languages), _english);
      expect(matchLanguage('pt_br', languages), _brazilian);
      expect(matchLanguage('auto', languages), Language.auto);
    });

    test('matches English and native names', () {
      expect(matchLanguage('spanish', languages), _spanish);
      expect(matchLanguage('Español', languages), _spanish);
    });

    test('returns null for blank input', () {
      expect(matchLanguage('  ', languages), isNull);
    });

    test('falls back to LanguageMatcher (primary subtag)', () {
      expect(matchLanguage('es-MX', languages), _spanish);
    });
  });

  group('TranslateLink.applyTo', () {
    late _MockTranslateCubit cubit;

    setUp(() {
      cubit = _MockTranslateCubit();
      when(() => cubit.isClosed).thenReturn(false);
    });

    test('selects languages and translates when engines are ready', () async {
      when(() => cubit.state).thenReturn(_ready());

      await const TranslateLink(
        text: 'hola',
        from: 'es',
        to: 'pt-br',
      ).applyTo(cubit);

      verifyInOrder([
        () => cubit.setSource(_spanish),
        () => cubit.setTarget(_brazilian),
        () => cubit.setInputAndTranslate('hola'),
      ]);
    });

    test('does not reselect the current languages', () async {
      when(() => cubit.state).thenReturn(_ready());

      await const TranslateLink(
        text: 'hi',
        from: 'auto',
        to: 'en',
      ).applyTo(cubit);

      verifyNever(() => cubit.setSource(any()));
      verifyNever(() => cubit.setTarget(any()));
      verify(() => cubit.setInputAndTranslate('hi')).called(1);
    });

    test('ignores unknown languages for Mozhi engines', () async {
      when(() => cubit.state).thenReturn(_ready());

      await const TranslateLink(
        text: 'hi',
        from: 'xx',
        to: 'Pirate speak',
      ).applyTo(cubit);

      verifyNever(() => cubit.setSource(any()));
      verifyNever(() => cubit.setTarget(any()));
      verify(() => cubit.setInputAndTranslate('hi')).called(1);
    });

    test('uses a custom target for AI engines', () async {
      when(() => cubit.state).thenReturn(_ready(engine: _aiEngine));

      await const TranslateLink(to: 'Pirate speak').applyTo(cubit);

      verify(() => cubit.setTarget(const Language.custom('Pirate speak')))
          .called(1);
      verifyNever(() => cubit.setInputAndTranslate(any()));
    });

    test('waits for the engines to load', () async {
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      whenListen(
        cubit,
        states.stream,
        initialState: const TranslateState(
          enginesStatus: EnginesStatus.loading,
        ),
      );

      final done = const TranslateLink(text: 'x', to: 'fr').applyTo(cubit);
      await Future<void>.delayed(Duration.zero);
      verifyNever(() => cubit.setInputAndTranslate(any()));

      states.add(_ready());
      await done;
      verify(() => cubit.setTarget(_french)).called(1);
      verify(() => cubit.setInputAndTranslate('x')).called(1);
    });

    test('still translates when loading the engines failed', () async {
      whenListen(
        cubit,
        Stream.value(
          const TranslateState(enginesStatus: EnginesStatus.failure),
        ),
        initialState: const TranslateState(),
      );

      await const TranslateLink(text: 'x').applyTo(cubit);

      verify(() => cubit.setInputAndTranslate('x')).called(1);
    });

    test('gives up waiting after the timeout', () async {
      whenListen(
        cubit,
        const Stream<TranslateState>.empty().asBroadcastStream(),
        initialState: const TranslateState(
          enginesStatus: EnginesStatus.loading,
        ),
      );
      // An empty stream completes: nothing to apply to.
      await const TranslateLink(text: 'x').applyTo(cubit);
      verifyNever(() => cubit.setInputAndTranslate(any()));

      final never = StreamController<TranslateState>.broadcast();
      addTearDown(never.close);
      whenListen(
        cubit,
        never.stream,
        initialState: const TranslateState(
          enginesStatus: EnginesStatus.loading,
        ),
      );
      await const TranslateLink(text: 'y')
          .applyTo(cubit, timeout: const Duration(milliseconds: 10));
      verify(() => cubit.setInputAndTranslate('y')).called(1);
    });

    test('does nothing when the cubit is closed', () async {
      when(() => cubit.state).thenReturn(const TranslateState());
      when(() => cubit.isClosed).thenReturn(true);

      await const TranslateLink(text: 'x').applyTo(cubit);

      verifyNever(() => cubit.setInputAndTranslate(any()));
    });
  });
}
