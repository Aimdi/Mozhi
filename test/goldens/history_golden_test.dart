@Tags(['golden', 'skip_very_good_optimization'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/history/view/history_page.dart';
import 'package:mozhi/history/view/widgets/history_entry_tile.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../settings/view/helpers.dart';
import 'helpers/golden_helpers.dart';

const _english = Language(code: 'en', name: 'English');
const _german = Language(code: 'de', name: 'German');
const _french = Language(code: 'fr', name: 'French');
const _spanish = Language(code: 'es', name: 'Spanish');

/// The screen's "now" in these tests ([HistoryClock]): at noon, yesterday
/// morning is more than a day ago, so its entries show their clock time
/// whenever the test runs (at 00:03 they would read "14h").
final _now = DateTime(2026, 10, 20, 12);

/// Entries from today (made just now, shown as "now") and from yesterday
/// morning (shown with their clock time).
List<HistoryEntry> _entries() {
  final now = _now;
  final yesterday = DateTime(now.year, now.month, now.day - 1, 9, 30);
  return [
    HistoryEntry(
      id: '1',
      text: 'Where is the train station?',
      translation: 'Où est la gare ?',
      source: Language.auto,
      target: _french,
      engineId: 'mozhi:deepl',
      engineName: 'DeepL',
      createdAt: now,
      detectedSource: 'en',
      isFavorite: true,
    ),
    HistoryEntry(
      id: '2',
      text: 'Good morning',
      translation: 'Guten Morgen',
      source: _english,
      target: _german,
      engineId: 'mozhi:google',
      engineName: 'Google',
      createdAt: now,
    ),
    HistoryEntry(
      id: '3',
      text: 'Thank you very much for your help.',
      translation: 'Muchas gracias por tu ayuda.',
      source: _english,
      target: _spanish,
      engineId: 'ai:p1',
      engineName: 'Claude',
      createdAt: yesterday,
    ),
    HistoryEntry(
      id: '4',
      text: 'Bonjour',
      translation: 'Hello',
      source: Language.auto,
      target: _english,
      engineId: 'offline:bergamot',
      engineName: 'On device',
      createdAt: yesterday.subtract(const Duration(minutes: 45)),
      detectedSource: 'fr',
    ),
  ];
}

void main() {
  setUpAll(registerFallbacks);

  goldenGroup('History screen', () {
    setUp(() => HistoryClock.now = () => _now);
    tearDown(() => HistoryClock.now = DateTime.now);

    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets('with a few entries on a phone (${brightness.name})', (
        tester,
      ) async {
        final translate = MockTranslateCubit();
        when(() => translate.state).thenReturn(const TranslateState());
        useGoldenDevice(tester, GoldenDevice.phone);
        await tester.pumpView(
          const HistoryPage(),
          settings: createSettingsCubit(),
          history: createHistoryCubit(
            HistoryState(status: HistoryStatus.ready, entries: _entries()),
          ),
          translate: translate,
          router: createRouter(),
          theme: goldenTheme(brightness),
        );
        await tester.pumpAndSettle();
        await expectScreenGolden('history_phone_${brightness.name}');
      });
    }

    testWidgets('a dictionary look-up on a phone (light)', (tester) async {
      final translate = MockTranslateCubit();
      when(() => translate.state).thenReturn(const TranslateState());
      final now = _now;
      final entries = [
        HistoryEntry(
          id: 'dictionary:1',
          kind: HistoryEntryKind.dictionary,
          text: 'hola',
          translation:
              'interjection · A greeting used when meeting someone or '
              'acknowledging their arrival.',
          source: _spanish,
          target: _english,
          engineId: 'ai:p1',
          engineName: 'Claude',
          // Newer than the translations (all shown as "now").
          createdAt: now.add(const Duration(seconds: 1)),
          verbosity: DictionaryVerbosity.standard,
          isFavorite: true,
        ),
        ..._entries().skip(1),
      ];
      useGoldenDevice(tester, GoldenDevice.phone);
      await tester.pumpView(
        const HistoryPage(),
        settings: createSettingsCubit(),
        history: createHistoryCubit(
          HistoryState(status: HistoryStatus.ready, entries: entries),
        ),
        translate: translate,
        router: createRouter(),
        theme: goldenTheme(Brightness.light),
      );
      await tester.pumpAndSettle();
      await expectScreenGolden('history_dictionary_entry_phone_light');
    });

    testWidgets('the Favorites tab on a phone (light)', (tester) async {
      final translate = MockTranslateCubit();
      when(() => translate.state).thenReturn(const TranslateState());
      // Every entry but the German one is a favourite.
      final entries = [
        for (final entry in _entries())
          entry.copyWith(isFavorite: entry.id != '2'),
      ];
      useGoldenDevice(tester, GoldenDevice.phone);
      await tester.pumpView(
        const HistoryPage(),
        settings: createSettingsCubit(),
        history: createHistoryCubit(
          HistoryState(
            status: HistoryStatus.ready,
            entries: entries,
            favoritesOnly: true,
          ),
        ),
        translate: translate,
        router: createRouter(),
        theme: goldenTheme(Brightness.light),
      );
      await tester.pumpAndSettle();
      await expectScreenGolden('history_favorites_phone_light');
    });
  });
}
