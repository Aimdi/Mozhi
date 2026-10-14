import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

const _pirate = Language.custom('Pirate speak');

const _pairs = [
  LanguagePair(source: english, target: french),
  LanguagePair(source: Language.auto, target: german),
  LanguagePair(source: german, target: _pirate),
];

Future<TranslateHarness> _open(
  WidgetTester tester, {
  TranslateState? state,
  List<LanguagePair> pairs = _pairs,
  bool longPress = true,
}) async {
  final harness = TranslateHarness(
    state: state ?? translatedState(),
    settings: AppSettings(recentPairs: pairs),
  );
  await harness.pump(
    tester,
    child: const LanguageBar(),
    size: const Size(800, 1200),
  );
  if (longPress) {
    await tester.longPress(find.byKey(const Key('translate_swap_button')));
  } else {
    await tester.tap(find.byKey(const Key('translate_swap_button')));
  }
  await tester.pumpAndSettle();
  return harness;
}

ListTile _tile(WidgetTester tester, int index) => tester.widget<ListTile>(
  find.descendant(
    of: find.byKey(ValueKey('translate_recent_pair_$index')),
    matching: find.byType(ListTile),
  ),
);

void main() {
  setUpAll(() {
    registerTranslateFallbacks();
    registerFallbackValue(_pairs.first);
  });

  group('RecentPairsSheet', () {
    testWidgets('long-pressing swap lists the recent pairs', (tester) async {
      final harness = await _open(tester);
      expect(find.byType(RecentPairsSheet), findsOneWidget);
      expect(find.text('Recent language pairs'), findsOneWidget);
      expect(find.text('English → French'), findsOneWidget);
      expect(find.text('Detect language → German'), findsOneWidget);
      expect(find.text('German → Pirate speak'), findsOneWidget);
      // A long press does not swap.
      verifyNever(harness.translate.swap);
    });

    testWidgets('marks the pair in use (detected source)', (tester) async {
      await _open(tester);
      final current = _tile(tester, 0);
      expect(current.selected, isTrue);
      expect(
        find.bySemanticsLabel('From English to French, current'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('From Detect language to German'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('picking a pair applies it and closes the sheet', (
      tester,
    ) async {
      final harness = await _open(tester);
      await tester.tap(find.text('Detect language → German'));
      await tester.pumpAndSettle();
      verify(() => harness.translate.applyLanguagePair(_pairs[1])).called(1);
      expect(find.byType(RecentPairsSheet), findsNothing);
    });

    testWidgets('custom pairs need an engine that takes them', (tester) async {
      final harness = await _open(tester);
      final custom = _tile(tester, 2);
      expect(custom.enabled, isFalse);
      // It says why (to screen readers too, as part of the tile).
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('translate_recent_pair_2')),
          matching: find.text('Needs an AI model that takes custom languages'),
        ),
        findsOneWidget,
      );
      expect(_tile(tester, 0).subtitle, isNull);
      await tester.tap(find.text('German → Pirate speak'));
      await tester.pump();
      verifyNever(() => harness.translate.applyLanguagePair(any()));
    });

    testWidgets('custom pairs work with AI engines', (tester) async {
      final harness = await _open(
        tester,
        state: readyState(engine: claude, source: german, target: _pirate),
      );
      final custom = _tile(tester, 2);
      expect(custom.enabled, isTrue);
      expect(custom.selected, isTrue);
      expect(custom.subtitle, isNull);
      await tester.tap(find.text('German → Pirate speak'));
      await tester.pumpAndSettle();
      verify(() => harness.translate.applyLanguagePair(_pairs[2])).called(1);
    });

    testWidgets('clear forgets the pairs', (tester) async {
      final harness = await _open(tester);
      await tester.tap(find.byTooltip('Clear recent language pairs'));
      verify(harness.settings.clearRecentPairs).called(1);
    });

    testWidgets('shows an empty state', (tester) async {
      await _open(tester, pairs: const []);
      expect(
        find.byKey(const Key('translate_recent_pairs_empty')),
        findsOneWidget,
      );
      expect(
        find.text(
          'No recent language pairs yet. Pairs you translate with show up '
          'here.',
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('Clear recent language pairs'), findsNothing);
    });

    testWidgets('updates when the pairs change', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      whenListen(
        harness.settings,
        Stream.fromIterable([const AppSettings()]),
        initialState: const AppSettings(recentPairs: _pairs),
      );
      await harness.pump(tester, child: const LanguageBar());
      await tester.longPress(find.byKey(const Key('translate_swap_button')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('translate_recent_pairs_empty')),
        findsOneWidget,
      );
    });

    testWidgets('opens from a disabled swap button too', (tester) async {
      await _open(
        tester,
        state: readyState(engine: claude, target: _pirate),
      );
      expect(find.byType(RecentPairsSheet), findsOneWidget);
    });

    testWidgets('a tap still swaps', (tester) async {
      final harness = await _open(tester, longPress: false);
      verify(harness.translate.swap).called(1);
      expect(find.byType(RecentPairsSheet), findsNothing);
    });

    testWidgets('the swap button offers the long press to screen readers', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const LanguageBar());
      expect(
        tester.getSemantics(find.byKey(const Key('translate_swap_button'))),
        matchesSemantics(
          tooltip: 'Swap languages',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
          hasLongPressAction: true,
          hasFocusAction: true,
          onLongPressHint: 'show recent language pairs',
        ),
      );
      handle.dispose();
    });

    test('isCurrentLanguagePair', () {
      final state = translatedState();
      expect(isCurrentLanguagePair(_pairs[0], state), isTrue);
      expect(isCurrentLanguagePair(_pairs[1], state), isFalse);
      expect(
        isCurrentLanguagePair(
          const LanguagePair(source: Language.auto, target: french),
          state,
        ),
        isTrue,
      );
      expect(
        isCurrentLanguagePair(
          const LanguagePair(source: german, target: french),
          state,
        ),
        isFalse,
      );
      expect(
        isCurrentLanguagePair(
          const LanguagePair(source: _pirate, target: french),
          readyState(),
        ),
        isFalse,
      );
    });
  });
}
