import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

const _pirate = Language.custom('Pirate speak');

/// The visible label of a pair: each name is a bidi isolate.
String _label(String source, String target) =>
    '\u2068$source\u2069 → \u2068$target\u2069';

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
    registerFallbackValue((AppSettings settings) => settings);
  });

  group('RecentPairsSheet', () {
    testWidgets('long-pressing swap lists the recent pairs', (tester) async {
      final harness = await _open(tester);
      expect(find.byType(RecentPairsSheet), findsOneWidget);
      expect(find.text('Recent language pairs'), findsOneWidget);
      expect(find.text(_label('English', 'French')), findsOneWidget);
      expect(find.text(_label('Detect language', 'German')), findsOneWidget);
      expect(find.text(_label('German', 'Pirate speak')), findsOneWidget);
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
        find.bySemanticsLabel('From any language to German'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('picking a pair applies it and closes the sheet', (
      tester,
    ) async {
      final harness = await _open(tester);
      await tester.tap(find.text(_label('Detect language', 'German')));
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
          matching: find.text(
            'Needs an AI model that supports custom languages',
          ),
        ),
        findsOneWidget,
      );
      expect(_tile(tester, 0).subtitle, isNull);
      await tester.tap(find.text(_label('German', 'Pirate speak')));
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
      await tester.tap(find.text(_label('German', 'Pirate speak')));
      await tester.pumpAndSettle();
      verify(() => harness.translate.applyLanguagePair(_pairs[2])).called(1);
    });

    testWidgets('clear forgets the pairs', (tester) async {
      final harness = await _open(tester);
      await tester.tap(find.byTooltip('Clear recent language pairs'));
      verify(harness.settings.clearRecentPairs).called(1);
    });

    group('clearing', () {
      late StreamController<AppSettings> settings;
      late TranslateHarness harness;

      setUp(() {
        settings = StreamController<AppSettings>();
        harness = TranslateHarness(state: translatedState());
        whenListen(
          harness.settings,
          settings.stream,
          initialState: const AppSettings(recentPairs: _pairs),
        );
        when(harness.settings.clearRecentPairs)
            .thenAnswer((_) => settings.add(const AppSettings()));
        when(() => harness.settings.update(any())).thenAnswer((invocation) {
          final change =
              invocation.positionalArguments.single
                  as AppSettings Function(AppSettings);
          settings.add(change(harness.settings.state));
        });
      });

      tearDown(() => settings.close());

      Future<void> openSheet(WidgetTester tester) async {
        await harness.pump(
          tester,
          child: const LanguageBar(),
          size: const Size(800, 1200),
        );
        await tester.longPress(find.byKey(const Key('translate_swap_button')));
        await tester.pumpAndSettle();
      }

      testWidgets('with the keyboard is announced and offers Undo', (
        tester,
      ) async {
        await openSheet(tester);
        final clear = find.byKey(const Key('translate_recent_pairs_clear'));
        Focus.of(tester.element(find.byIcon(Icons.delete_sweep_outlined)))
            .requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();

        verify(harness.settings.clearRecentPairs).called(1);
        expect(clear, findsNothing);
        expect(
          find.byKey(const Key('translate_recent_pairs_cleared')),
          findsOneWidget,
        );
        expect(find.text('Recent language pairs cleared'), findsOneWidget);
        // Told to screen readers.
        expect(tester.takeAnnouncements(), [
          isAccessibilityAnnouncement('Recent language pairs cleared'),
        ]);
        // The focus moved from the removed button to Undo.
        final undo = find.byKey(const Key('translate_recent_pairs_undo'));
        expect(
          Focus.of(tester.element(find.text('Undo'))).hasPrimaryFocus,
          isTrue,
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        verify(() => harness.settings.update(any())).called(1);
        expect(undo, findsNothing);
        expect(find.text(_label('English', 'French')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('translate_recent_pair_2')),
          findsOneWidget,
        );
        // Back to the clear button.
        expect(
          Focus.of(tester.element(find.byIcon(Icons.delete_sweep_outlined)))
              .hasPrimaryFocus,
          isTrue,
        );
      });

      testWidgets('is announced through a live region on Android', (
        tester,
      ) async {
        await harness.pump(
          tester,
          child: const LanguageBar(),
          size: const Size(800, 1200),
          supportsAnnounce: false,
        );
        await tester.longPress(find.byKey(const Key('translate_swap_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Clear recent language pairs'));
        await tester.pumpAndSettle();
        final live = find.byKey(const Key('status_announcer_live_region'));
        expect(live, findsOneWidget);
        expect(
          tester.getSemantics(live).label,
          'Recent language pairs cleared',
        );
      });

      testWidgets('undo stays and keeps pairs recorded meanwhile first', (
        tester,
      ) async {
        await openSheet(tester);
        await tester.tap(find.byTooltip('Clear recent language pairs'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('translate_recent_pairs_empty')),
          findsNothing,
        );

        // A translation finished meanwhile and recorded its pair.
        const recorded = LanguagePair(source: french, target: german);
        settings.add(const AppSettings(recentPairs: [recorded]));
        await tester.pumpAndSettle();
        expect(find.text(_label('French', 'German')), findsOneWidget);

        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();
        expect(harness.settings.state.recentPairs, [recorded, ..._pairs]);
        expect(find.text('Undo'), findsNothing);
      });

      testWidgets('clearing again keeps everything for undo', (tester) async {
        await openSheet(tester);
        await tester.tap(find.byTooltip('Clear recent language pairs'));
        await tester.pumpAndSettle();
        const recorded = LanguagePair(source: french, target: german);
        settings.add(const AppSettings(recentPairs: [recorded]));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Clear recent language pairs'));
        await tester.pumpAndSettle();
        expect(harness.settings.state.recentPairs, isEmpty);

        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();
        expect(harness.settings.state.recentPairs, [recorded, ..._pairs]);
      });
    });

    testWidgets(
      'the arrow points from the source to the target in right-to-left UI',
      (tester) async {
        await _open(tester, pairs: [_pairs.first]);
        await tester.binding.setLocale('ar', '');
        await tester.pumpAndSettle();
        // The names are Arabic too ("English", "French").
        const english = 'الإنجليزية';
        const french = 'الفرنسية';
        final label = find.textContaining('\u2068$english\u2069');
        expect(label, findsOneWidget);
        final text = tester.widget<Text>(label).data!;
        expect(text, '\u2068$english\u2069 ← \u2068$french\u2069');
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: label, matching: find.byType(RichText)),
        );
        expect(paragraph.textDirection, TextDirection.rtl);
        double left(String part) {
          final start = text.indexOf(part);
          return paragraph
              .getBoxesForSelection(
                TextSelection(
                  baseOffset: start,
                  extentOffset: start + part.length,
                ),
              )
              .first
              .left;
        }

        // Read right to left: English, then the arrow pointing (left) at
        // French.
        expect(left(english), greaterThan(left('←')));
        expect(left('←'), greaterThan(left(french)));
      },
    );

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
