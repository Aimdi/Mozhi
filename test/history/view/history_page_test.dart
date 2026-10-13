import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/history/view/history_page.dart';
import 'package:mozhi/history/view/widgets/history_entry_tile.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../settings/view/helpers.dart';

const _english = Language(code: 'en', name: 'English');
const _german = Language(code: 'de', name: 'German');

DateTime _daysAgo(int days, {int hour = 12}) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day - days, hour);
}

final _today = HistoryEntry(
  id: '1',
  text: 'Good morning',
  translation: 'Guten Morgen',
  source: _english,
  target: _german,
  engineId: 'mozhi:google',
  engineName: 'Google',
  createdAt: _daysAgo(0, hour: 9),
);

final _yesterday = HistoryEntry(
  id: '2',
  text: 'Bonjour',
  translation: 'Hello',
  source: Language.auto,
  target: _english,
  engineId: 'ai:p1',
  engineName: 'Claude',
  createdAt: _daysAgo(1),
  detectedSource: 'fr',
  isFavorite: true,
);

final _older = HistoryEntry(
  id: '3',
  text: 'Thank you',
  translation: 'Danke',
  source: _english,
  target: _german,
  engineId: 'mozhi:deepl',
  engineName: 'DeepL',
  createdAt: _daysAgo(10),
);

void main() {
  setUpAll(registerFallbacks);

  group('HistoryPage', () {
    late MockHistoryCubit history;
    late MockSettingsCubit settings;
    late MockTranslateCubit translate;
    late MockGoRouter router;

    setUp(() {
      final entries = [_today, _yesterday, _older];
      history = createHistoryCubit(
        HistoryState(status: HistoryStatus.ready, entries: entries),
      );
      settings = createSettingsCubit();
      translate = MockTranslateCubit();
      when(() => translate.state).thenReturn(const TranslateState());
      router = createRouter();
    });

    Future<void> pump(
      WidgetTester tester, {
      HistoryState? state,
      AppSettings? appSettings,
      Size size = const Size(800, 1600),
      double textScale = 1,
    }) async {
      if (state != null) when(() => history.state).thenReturn(state);
      if (appSettings != null) {
        when(() => settings.state).thenReturn(appSettings);
      }
      tester.setScreenSize(size);
      await tester.pumpView(
        const HistoryPage(),
        settings: settings,
        history: history,
        translate: translate,
        router: router,
        textScale: textScale,
      );
    }

    testWidgets('groups entries by day', (tester) async {
      await pump(tester);
      expect(find.text('History'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('Good morning'), findsOneWidget);
      expect(find.text('Guten Morgen'), findsOneWidget);
      expect(find.text('English → German'), findsNWidgets(2));
      expect(find.text('French (detected) → English'), findsOneWidget);
      expect(find.textContaining('Claude · '), findsOneWidget);
      // The 10-day-old entry has a date header.
      final todayY = tester.getTopLeft(find.text('Today')).dy;
      final yesterdayY = tester.getTopLeft(find.text('Yesterday')).dy;
      final olderY = tester.getTopLeft(find.text('Thank you')).dy;
      expect(todayY, lessThan(yesterdayY));
      expect(yesterdayY, lessThan(olderY));
    });

    testWidgets('shows the year for entries from a past year', (tester) async {
      final old = HistoryEntry(
        id: '9',
        text: 'Old',
        translation: 'Alt',
        source: _english,
        target: _german,
        engineId: 'mozhi:google',
        engineName: 'Google',
        createdAt: DateTime(2020, 3, 4, 12),
      );
      await pump(
        tester,
        state: HistoryState(status: HistoryStatus.ready, entries: [old]),
      );
      expect(find.textContaining('2020'), findsOneWidget);
    });

    testWidgets('searches', (tester) async {
      when(() => history.search(any())).thenReturn(null);
      await pump(tester);
      await tester.enterText(find.byType(SearchBar), 'morning');
      verify(() => history.search('morning')).called(1);
      await tester.pump();
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pump();
      verify(() => history.search('')).called(1);
    });

    testWidgets('filter chips show a checkmark when selected', (tester) async {
      await pump(tester);
      final chips = tester.widgetList<ChoiceChip>(find.byType(ChoiceChip));
      expect(chips.map((c) => c.showCheckmark), everyElement(isTrue));
    });

    testWidgets('search field stays named after typing', (tester) async {
      when(() => history.search(any())).thenReturn(null);
      final handle = tester.ensureSemantics();
      await pump(tester);
      await tester.enterText(find.byType(SearchBar), 'morning');
      await tester.pump();
      expect(
        tester.getSemantics(find.byType(EditableText)),
        isSemantics(
          label: 'Search history',
          value: 'morning',
          isTextField: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('filters favorites', (tester) async {
      when(() => history.setFavoritesOnly(enabled: any(named: 'enabled')))
          .thenReturn(null);
      await pump(tester);
      await tester.tap(find.text('Favorites'));
      verify(() => history.setFavoritesOnly(enabled: true)).called(1);
      await tester.tap(find.text('All'));
      verify(() => history.setFavoritesOnly(enabled: false)).called(1);
    });

    testWidgets('only shows visible entries', (tester) async {
      await pump(
        tester,
        state: HistoryState(
          status: HistoryStatus.ready,
          entries: [_today, _yesterday, _older],
          favoritesOnly: true,
        ),
      );
      expect(find.text('Bonjour'), findsOneWidget);
      expect(find.text('Good morning'), findsNothing);
    });

    testWidgets('toggles a favorite', (tester) async {
      await pump(tester);
      expect(find.byTooltip('Remove from favorites'), findsOneWidget);
      await tester.tap(find.byTooltip('Add to favorites').first);
      verify(() => history.toggleFavorite('1')).called(1);
    });

    testWidgets('swipe deletes with undo', (tester) async {
      await pump(tester);
      await tester.drag(find.text('Good morning'), const Offset(-600, 0));
      await tester.pumpAndSettle();
      verify(() => history.delete('1')).called(1);
      expect(find.text('Good morning'), findsNothing);
      expect(find.text('Translation deleted'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      verify(() => history.restore(_today)).called(1);
      expect(find.text('Good morning'), findsOneWidget);
    });

    group('delete without swiping', () {
      testWidgets('from the actions menu, with undo', (tester) async {
        await pump(tester);
        await tester.tap(find.byTooltip('More actions').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        verify(() => history.delete('1')).called(1);
        expect(find.text('Good morning'), findsNothing);
        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();
        verify(() => history.restore(_today)).called(1);
      });

      testWidgets('long press opens the same menu', (tester) async {
        await pump(tester);
        await tester.longPress(find.text('Bonjour'));
        await tester.pumpAndSettle();
        expect(find.text('Remove from favorites'), findsWidgets);
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        verify(() => history.delete('2')).called(1);
      });

      testWidgets('the menu toggles favorites too', (tester) async {
        await pump(tester);
        await tester.tap(find.byTooltip('More actions').first);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ListTile, 'Add to favorites'));
        await tester.pumpAndSettle();
        verify(() => history.toggleFavorite('1')).called(1);
      });

      testWidgets('Delete key removes the focused entry', (tester) async {
        await pump(tester);
        Focus.of(tester.element(find.text('Thank you'))).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.delete);
        await tester.pumpAndSettle();
        verify(() => history.delete('3')).called(1);
      });

      testWidgets('screen readers get a delete action', (tester) async {
        final handle = tester.ensureSemantics();
        await pump(tester);
        final node = find.semantics.byLabel(RegExp('Good morning'));
        expect(node, findsOne);
        final semantics = tester.getSemantics(find.text('Good morning'));
        expect(
          semantics,
          isSemantics(
            customActions: [
              const CustomSemanticsAction(label: 'Delete'),
              const CustomSemanticsAction.overridingAction(
                hint: 'Open in translator',
                action: SemanticsAction.tap,
              ),
            ],
            hasTapAction: true,
            hasLongPressAction: true,
          ),
        );
        // Each text is spoken in its own language.
        expect(
          semantics.attributedLabel.attributes
              .whereType<LocaleStringAttribute>()
              .map((a) => a.locale),
          [const Locale('en'), const Locale('de')],
        );
        tester.semantics.customAction(
          node,
          const CustomSemanticsAction(label: 'Delete'),
        );
        await tester.pumpAndSettle();
        verify(() => history.delete('1')).called(1);
        handle.dispose();
      });
    });

    group('language-aware text', () {
      const arabic = Language(code: 'ar', name: 'Arabic');
      const japanese = Language(code: 'ja', name: 'Japanese');

      testWidgets('lays out RTL text right to left with its locale', (
        tester,
      ) async {
        final entry = HistoryEntry(
          id: 'rtl',
          text: 'Hello?',
          translation: 'مرحبا؟',
          source: _english,
          target: arabic,
          engineId: 'mozhi:google',
          engineName: 'Google',
          createdAt: _daysAgo(0),
        );
        await pump(
          tester,
          state: HistoryState(status: HistoryStatus.ready, entries: [entry]),
        );
        final source = tester.widget<Text>(find.text('Hello?'));
        final target = tester.widget<Text>(find.text('مرحبا؟'));
        expect(source.textDirection, TextDirection.ltr);
        expect(source._locale, const Locale('en'));
        expect(target.textDirection, TextDirection.rtl);
        expect(target._locale, const Locale('ar'));
      });

      testWidgets('uses the detected source and guesses custom targets', (
        tester,
      ) async {
        final entry = HistoryEntry(
          id: 'auto',
          text: 'שלום',
          translation: 'こんにちは',
          source: Language.auto,
          target: japanese,
          engineId: 'ai:p1',
          engineName: 'Claude',
          createdAt: _daysAgo(0),
          detectedSource: 'he',
        );
        final custom = HistoryEntry(
          id: 'custom',
          text: 'Hello',
          translation: 'Ahoy',
          source: Language.auto,
          target: const Language.custom('Pirate'),
          engineId: 'ai:p1',
          engineName: 'Claude',
          createdAt: _daysAgo(0),
        );
        await pump(
          tester,
          state: HistoryState(
            status: HistoryStatus.ready,
            entries: [entry, custom],
          ),
        );
        final source = tester.widget<Text>(find.text('שלום'));
        expect(source.textDirection, TextDirection.rtl);
        expect(source._locale, const Locale('he'));
        expect(
          tester.widget<Text>(find.text('こんにちは'))._locale,
          const Locale('ja'),
        );
        final pirate = tester.widget<Text>(find.text('Ahoy'));
        expect(pirate._locale, isNull);
        expect(pirate.textDirection, TextDirection.ltr);
        expect(tester.widget<Text>(find.text('Hello'))._locale, isNull);
      });

      test('localeForLanguageCode', () {
        expect(localeForLanguageCode('ja'), const Locale('ja'));
        expect(localeForLanguageCode('pt-BR'), const Locale('pt', 'BR'));
        expect(localeForLanguageCode('zh_tw'), const Locale('zh', 'TW'));
        expect(
          localeForLanguageCode('sr-latn'),
          const Locale.fromSubtags(languageCode: 'sr', scriptCode: 'Latn'),
        );
        expect(
          localeForLanguageCode('zh-Hant-TW'),
          const Locale.fromSubtags(
            languageCode: 'zh',
            scriptCode: 'Hant',
            countryCode: 'TW',
          ),
        );
        expect(localeForLanguageCode('Pirate speak'), isNull);
        expect(localeForLanguageCode(''), isNull);
      });
    });

    testWidgets('shows swiped entries again once they are re-added', (
      tester,
    ) async {
      final controller = StreamController<HistoryState>();
      addTearDown(controller.close);
      whenListen(
        history,
        controller.stream,
        initialState: HistoryState(
          status: HistoryStatus.ready,
          entries: [_today, _yesterday],
        ),
      );
      await pump(tester);
      await tester.drag(find.text('Good morning'), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(find.text('Good morning'), findsNothing);

      controller.add(
        HistoryState(status: HistoryStatus.ready, entries: [_yesterday]),
      );
      await tester.pump();
      controller.add(
        HistoryState(
          status: HistoryStatus.ready,
          entries: [_today, _yesterday],
        ),
      );
      await tester.pump();
      expect(find.text('Good morning'), findsOneWidget);
    });

    testWidgets('tap opens the entry in the translator', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Bonjour'));
      verifyInOrder([
        () => translate.setSource(Language.auto),
        () => translate.setTarget(_english),
        () => translate.setInputAndTranslate('Bonjour'),
      ]);
      verify(() => router.go('/translate', extra: any(named: 'extra')))
          .called(1);
    });

    testWidgets('clears history from the app bar', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('Clear history'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      verify(() => history.clear(keepFavorites: true)).called(1);
    });

    group('empty states', () {
      testWidgets('no history', (tester) async {
        await pump(
          tester,
          state: const HistoryState(status: HistoryStatus.ready),
        );
        expect(find.text('No history yet'), findsOneWidget);
        expect(find.byTooltip('Clear history'), findsNothing);
        expect(
          tester.getSemantics(find.text('No history yet')),
          isSemantics(isHeader: true, isLiveRegion: false),
        );
      });

      testWidgets('no matches', (tester) async {
        await pump(
          tester,
          state: HistoryState(
            status: HistoryStatus.ready,
            entries: [_today],
            query: 'zebra',
          ),
        );
        expect(find.text('No matches'), findsOneWidget);
        expect(find.text('Nothing matches “zebra”.'), findsOneWidget);
        expect(
          tester.getSemantics(find.text('No matches')),
          isSemantics(isLiveRegion: true, isHeader: true),
        );
      });

      testWidgets('no favorites', (tester) async {
        await pump(
          tester,
          state: HistoryState(
            status: HistoryStatus.ready,
            entries: [_today],
            favoritesOnly: true,
          ),
        );
        expect(find.text('No favorites yet'), findsOneWidget);
      });

      testWidgets('loading', (tester) async {
        await pump(
          tester,
          state: const HistoryState(status: HistoryStatus.loading),
        );
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.bySemanticsLabel('Loading history…'), findsOneWidget);
      });

      testWidgets('failure offers a retry', (tester) async {
        await pump(
          tester,
          state: const HistoryState(status: HistoryStatus.failure),
        );
        expect(find.text("Couldn't load history"), findsOneWidget);
        await tester.tap(find.text('Retry'));
        verify(history.load).called(1);
      });
    });

    testWidgets('history disabled shows a banner to turn it on', (
      tester,
    ) async {
      await pump(tester, appSettings: const AppSettings(saveHistory: false));
      expect(
        find.text("History is off. New translations aren't saved."),
        findsOneWidget,
      );
      await tester.tap(find.text('Turn on'));
      verify(() => settings.setSaveHistory(enabled: true)).called(1);
    });

    testWidgets('fits 320dp with large text', (tester) async {
      await pump(
        tester,
        appSettings: const AppSettings(saveHistory: false),
        size: const Size(320, 640),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      await tester.dragUntilVisible(
        find.text('Thank you'),
        find.byType(CustomScrollView),
        const Offset(0, -200),
      );
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('More actions'), findsWidgets);
    });

    testWidgets('centers the list on wide screens', (tester) async {
      await pump(tester, size: const Size(1400, 1000));
      expect(tester.getTopLeft(find.byType(SearchBar)).dx, greaterThan(300));
    });
  });
}

extension on Text {
  Locale? get _locale => (textSpan! as TextSpan).locale;
}
