import 'dart:async';
import 'dart:ui' show SemanticsInputType;

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/history/view/history_page.dart';
import 'package:mozhi/history/view/widgets/history_entry_tile.dart';
import 'package:mozhi/l10n/l10n.dart';
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

/// A history language-pair label: both names are bidi-isolated.
String _pair(String source, String target) =>
    '\u2068$source\u2069 → \u2068$target\u2069';

void main() {
  setUpAll(() {
    registerFallbacks();
    registerFallbackValue(
      const HistoryPair(source: Language.auto, target: Language.auto),
    );
  });

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
      expect(find.text(_pair('English', 'German')), findsNWidgets(2));
      expect(find.text(_pair('French (detected)', 'English')), findsOneWidget);
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
      await tester.enterText(find.byKey(HistoryView.searchFieldKey), 'morning');
      verify(() => history.search('morning')).called(1);
      await tester.pump();
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pump();
      verify(() => history.search('')).called(1);
    });

    testWidgets('filters are tabs that say which is selected', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      expect(find.byType(TabBar), findsOneWidget);
      expect(
        tester.getSemantics(find.text('All')),
        isSemantics(label: 'All\nTab 1 of 2', isSelected: true),
      );
      expect(
        tester.getSemantics(find.text('Favorites')),
        isSemantics(label: 'Favorites\nTab 2 of 2', isSelected: false),
      );
      handle.dispose();
    });

    testWidgets('the tabs follow the filter', (tester) async {
      final controller = StreamController<HistoryState>();
      addTearDown(controller.close);
      final initial = HistoryState(
        status: HistoryStatus.ready,
        entries: [_today, _yesterday],
      );
      whenListen(history, controller.stream, initialState: initial);
      await pump(tester);
      TabController tabs() =>
          tester.widget<TabBar>(find.byType(TabBar)).controller!;
      expect(tabs().index, 0);
      controller.add(initial.copyWith(favoritesOnly: true));
      await tester.pumpAndSettle();
      expect(tabs().index, 1);
    });

    testWidgets('starts on the Favorites tab when filtered', (tester) async {
      await pump(
        tester,
        state: HistoryState(
          status: HistoryStatus.ready,
          entries: [_yesterday],
          favoritesOnly: true,
        ),
      );
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 1);
    });

    testWidgets('the tabs stay pinned while the timeline scrolls', (
      tester,
    ) async {
      await pump(tester, size: const Size(400, 500));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
      await tester.pump();
      expect(tester.getTopLeft(find.byType(TabBar)).dy, lessThan(120));
      expect(find.byType(TabBar), findsOneWidget);
    });

    testWidgets('search field stays named after typing', (tester) async {
      when(() => history.search(any())).thenReturn(null);
      final handle = tester.ensureSemantics();
      await pump(tester);
      await tester.enterText(find.byKey(HistoryView.searchFieldKey), 'morning');
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
      // Closable without a pointer and without undoing.
      expect(
        tester.widget<SnackBar>(find.byType(SnackBar)).showCloseIcon,
        isTrue,
      );

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
          // The translation is the body; the quoted source follows it.
          [const Locale('de'), const Locale('en')],
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

    group('long histories', () {
      final many = [
        for (var i = 0; i < 300; i++)
          HistoryEntry(
            id: 'm$i',
            text: 'Entry $i',
            translation: 'Eintrag $i',
            source: _english,
            target: _german,
            engineId: 'mozhi:google',
            engineName: 'Google',
            createdAt: _daysAgo(i ~/ 10, hour: 12 - i % 10),
          ),
      ];

      testWidgets('only builds the entries on screen', (tester) async {
        await pump(
          tester,
          state: HistoryState(status: HistoryStatus.ready, entries: many),
        );

        final built = find
            .byType(HistoryEntryTile, skipOffstage: false)
            .evaluate()
            .length;
        expect(built, greaterThan(0));
        expect(built, lessThan(40));
        expect(find.text('Entry 0'), findsOneWidget);
        expect(find.text('Entry 299', skipOffstage: false), findsNothing);

        await tester.scrollUntilVisible(
          find.text('Entry 120'),
          2000,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Entry 120'), findsOneWidget);
        expect(find.text('Entry 0', skipOffstage: false), findsNothing);
      });

      testWidgets('keeps unchanged tiles when the state changes', (
        tester,
      ) async {
        final controller = StreamController<HistoryState>();
        addTearDown(controller.close);
        whenListen(
          history,
          controller.stream,
          initialState: HistoryState(
            status: HistoryStatus.ready,
            entries: many,
          ),
        );
        await pump(tester);

        HistoryEntryTile tile(String id) =>
            tester.widget<HistoryEntryTile>(find.byKey(ValueKey(id)));
        final first = tile('m0');
        final second = tile('m1');

        final starred = many.first.copyWith(isFavorite: true);
        controller.add(
          HistoryState(
            status: HistoryStatus.ready,
            entries: [starred, ...many.skip(1)],
          ),
        );
        await tester.pump();

        expect(tile('m0'), isNot(same(first)));
        expect(tile('m0').entry.isFavorite, isTrue);
        expect(tile('m1'), same(second));
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

    group('actions', () {
      late List<MethodCall> calls;

      setUp(() {
        calls = [];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              calls.add(call);
              return null;
            });
      });

      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      testWidgets('copy copies the translation and shows a check', (
        tester,
      ) async {
        await pump(tester);
        await tester.tap(find.byTooltip('Copy').first);
        await tester.pump();
        expect(
          calls
              .where((c) => c.method == 'Clipboard.setData')
              .map((c) => (c.arguments as Map)['text']),
          ['Guten Morgen'],
        );
        expect(find.byIcon(Icons.check_rounded), findsOneWidget);
        expect(find.byTooltip('Copied to clipboard'), findsOneWidget);
        // Copying again restarts the timer.
        await tester.tap(find.byTooltip('Copied to clipboard'));
        await tester.pump();
        await tester.pump(HistoryEntryTile.copiedDuration);
        expect(find.byIcon(Icons.check_rounded), findsNothing);
        expect(find.byTooltip('Copy'), findsNWidgets(3));
        await tester.pumpAndSettle();
      });

      testWidgets('a copied row can go away while it shows the check', (
        tester,
      ) async {
        await pump(tester);
        await tester.tap(find.byTooltip('Copy').first);
        await tester.pump();
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      });

      testWidgets('share shares the translation', (tester) async {
        final shared = <String?>[];
        final previous = HistoryShare.share;
        HistoryShare.share = (params) async => shared.add(params.text);
        addTearDown(() => HistoryShare.share = previous);
        await pump(tester);
        await tester.tap(find.byTooltip('Share').at(1));
        expect(shared, ['Hello']);
      });

      testWidgets('the favorite is a heart in the like colour', (tester) async {
        await pump(tester);
        final hearts = tester.widgetList<XActionButton>(
          find.byWidgetPredicate(
            (w) =>
                w is XActionButton && w.activeColor == const Color(0xFFF91880),
          ),
        );
        expect(hearts.map((b) => b.active), [false, true, false]);
        expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
      });

      testWidgets('the button starts a new translation', (tester) async {
        await pump(tester);
        await tester.tap(find.byTooltip('New translation'));
        verify(() => router.go('/translate', extra: any(named: 'extra')))
            .called(1);
      });
    });

    group('relativeHistoryTime', () {
      final now = DateTime(2026, 5, 6, 12);
      late AppLocalizations l10n;

      setUpAll(() async {
        l10n = await AppLocalizations.delegate.load(const Locale('en'));
      });

      test('is X-style short for the last day', () {
        expect(relativeHistoryTime(l10n, now, now), 'now');
        expect(
          relativeHistoryTime(l10n, now.add(const Duration(minutes: 1)), now),
          'now',
        );
        expect(
          relativeHistoryTime(
            l10n,
            now.subtract(const Duration(minutes: 5)),
            now,
          ),
          '5m',
        );
        expect(
          relativeHistoryTime(
            l10n,
            now.subtract(const Duration(hours: 3)),
            now,
          ),
          '3h',
        );
      });

      test('is the clock time for older entries', () {
        expect(
          relativeHistoryTime(l10n, now.subtract(const Duration(days: 2)), now),
          '12:00\u202fPM',
        );
      });
    });

    testWidgets('clears history from the app bar', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('Clear history'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      verify(() => history.clear(keepFavorites: true)).called(1);
    });

    group('retention note', () {
      testWidgets('says how long translations are kept', (tester) async {
        await pump(
          tester,
          appSettings: const AppSettings(
            historyRetention: HistoryRetention.week,
          ),
        );
        expect(
          find.text(
            'Translations older than 7 days are deleted automatically. '
            'Favorites are kept.',
          ),
          findsOneWidget,
        );
      });

      testWidgets('uses the singular for one day', (tester) async {
        await pump(
          tester,
          appSettings: const AppSettings(
            historyRetention: HistoryRetention.day,
          ),
        );
        expect(
          find.text(
            'Translations older than 1 day are deleted automatically. '
            'Favorites are kept.',
          ),
          findsOneWidget,
        );
      });

      testWidgets('is hidden when history is kept forever', (tester) async {
        await pump(tester);
        expect(find.textContaining('deleted automatically'), findsNothing);
      });
    });

    group('empty states', () {
      testWidgets('no history', (tester) async {
        await pump(
          tester,
          state: const HistoryState(status: HistoryStatus.ready),
        );
        expect(find.text('No history yet'), findsOneWidget);
        expect(find.byTooltip('Clear history'), findsNothing);
        // The empty state has its own call to action.
        expect(find.byType(FloatingActionButton), findsNothing);
        expect(
          tester.getSemantics(find.text('No history yet')),
          isSemantics(isHeader: true, isLiveRegion: false),
        );
        await tester.tap(find.text('Start translating'));
        verify(() => router.go('/translate', extra: any(named: 'extra')))
            .called(1);
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
        await tester.tap(find.text('Clear search'));
        verify(() => history.search('')).called(1);
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
        await tester.tap(find.text('Show all translations'));
        verify(() => history.setFavoritesOnly(enabled: false)).called(1);
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
      expect(find.text('History is paused'), findsOneWidget);
      expect(
        find.text("History is off. New translations aren't saved."),
        findsOneWidget,
      );
      await tester.tap(find.text('Turn on'));
      verify(() => settings.setSaveHistory(enabled: true)).called(1);
    });

    testWidgets('incognito shows a banner to turn it off', (tester) async {
      await pump(
        tester,
        appSettings: const AppSettings(incognito: true, saveHistory: false),
      );
      expect(find.text('History is paused'), findsOneWidget);
      expect(find.textContaining('Incognito is on'), findsOneWidget);
      expect(find.textContaining('History is off'), findsNothing);
      await tester.tap(find.text('Turn off incognito'));
      verify(() => settings.setIncognito(enabled: false)).called(1);
    });

    testWidgets('the banner is one group for screen readers', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, appSettings: const AppSettings(saveHistory: false));
      expect(
        find.semantics.byLabel(
          RegExp("History is paused\nHistory is off. New translations aren't"),
        ),
        findsOne,
      );
      handle.dispose();
    });

    testWidgets('shows no banner while history is saved', (tester) async {
      await pump(tester);
      expect(find.text('History is paused'), findsNothing);
    });

    group('search field', () {
      testWidgets('lets keyboards learn normally', (tester) async {
        await pump(tester);
        final field = tester.widget<TextField>(
          find.byKey(HistoryView.searchFieldKey),
        );
        expect(field.enableIMEPersonalizedLearning, isTrue);
      });

      testWidgets('asks keyboards not to learn while incognito', (
        tester,
      ) async {
        await pump(tester, appSettings: const AppSettings(incognito: true));
        final field = tester.widget<TextField>(
          find.byKey(HistoryView.searchFieldKey),
        );
        expect(field.enableIMEPersonalizedLearning, isFalse);
      });

      testWidgets('is a search box for screen readers', (tester) async {
        final handle = tester.ensureSemantics();
        await pump(tester);
        expect(
          tester.getSemantics(find.byType(EditableText)),
          isSemantics(
            label: 'Search history',
            isTextField: true,
            inputType: SemanticsInputType.search,
          ),
        );
        handle.dispose();
      });
    });

    group('unreadable history', () {
      const unreadable = HistoryState(status: HistoryStatus.unreadable);

      testWidgets('explains it and retries', (tester) async {
        await pump(tester, state: unreadable);
        expect(find.text("Your history can't be decrypted"), findsOneWidget);
        expect(find.textContaining('secure storage was reset'), findsOneWidget);
        expect(find.byTooltip('Clear history'), findsNothing);
        await tester.tap(find.text('Retry'));
        verify(history.load).called(1);
      });

      testWidgets('starts a new history once confirmed', (tester) async {
        when(history.discardUnreadable).thenAnswer((_) async {});
        await pump(tester, state: unreadable);

        await tester.tap(find.text('Start a new history'));
        await tester.pumpAndSettle();
        expect(find.text('Start a new history?'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        verifyNever(history.discardUnreadable);

        await tester.tap(find.text('Start a new history'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('history_start_over_confirm')));
        await tester.pumpAndSettle();
        verify(history.discardUnreadable).called(1);
      });
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

    group('filters', () {
      Finder chip(String label) => find.widgetWithText(FilterChip, label);

      testWidgets('offers the language pairs and the destinations in the '
          'history', (tester) async {
        final handle = tester.ensureSemantics();
        await pump(tester);
        expect(chip('All language pairs'), findsOneWidget);
        expect(chip('Public server'), findsOneWidget);
        expect(chip('Cloud'), findsOneWidget);
        expect(chip('On device'), findsNothing);
        expect(chip('Self-hosted'), findsNothing);
        expect(find.text('Clear filters'), findsNothing);
        expect(find.bySemanticsLabel('Filters'), findsOneWidget);
        handle.dispose();
      });

      testWidgets('classifies with the configured providers and instances', (
        tester,
      ) async {
        await pump(
          tester,
          appSettings: const AppSettings(
            instances: [MozhiInstance(url: 'http://192.168.1.2:3000')],
            providers: [
              AiProviderConfig(
                id: 'p1',
                name: 'Claude',
                provider: LlmProvider.anthropic,
                baseUrl: 'https://api.anthropic.com/v1',
                model: 'claude',
              ),
            ],
          ),
        );
        expect(chip('Self-hosted'), findsOneWidget);
        expect(chip('Cloud'), findsOneWidget);
        expect(chip('Public server'), findsNothing);
      });

      testWidgets('a destination chip filters and clears', (tester) async {
        await pump(tester);
        await tester.tap(chip('Cloud'));
        verify(() => history.filterByDestination(HistoryDestination.cloud))
            .called(1);

        await pump(
          tester,
          state: HistoryState(
            status: HistoryStatus.ready,
            entries: [_today, _yesterday, _older],
            destination: HistoryDestination.cloud,
          ),
        );
        // Only Claude's translation is shown.
        expect(find.text('Bonjour'), findsOneWidget);
        expect(find.text('Good morning'), findsNothing);
        expect(tester.widget<FilterChip>(chip('Cloud')).selected, isTrue);
        await tester.tap(chip('Cloud'));
        verify(() => history.filterByDestination(null)).called(1);
        await tester.tap(find.text('Clear filters'));
        verify(history.clearFilters).called(1);
      });

      testWidgets('the pair chip lists the pairs with their counts', (
        tester,
      ) async {
        await pump(tester);
        await tester.tap(find.byKey(HistoryView.pairFilterKey));
        await tester.pumpAndSettle();
        expect(find.text('Language pair'), findsOneWidget);
        expect(find.text('2 translations'), findsOneWidget);
        expect(find.text('1 translation'), findsOneWidget);
        // Most used first.
        expect(
          tester.getTopLeft(find.text('2 translations')).dy,
          lessThan(tester.getTopLeft(find.text('1 translation')).dy),
        );
        await tester.tap(find.text('2 translations'));
        await tester.pumpAndSettle();
        verify(
          () => history.filterByPair(
            const HistoryPair(source: _english, target: _german),
          ),
        ).called(1);
      });

      testWidgets('picking all pairs clears the pair, dismissing changes '
          'nothing', (tester) async {
        const pair = HistoryPair(
          source: Language(code: 'fr', name: 'French'),
          target: _english,
        );
        await pump(
          tester,
          state: HistoryState(
            status: HistoryStatus.ready,
            entries: [_today, _yesterday, _older],
            pair: pair,
          ),
        );
        // The chip names the pair; only its entries are shown.
        expect(
          find.descendant(
            of: find.byKey(HistoryView.pairFilterKey),
            matching: find.text(_pair('French', 'English')),
          ),
          findsOneWidget,
        );
        expect(find.text('Good morning'), findsNothing);
        expect(find.text('Bonjour'), findsOneWidget);

        await tester.tap(find.byKey(HistoryView.pairFilterKey));
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        verifyNever(() => history.filterByPair(any()));

        await tester.tap(find.byKey(HistoryView.pairFilterKey));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(ListTile),
            matching: find.text('All language pairs'),
          ),
        );
        await tester.pumpAndSettle();
        verify(() => history.filterByPair(null)).called(1);
      });

      testWidgets('says when nothing matches the filters', (tester) async {
        await pump(
          tester,
          state: HistoryState(
            status: HistoryStatus.ready,
            entries: [_today, _yesterday, _older],
            destination: HistoryDestination.onDevice,
          ),
        );
        expect(find.text('Nothing matches these filters'), findsOneWidget);
        expect(
          find.text('Try another language pair or destination.'),
          findsOneWidget,
        );
        // The set filter stays visible so it can be turned off.
        expect(chip('On device'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'Clear filters'));
        verify(history.clearFilters).called(1);
      });

      testWidgets('are hidden when they would not narrow anything', (
        tester,
      ) async {
        await pump(
          tester,
          state: HistoryState(
            status: HistoryStatus.ready,
            entries: [_today, _older],
          ),
        );
        expect(find.byType(FilterChip), findsNothing);
        await pump(
          tester,
          state: const HistoryState(status: HistoryStatus.ready),
        );
        expect(find.byType(FilterChip), findsNothing);
      });

      testWidgets('fit 360dp at 200% text with large enough targets', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await pump(
          tester,
          state: HistoryState(
            status: HistoryStatus.ready,
            entries: [_today, _yesterday, _older],
            pair: const HistoryPair(source: _english, target: _german),
          ),
          size: const Size(360, 1600),
          textScale: 2,
        );
        expect(tester.takeException(), isNull);
        expect(find.text('Clear filters'), findsOneWidget);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        handle.dispose();
      });
    });

    testWidgets('centers the list on wide screens', (tester) async {
      await pump(tester, size: const Size(1400, 1000));
      expect(
        tester.getTopLeft(find.byKey(HistoryView.searchFieldKey)).dx,
        greaterThan(300),
      );
    });
  });
}

extension on Text {
  Locale? get _locale => (textSpan! as TextSpan).locale;
}
