import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

class _MockTranslationRepository extends Mock implements TranslationRepository;

const _english = Language(code: 'en', name: 'English');
const _french = Language(code: 'fr', name: 'French');
const _aiEngine = TranslationEngine(
  id: 'ai:p1',
  kind: EngineKind.ai,
  name: 'Claude',
  providerId: 'p1',
);
final _mozhiEngine = TranslationEngine.mozhi('google', 'Google');

void main() {
  setUpAll(() {
    registerFallbackValue(_english);
    registerFallbackValue(_aiEngine);
    registerFallbackValue(
      const TranslationRequest(text: '', source: _english, target: _french),
    );
  });

  late _MockTranslationRepository repo;
  late SettingsCubit settings;
  late HistoryCubit history;
  late TranslateCubit cubit;

  Future<void> setUpCubit({
    bool autoExtras = false,
    TranslationEngine? engine,
  }) async {
    final chosen = engine ?? _aiEngine;
    repo = _MockTranslationRepository();
    when(() => repo.getEngines(refresh: any(named: 'refresh')))
        .thenAnswer((_) async => [chosen]);
    when(() => repo.getSourceLanguages(any()))
        .thenAnswer((_) async => [Language.auto, _english, _french]);
    when(() => repo.getTargetLanguages(any()))
        .thenAnswer((_) async => [_english, _french]);
    when(
      () => repo.needsConsent(
        any(),
        source: any(named: 'source'),
        target: any(named: 'target'),
      ),
    ).thenReturn(false);
    when(() => repo.metadataChanged).thenAnswer((_) => const Stream.empty());
    when(() => repo.mozhiEnginesNeedReload).thenReturn(false);
    when(() => repo.maskPersonalData).thenReturn(true);
    when(() => repo.privacyMode).thenReturn(PrivacyMode.online);
    when(() => repo.translate(any(), any(), refresh: any(named: 'refresh')))
        .thenAnswer(
          (_) => Stream.value(
            TranslationResult(
              text: 'Bonjour',
              engineId: chosen.id,
              engineName: chosen.name,
            ),
          ),
        );
    when(() => repo.getInsights(any(), any(), any())).thenAnswer(
      (_) async => const [
        WordInsight(
          sourceText: 'Hello',
          targetText: 'Bonjour',
          explanation: 'Standard greeting',
        ),
      ],
    );
    when(
      () => repo.getAlternatives(any(), any(), any(), span: any(named: 'span')),
    ).thenAnswer(
      (_) async => const AlternativeTranslations(
        description: 'Greeting options',
        alternatives: [Alternative(text: 'Salut', explanation: 'Informal')],
      ),
    );

    settings = SettingsCubit(
      repository: SettingsRepository(
        prefs: MemoryStore(),
        secrets: MemoryStore(),
      ),
      initial: AppSettings(
        source: _english,
        target: _french,
        engineId: chosen.id,
        autoExtras: autoExtras,
        instantTranslate: false,
        instantTranslateAi: false,
        showTransliteration: false,
        privacyMode: PrivacyMode.online,
      ),
    );
    history = HistoryCubit(
      repository: HistoryRepository(
        store: MemoryStore(),
        keyStore: MemoryStore(),
      ),
    );
    cubit = TranslateCubit(
      repository: repo,
      settings: settings,
      history: history,
    );
    await cubit.loadEngines();
  }

  tearDown(() async {
    await cubit.close();
    await history.close();
    await settings.close();
  });

  group('TranslateCubit.regenerate', () {
    test('re-runs the current translation with refresh: true', () async {
      await setUpCubit();
      cubit.setInput('Hello');
      await cubit.translate();

      verify(() => repo.translate(_aiEngine, any())).called(1);

      when(() => repo.translate(_aiEngine, any(), refresh: true)).thenAnswer(
        (_) => Stream.value(
          const TranslationResult(
            text: 'Salut',
            engineId: 'ai:p1',
            engineName: 'Claude',
          ),
        ),
      );

      await cubit.regenerate();

      verify(() => repo.translate(_aiEngine, any(), refresh: true)).called(1);
      expect(cubit.state.output, 'Salut');
    });

    test('is a no-op when input is empty', () async {
      await setUpCubit();
      await cubit.regenerate();
      verifyNever(
        () => repo.translate(any(), any(), refresh: any(named: 'refresh')),
      );
    });
  });

  group('AppSettings.autoExtras', () {
    test('defaults to false and serializes cleanly', () {
      const defaults = AppSettings();
      expect(defaults.autoExtras, isFalse);
      final enabled = defaults.copyWith(autoExtras: true);
      expect(enabled.autoExtras, isTrue);
      expect(AppSettings.fromJson(enabled.toJson()).autoExtras, isTrue);
      expect(AppSettings.fromJson(const {}).autoExtras, isFalse);
    });

    test('does not auto-load insights/alternatives when disabled', () async {
      await setUpCubit();
      cubit.setInput('Hello');
      await cubit.translate();
      await Future<void>.delayed(Duration.zero);

      verifyNever(() => repo.getInsights(any(), any(), any()));
      verifyNever(
        () =>
            repo.getAlternatives(any(), any(), any(), span: any(named: 'span')),
      );
    });

    test(
      'auto-loads insights and alternatives on AI completion when enabled',
      () async {
        await setUpCubit(autoExtras: true);
        cubit.setInput('Hello');
        await cubit.translate();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        verify(() => repo.getInsights(_aiEngine, any(), 'Bonjour')).called(1);
        verify(() => repo.getAlternatives(_aiEngine, any(), 'Bonjour'))
            .called(1);
        expect(cubit.state.insightsStatus, ExtraStatus.ready);
        expect(cubit.state.alternativesStatus, ExtraStatus.ready);
      },
    );

    test('does not auto-load extras for non-AI engines', () async {
      await setUpCubit(autoExtras: true, engine: _mozhiEngine);
      cubit.setInput('Hello');
      await cubit.translate();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      verifyNever(() => repo.getInsights(any(), any(), any()));
      verifyNever(
        () =>
            repo.getAlternatives(any(), any(), any(), span: any(named: 'span')),
      );
    });
  });
}
