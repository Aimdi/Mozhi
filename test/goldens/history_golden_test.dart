@Tags(['golden', 'skip_very_good_optimization'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/history/view/history_page.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../settings/view/helpers.dart';
import 'helpers/golden_helpers.dart';

const _english = Language(code: 'en', name: 'English');
const _german = Language(code: 'de', name: 'German');
const _french = Language(code: 'fr', name: 'French');
const _spanish = Language(code: 'es', name: 'Spanish');

/// Entries from today (made just now, shown as "now") and from yesterday
/// morning (shown with their clock time): stable whenever the test runs.
List<HistoryEntry> _entries() {
  final now = DateTime.now();
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
  });
}
