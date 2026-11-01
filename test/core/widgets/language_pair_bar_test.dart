import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/composer_card.dart';
import 'package:mozhi/core/widgets/language_pair_bar.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers/helpers.dart';

void main() {
  group('languagePairWidths', () {
    test('halves the width while both fit', () {
      expect(languagePairWidths(200, 80, 90), (100.0, 100.0));
    });

    test('gives the longer name the rest', () {
      expect(languagePairWidths(200, 60, 150), (60.0, 140.0));
      expect(languagePairWidths(200, 150, 60), (140.0, 60.0));
    });

    test('halves the width when neither fits, never below zero', () {
      expect(languagePairWidths(200, 150, 160), (100.0, 100.0));
      expect(languagePairWidths(-10, 10, 10), (0.0, 0.0));
    });
  });

  group('languagePairForms', () {
    test('shortens "Detect language" to the sparkle and "Auto"', () {
      expect(
        languagePairForms(
          Language.auto,
          label: 'Sprache erkennen',
          autoShort: 'Auto',
        ),
        [
          (icon: null, text: 'Sprache erkennen'),
          (icon: Icons.auto_awesome_outlined, text: 'Auto'),
          (icon: Icons.auto_awesome_outlined, text: null),
        ],
      );
    });

    test('shortens a name to its codes', () {
      expect(
        languagePairForms(
          const Language(code: 'pt-BR', name: 'Portuguese (Brazil)'),
          label: 'Portugiesisch (Brasilien)',
          autoShort: 'Auto',
        ),
        [
          (icon: null, text: 'Portugiesisch (Brasilien)'),
          (icon: null, text: 'PT-BR'),
          (icon: null, text: 'PT'),
          (icon: null, text: null),
        ],
      );
    });
  });

  group('LanguagePairBar', () {
    late List<String> taps;

    setUp(() => taps = []);

    LanguagePairSide side(String name, {bool enabled = true}) =>
        LanguagePairSide(
          key: Key(name),
          label: name,
          semanticLabel: 'Language: $name',
          icon: name == 'Pirate' ? Icons.auto_awesome : null,
          onPressed: enabled ? () => taps.add(name) : null,
        );

    Future<void> pump(
      WidgetTester tester,
      Widget bar, {
      Size size = const Size(400, 300),
      double textScale = 1,
    }) async {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpApp(
        Scaffold(
          body: Padding(padding: const EdgeInsets.all(16), child: bar),
        ),
      );
    }

    Widget go() => ComposerGoButton(
      key: const Key('go'),
      label: 'Go',
      onPressed: () => taps.add('go'),
    );

    testWidgets('names the languages and opens their pickers', (tester) async {
      await pump(
        tester,
        LanguagePairBar(
          source: side('English'),
          target: side('Pirate'),
          trailing: [go()],
        ),
      );
      expect(find.byType(ComposerBar), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.bySemanticsLabel('Language: Pirate'), findsOneWidget);
      // A custom language shows its icon; the arrow is decorative.
      expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
      expect(find.byType(LanguagePairArrow), findsOneWidget);
      await tester.tap(find.byKey(const Key('English')));
      await tester.tap(find.byKey(const Key('Pirate')));
      await tester.tap(find.byKey(const Key('go')));
      expect(taps, ['English', 'Pirate', 'go']);
      // The target is a little bolder.
      final source = tester.widget<TextButton>(
        find.byKey(const Key('English')),
      );
      final target = tester.widget<TextButton>(find.byKey(const Key('Pirate')));
      expect(source.style!.textStyle!.resolve({})!.fontWeight, FontWeight.w700);
      expect(target.style!.textStyle!.resolve({})!.fontWeight, FontWeight.w800);
    });

    testWidgets('disables a language without a callback', (tester) async {
      await pump(
        tester,
        LanguagePairBar(
          source: side('English', enabled: false),
          target: side('French'),
          middle: const LanguagePairProgress(),
        ),
      );
      final source = tester.widget<TextButton>(
        find.byKey(const Key('English')),
      );
      expect(source.onPressed, isNull);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('a long name takes the room the short one leaves', (
      tester,
    ) async {
      await pump(
        tester,
        LanguagePairBar(
          source: side('Detect language from the text'),
          target: side('Ga'),
        ),
      );
      final source = tester.getSize(
        find.byKey(const Key('Detect language from the text')),
      );
      final target = tester.getSize(find.byKey(const Key('Ga')));
      expect(source.width, greaterThan(target.width * 2));
    });

    testWidgets('moves the other controls below the pill when narrow', (
      tester,
    ) async {
      await pump(
        tester,
        LanguagePairBar(
          source: side('English'),
          target: side('French'),
          leading: [
            IconButton(
              key: const Key('options'),
              onPressed: () {},
              icon: const Icon(Icons.tune),
            ),
          ],
          trailing: [go()],
        ),
        size: const Size(320, 640),
        textScale: 2,
      );
      final pill = find.byType(ComposerBar);
      expect(pill, findsOneWidget);
      expect(
        find.descendant(of: pill, matching: find.byKey(const Key('go'))),
        findsNothing,
      );
      expect(find.byKey(const Key('go')), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const Key('go'))).dy,
        greaterThan(tester.getBottomLeft(pill).dy),
      );
      // Options at the start, go at the end.
      expect(
        tester.getCenter(find.byKey(const Key('options'))).dx,
        lessThan(tester.getCenter(find.byKey(const Key('go'))).dx),
      );
    });
  });

  group('LanguagePairBar with label forms', () {
    LanguagePairSide side(Language language, String label) => LanguagePairSide(
      key: Key(language.code),
      label: label,
      semanticLabel: 'Language: $label',
      forms: languagePairForms(language, label: label, autoShort: 'Auto'),
      onPressed: () {},
    );

    Future<void> pump(WidgetTester tester, double width) async {
      tester.view
        ..physicalSize = Size(width, 300)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpApp(
        Scaffold(
          body: LanguagePairBar(
            source: side(Language.auto, 'Sprache erkennen'),
            target: side(
              const Language(code: 'fr', name: 'French'),
              'Französisch',
            ),
          ),
        ),
      );
    }

    testWidgets('shows the names where they fit', (tester) async {
      await pump(tester, 800);
      expect(find.text('Sprache erkennen'), findsOneWidget);
      expect(find.text('Französisch'), findsOneWidget);
    });

    testWidgets('shortens them instead of cutting them', (tester) async {
      await pump(tester, 300);
      expect(find.text('Sprache erkennen'), findsNothing);
      expect(find.text('Auto'), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome_outlined), findsOneWidget);
      expect(find.text('FR'), findsOneWidget);
      expect(find.bySemanticsLabel('Language: Französisch'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('LanguageSwapButton', () {
    Future<void> pump(WidgetTester tester, Widget button) =>
        tester.pumpApp(Scaffold(body: Center(child: button)));

    testWidgets('swaps with a tick and half a turn', (tester) async {
      final haptics = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add('${call.arguments}');
          }
          return null;
        },
      );
      var swaps = 0;
      await pump(
        tester,
        LanguageSwapButton(tooltip: 'Swap', onPressed: () => swaps++),
      );
      await tester.tap(find.byTooltip('Swap'));
      await tester.pumpAndSettle();
      expect(swaps, 1);
      expect(haptics, ['HapticFeedbackType.selectionClick']);
      expect(
        tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns,
        0.5,
      );
    });

    testWidgets('is disabled without a callback', (tester) async {
      await pump(
        tester,
        const LanguageSwapButton(tooltip: 'Swap', onPressed: null),
      );
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        null,
      );
    });

    testWidgets('long presses also while disabled', (tester) async {
      var longPresses = 0;
      await pump(
        tester,
        LanguageSwapButton(
          tooltip: 'Swap',
          onPressed: () {},
          onLongPress: () => longPresses++,
          longPressHint: 'Show recent pairs',
        ),
      );
      final handle = tester.ensureSemantics();
      expect(
        tester.getSemantics(find.byType(IconButton)),
        matchesSemantics(
          tooltip: 'Swap',
          isButton: true,
          isEnabled: true,
          hasEnabledState: true,
          isFocusable: true,
          hasTapAction: true,
          hasLongPressAction: true,
          hasFocusAction: true,
          onLongPressHint: 'Show recent pairs',
        ),
      );
      handle.dispose();
      await tester.longPress(find.byType(IconButton));
      expect(longPresses, 1);

      await pump(
        tester,
        LanguageSwapButton(
          tooltip: 'Swap',
          onPressed: null,
          onLongPress: () => longPresses++,
        ),
      );
      await tester.longPress(find.byType(IconButton));
      expect(longPresses, 2);
    });
  });
}
