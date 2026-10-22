import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/dictionary/dictionary.dart';
import 'package:mozhi/offline/view/dictionary_packs_page.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers/helpers.dart';
import '../data/dictionary_pack_fixtures.dart';
import '../helpers/dictionary_helpers.dart';

const _readyWithAi = TranslateState(
  enginesStatus: EnginesStatus.ready,
  engines: [googleEngine, claudeEngine],
  engine: googleEngine,
  assistEngine: claudeEngine,
);

const _readyWithoutAi = TranslateState(
  enginesStatus: EnginesStatus.ready,
  engines: [googleEngine],
  engine: googleEngine,
);

void main() {
  setUpAll(registerDictionaryFallbacks);

  late MockTranslateCubit translateCubit;
  late MockSettingsCubit settingsCubit;
  late MockTranslationRepository repository;
  late MemoryDictionaryPackStorage storage;
  late DictionaryPacks packs;
  late DictionaryPackInfo es;

  setUp(() {
    translateCubit = MockTranslateCubit();
    settingsCubit = MockSettingsCubit();
    repository = MockTranslationRepository();
    when(() => settingsCubit.state).thenReturn(const AppSettings());
    when(() => translateCubit.loadEngines(refresh: any(named: 'refresh')))
        .thenAnswer((_) async {});
    stubLookUp(repository, () async => gatoEntry);
    final bytes = spanishPack();
    es = packInfo('es', bytes);
    storage = MemoryDictionaryPackStorage()..put(storedPack(es), bytes);
    packs = DictionaryPacks(
      catalog: DictionaryPackCatalog([es]),
      storage: storage,
    );
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    DictionaryPage page = const DictionaryPage(),
    TranslateState state = _readyWithAi,
  }) async {
    tester.view
      ..physicalSize = const Size(600, 1600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    whenListen(
      translateCubit,
      const Stream<TranslateState>.empty(),
      initialState: state,
    );
    await tester.pumpApp(
      RepositoryProvider<DictionaryPacks>.value(
        value: packs,
        child: RepositoryProvider<TranslationRepository>.value(
          value: repository,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<TranslateCubit>.value(value: translateCubit),
              BlocProvider<SettingsCubit>.value(value: settingsCubit),
            ],
            child: page,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  void verifyNoAiLookUp() => verifyNever(
    () => repository.lookUp(
      any(),
      any(),
      source: any(named: 'source'),
      target: any(named: 'target'),
      uiLanguage: any(named: 'uiLanguage'),
      verbosity: any(named: 'verbosity'),
    ),
  );

  group('with offline dictionaries', () {
    testWidgets('the greeting says where entries come from', (tester) async {
      await pumpPage(tester);
      expect(
        find.text(
          'Meanings, pronunciation and examples from your offline '
          'dictionaries, then your AI provider.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('the greeting without AI', (tester) async {
      await pumpPage(tester, state: _readyWithoutAi);
      expect(
        find.text(
          'Meanings, pronunciation and examples from your offline '
          'dictionaries, on this device.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('dictionary_no_engine')), findsNothing);
    });

    testWidgets('answers from the dictionary, crediting it', (tester) async {
      await pumpPage(
        tester,
        page: const DictionaryPage(word: 'gato', autoLookUp: true),
      );
      await tester.pump();
      expect(find.byType(DictionaryEntryTabs), findsOneWidget);
      expect(find.byKey(const Key('dictionary_headword')), findsOneWidget);
      expect(
        find.textContaining('cat  (masculine)', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('From Wiktionary · CC BY-SA 4.0'), findsOneWidget);
      expect(find.text('AI-generated'), findsNothing);
      expect(find.byKey(const Key('dictionary_more_detail')), findsOneWidget);
      verifyNoAiLookUp();
    });

    testWidgets('More detail asks the AI', (tester) async {
      await pumpPage(
        tester,
        page: const DictionaryPage(word: 'gato', autoLookUp: true),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('dictionary_more_detail')));
      await tester.pump();
      await tester.pump();
      verify(
        () => repository.lookUp(
          claudeEngine,
          'gato',
          source: any(named: 'source'),
          target: any(named: 'target'),
          uiLanguage: any(named: 'uiLanguage'),
          verbosity: any(named: 'verbosity'),
        ),
      ).called(1);
      expect(find.text('AI-generated'), findsOneWidget);
      expect(find.text('From Wiktionary · CC BY-SA 4.0'), findsNothing);
      expect(
        find.textContaining('A small domesticated feline.', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('no More detail without AI', (tester) async {
      await pumpPage(
        tester,
        state: _readyWithoutAi,
        page: const DictionaryPage(word: 'gato', autoLookUp: true),
      );
      await tester.pump();
      expect(find.byType(DictionaryEntryTabs), findsOneWidget);
      expect(find.byKey(const Key('dictionary_more_detail')), findsNothing);
    });

    testWidgets('the credit opens the attribution', (tester) async {
      final opened = <Uri>[];
      final launcher = LinkLauncher.launcher;
      LinkLauncher.launcher = (uri) async {
        opened.add(uri);
        return true;
      };
      addTearDown(() => LinkLauncher.launcher = launcher);
      await pumpPage(
        tester,
        page: const DictionaryPage(word: 'gato', autoLookUp: true),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('dictionary_offline_source')));
      await tester.pumpAndSettle();
      expect(find.byType(DictionaryAttributionDialog), findsOneWidget);
      expect(find.text('Spanish entries from Wiktionary.'), findsOneWidget);
      expect(find.text('Data of 2026-10-01'), findsOneWidget);
      // The pack names no source page.
      expect(
        find.byKey(const Key('dictionary_attribution_source')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('dictionary_attribution_license')));
      await tester.pump();
      expect(opened, [
        Uri.parse('https://creativecommons.org/licenses/by-sa/4.0/'),
      ]);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(DictionaryAttributionDialog), findsNothing);
    });

    testWidgets('an inflected form shows its lemma', (tester) async {
      await pumpPage(
        tester,
        page: const DictionaryPage(word: 'gatos', autoLookUp: true),
      );
      await tester.pump();
      expect(find.text('“gatos” is a form of “gato”'), findsOneWidget);
    });

    testWidgets('without AI, a miss offers similar words', (tester) async {
      await pumpPage(
        tester,
        state: _readyWithoutAi,
        page: const DictionaryPage(word: 'gatoo', from: 'es', autoLookUp: true),
      );
      await tester.pump();
      expect(find.byKey(const Key('dictionary_not_found')), findsOneWidget);
      expect(
        find.text(
          'Your offline dictionaries don’t have it. Add an AI provider to '
          'look up any word.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('dictionary_suggestions')), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('dictionary_suggestion:gatos')),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('“gatos” is a form of “gato”'), findsOneWidget);
      verifyNoAiLookUp();
    });

    testWidgets('without a dictionary for the language, says how to get '
        'one', (tester) async {
      await pumpPage(
        tester,
        state: _readyWithoutAi,
        page: const DictionaryPage(word: 'chat', from: 'fr', autoLookUp: true),
      );
      await tester.pump();
      expect(
        find.text('No offline dictionary for French is downloaded.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('dictionary_get_packs')));
      await tester.pumpAndSettle();
      expect(find.byType(DictionaryPacksPage), findsOneWidget);
      expect(find.text('Spanish'), findsWidgets);
    });

    testWidgets('a miss with AI asks the AI', (tester) async {
      await pumpPage(
        tester,
        page: const DictionaryPage(word: 'perro', autoLookUp: true),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('AI-generated'), findsOneWidget);
    });

    testWidgets('an AI entry says how much personal data stayed', (
      tester,
    ) async {
      stubLookUp(repository, () async => gatoEntry.withMaskedPersonalData(2));
      await pumpPage(
        tester,
        page: const DictionaryPage(word: 'perro', autoLookUp: true),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('dictionary_personal_data')), findsOneWidget);
    });
  });

  group('without offline dictionaries', () {
    setUp(() => storage.delete('es'));

    testWidgets('no AI and no dictionary: says how to get either', (
      tester,
    ) async {
      await pumpPage(tester, state: _readyWithoutAi);
      expect(find.byKey(const Key('dictionary_no_source')), findsOneWidget);
      expect(find.text('Look up words offline or with AI'), findsOneWidget);
      expect(find.byKey(const Key('dictionary_get_packs')), findsOneWidget);
      expect(
        find.byKey(const Key('dictionary_set_up_providers')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('dictionary_get_packs')));
      await tester.pumpAndSettle();
      expect(find.byType(DictionaryPacksPage), findsOneWidget);
    });

    testWidgets('with AI: the usual greeting', (tester) async {
      await pumpPage(tester);
      expect(
        find.text(
          'Meanings, pronunciation and examples from your AI provider.',
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('an AI entry without personal data shows no note', (
    tester,
  ) async {
    await tester.pumpApp(
      Scaffold(
        body: DictionaryEntryTabs(entry: gatoEntry, onWordTap: (_) {}),
      ),
    );
    expect(find.byKey(const Key('dictionary_personal_data')), findsNothing);
    expect(find.text('AI-generated'), findsOneWidget);
  });
}
