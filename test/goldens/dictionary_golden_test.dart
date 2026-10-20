@Tags(['golden', 'skip_very_good_optimization'])
library;

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/dictionary/dictionary.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/voice/voice.dart' show SpeechInputService;
import 'package:translation_repository/translation_repository.dart';

import '../dictionary/helpers/dictionary_helpers.dart';
import '../translate/helpers/helpers.dart'
    show FakeSpeechInput, MockSpeechService;
import 'helpers/golden_helpers.dart';

/// An entry whose IPA the test font can draw (it has no stress marks).
const _hola = DictionaryEntry(
  word: 'hola',
  pronunciation: 'ola',
  partsOfSpeech: ['interjection'],
  senses: [
    DictionarySense(
      definition:
          'A greeting used when meeting someone or acknowledging their '
          'arrival.',
      partOfSpeech: 'interjection',
      translations: ['hello', 'hi'],
    ),
    DictionarySense(
      definition: 'Used to attract someone’s attention.',
      partOfSpeech: 'interjection',
      translations: ['hey'],
      usage: 'informal',
    ),
  ],
  examples: [
    DictionaryExample(
      source: '¡Hola! ¿Cómo estás?',
      translation: 'Hello! How are you?',
    ),
  ],
  synonyms: ['buenas', 'saludos', 'qué tal'],
  etymology: 'Probably from the call “hala”, used to draw attention.',
  relatedWords: ['holita', 'saludar'],
);

const _readyTranslate = TranslateState(
  enginesStatus: EnginesStatus.ready,
  engines: [claudeEngine],
  engine: claudeEngine,
  assistEngine: claudeEngine,
);

/// Pumps [DictionaryView] on a phone with [state], the app's theme, and
/// speech output and voice input available.
Future<void> _pumpDictionary(
  WidgetTester tester, {
  required DictionaryState state,
  Brightness brightness = Brightness.light,
}) async {
  useGoldenDevice(tester, GoldenDevice.phone);
  final dictionary = MockDictionaryCubit();
  whenListen(
    dictionary,
    const Stream<DictionaryState>.empty(),
    initialState: state,
  );
  final translate = MockTranslateCubit();
  whenListen(
    translate,
    const Stream<TranslateState>.empty(),
    initialState: _readyTranslate,
  );
  final speech = MockSpeechService();
  when(() => speech.speaking).thenAnswer((_) => const Stream.empty());
  when(() => speech.current).thenReturn(null);
  final speechInput = FakeSpeechInput();
  await tester.pumpWidget(
    MultiRepositoryProvider(
      providers: [
        RepositoryProvider<SpeechService>.value(value: speech),
        RepositoryProvider<SpeechInputService>.value(
          value: speechInput.service,
        ),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider<TranslateCubit>.value(value: translate),
          BlocProvider<DictionaryCubit>.value(value: dictionary),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: goldenTheme(brightness),
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DictionaryView(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  goldenGroup('Dictionary screen', () {
    testWidgets('empty on a phone (light)', (tester) async {
      await _pumpDictionary(
        tester,
        state: const DictionaryState(target: french, engine: claudeEngine),
      );
      await expectScreenGolden('dictionary_empty_phone_light');
    });

    for (final brightness in [Brightness.light, Brightness.dark]) {
      final look = brightness.name;
      testWidgets('with an entry on a phone ($look)', (tester) async {
        await _pumpDictionary(
          tester,
          brightness: brightness,
          state: const DictionaryState(
            word: 'hola',
            source: spanish,
            target: english,
            engine: claudeEngine,
            status: DictionaryStatus.success,
            entry: _hola,
            lookedUp: 'hola',
          ),
        );
        await expectScreenGolden('dictionary_result_phone_$look');
      });
    }
  });
}
