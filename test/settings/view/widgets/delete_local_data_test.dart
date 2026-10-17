import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

class _MockHistoryRepository extends Mock implements HistoryRepository;

class _MockSettingsRepository extends Mock implements SettingsRepository;

class _MockOfflineTranslator extends Mock implements OfflineTranslator;

/// A store that cannot be cleared at once.
class _PlainStore implements KeyValueStore {
  final values = <String, String>{'a': '1'};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

const _withKey = AiProviderConfig(
  id: 'p1',
  name: 'Claude',
  provider: LlmProvider.anthropic,
  baseUrl: 'https://api.anthropic.com/v1',
  model: 'claude-opus-5-5',
  apiKey: 'sk-secret',
);

const _withoutKey = AiProviderConfig(
  id: 'p2',
  name: 'Local',
  provider: LlmProvider.ollama,
  baseUrl: 'http://localhost:11434',
  model: 'qwen3',
);

HistoryEntry _entry(String id) => HistoryEntry(
  id: id,
  text: 'text $id',
  translation: 'translation $id',
  source: Language.auto,
  target: const Language(code: 'fr', name: 'French'),
  engineId: 'mozhi:google',
  engineName: 'Google',
  createdAt: DateTime(2026),
);

void main() {
  setUpAll(() {
    registerFallbacks();
    registerFallbackValue(const AppSettings());
  });

  late MockHistoryCubit history;
  late MockSettingsCubit settings;
  late _MockHistoryRepository historyRepository;
  late _MockSettingsRepository settingsRepository;
  late _MockOfflineTranslator offline;
  late MockTranslateCubit translate;
  late MemoryStore preferences;

  setUp(() {
    history = createHistoryCubit(
      HistoryState(
        status: HistoryStatus.ready,
        entries: [_entry('1'), _entry('2')],
      ),
    );
    when(history.deleteAll).thenAnswer((_) async {});
    when(() => history.search(any())).thenReturn(null);
    settings = createSettingsCubit(
      const AppSettings(providers: [_withKey, _withoutKey]),
    );
    historyRepository = _MockHistoryRepository();
    when(historyRepository.storedLength).thenAnswer((_) async => 3 * 1024);
    settingsRepository = _MockSettingsRepository();
    when(() => settingsRepository.save(any())).thenAnswer((_) async {});
    offline = _MockOfflineTranslator();
    when(() => offline.isAvailable).thenReturn(true);
    when(offline.downloadedLanguages).thenAnswer((_) async => {'de', 'en'});
    when(() => offline.deleteLanguage(any())).thenAnswer((_) async {});
    translate = MockTranslateCubit();
    preferences = MemoryStore({'settings.v1': '{}', 'presets.v1': '[]'});
  });

  LocalDataEraser eraser({KeyValueStore? store, bool withOptional = true}) =>
      LocalDataEraser(
        history: history,
        settings: settings,
        historyRepository: withOptional ? historyRepository : null,
        settingsRepository: withOptional ? settingsRepository : null,
        preferences: withOptional ? store ?? preferences : null,
        offline: withOptional ? offline : null,
        translate: withOptional ? translate : null,
      );

  group(LocalDataEraser, () {
    test('summarizes what it deletes', () async {
      final summary = await eraser().summarize();

      expect(summary.historyEntries, 2);
      expect(summary.historyLength, 3 * 1024);
      expect(summary.apiKeys, 1);
      expect(summary.offlineModels, 2);
    });

    test('leaves out what it cannot find out', () async {
      when(historyRepository.storedLength).thenThrow(StateError('disk'));
      when(offline.downloadedLanguages).thenThrow(StateError('ml kit'));

      final summary = await eraser().summarize();

      expect(summary.historyLength, isNull);
      expect(summary.offlineModels, 0);
      final bare = await eraser(withOptional: false).summarize();
      expect(bare.historyLength, isNull);
      expect(bare.offlineModels, 0);
    });

    test('counts no models without an offline engine', () async {
      when(() => offline.isAvailable).thenReturn(false);

      expect((await eraser().summarize()).offlineModels, 0);
    });

    test('deletes everything and resets the settings', () async {
      await eraser().erase();

      verify(history.deleteAll).called(1);
      verify(() => offline.deleteLanguage('de')).called(1);
      verify(() => offline.deleteLanguage('en')).called(1);
      final change =
          verify(() => settings.update(captureAny())).captured.single
              as AppSettings Function(AppSettings);
      expect(
        change(const AppSettings(providers: [_withKey])),
        const AppSettings(),
      );
      verify(() => settingsRepository.save(const AppSettings())).called(1);
      expect(preferences.values, isEmpty);
      verify(translate.clear).called(1);
      verify(() => history.search('')).called(1);
    });

    test('leaves stores alone that cannot be cleared', () async {
      final store = _PlainStore();

      await eraser(store: store).erase();

      expect(store.values, {'a': '1'});
    });

    test('works without the optional parts', () async {
      await eraser(withOptional: false).erase();

      verify(history.deleteAll).called(1);
      verify(() => settings.update(any())).called(1);
    });

    test('tries every part and rethrows the first error', () async {
      when(history.deleteAll).thenAnswer((_) => Future.error(StateError('a')));
      when(() => offline.deleteLanguage(any()))
          .thenAnswer((_) => Future.error(ArgumentError('b')));

      await expectLater(eraser().erase(), throwsStateError);
      verify(() => settings.update(any())).called(1);
      expect(preferences.values, isEmpty);
    });

    testWidgets('of reads what the app provides', (tester) async {
      late LocalDataEraser found;
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<HistoryRepository>.value(
              value: historyRepository,
            ),
            RepositoryProvider<KeyValueStore>.value(value: preferences),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<HistoryCubit>.value(value: history),
              BlocProvider<SettingsCubit>.value(value: settings),
            ],
            child: Builder(
              builder: (context) {
                found = LocalDataEraser.of(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      expect(found.history, same(history));
      expect(found.settings, same(settings));
      expect(found.historyRepository, same(historyRepository));
      expect(found.preferences, same(preferences));
      expect(found.settingsRepository, isNull);
      expect(found.offline, isNull);
      expect(found.translate, isNull);
    });
  });

  group('formatStoredSize', () {
    test('uses B, KB and MB', () async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      expect(formatStoredSize(l10n, 512), '512 B');
      expect(formatStoredSize(l10n, 3 * 1024), '3 KB');
      expect(formatStoredSize(l10n, 1536 * 1024), '1.5 MB');
    });
  });

  group(DeleteLocalDataDialog, () {
    Future<void> pump(WidgetTester tester, LocalDataSummary summary) =>
        tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            home: Scaffold(body: DeleteLocalDataDialog(summary: summary)),
          ),
        );

    testWidgets('lists what is deleted, with sizes', (tester) async {
      await pump(
        tester,
        const LocalDataSummary(
          historyEntries: 2,
          historyLength: 3 * 1024,
          apiKeys: 1,
          offlineModels: 2,
        ),
      );

      expect(find.text('Delete all local data?'), findsOneWidget);
      expect(
        find.text('Translation history: 2 translations (3 KB)'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Settings, presets, glossaries, usage counters and cached data',
        ),
        findsOneWidget,
      );
      expect(find.text('1 API key'), findsOneWidget);
      expect(
        find.text('2 offline language models (about 30 MB each)'),
        findsOneWidget,
      );
      expect(find.textContaining("can't be undone"), findsOneWidget);
    });

    testWidgets('leaves out unknown sizes and missing models', (tester) async {
      await pump(tester, const LocalDataSummary(historyEntries: 1, apiKeys: 0));

      expect(find.text('Translation history: 1 translation'), findsOneWidget);
      expect(find.text('API keys (none saved)'), findsOneWidget);
      expect(find.textContaining('offline language model'), findsNothing);
    });
  });

  group('confirmDeleteLocalData', () {
    late MockGoRouter router;

    setUp(() => router = createRouter());

    Future<void> pump(WidgetTester tester) async {
      tester.setScreenSize(const Size(800, 1200));
      await tester.pumpView(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  confirmDeleteLocalData(context, eraser: eraser()),
              child: const Text('delete'),
            ),
          ),
        ),
        settings: settings,
        history: history,
        router: router,
      );
      await tester.tap(find.text('delete'));
      await tester.pumpAndSettle();
    }

    testWidgets('deletes everything once confirmed and starts setup', (
      tester,
    ) async {
      await pump(tester);
      expect(
        find.text('Translation history: 2 translations (3 KB)'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('settings_delete_all_confirm')));
      await tester.pumpAndSettle();

      verify(history.deleteAll).called(1);
      verify(() => router.go('/onboarding')).called(1);
      expect(find.text('All local data deleted'), findsOneWidget);
    });

    testWidgets('does nothing when cancelled', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      verifyNever(history.deleteAll);
      verifyNever(() => router.go(any()));
    });

    testWidgets('says when something could not be deleted', (tester) async {
      when(history.deleteAll).thenAnswer((_) => Future.error(StateError('x')));
      await pump(tester);
      await tester.tap(find.byKey(const Key('settings_delete_all_confirm')));
      await tester.pumpAndSettle();

      expect(
        find.text("Couldn't delete all local data. Try again."),
        findsOneWidget,
      );
      verifyNever(() => router.go(any()));
    });
  });
}
