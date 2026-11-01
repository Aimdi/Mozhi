import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_offline.dart';
import '../helpers/helpers.dart';

/// [finder] inside the language picker.
Finder _inPicker(Finder finder) =>
    find.descendant(of: find.byType(LanguagePickerSheet), matching: finder);

void main() {
  setUpAll(registerTranslateFallbacks);

  group('LanguageBar', () {
    testWidgets('shows "Detect language" before anything is detected', (
      tester,
    ) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      expect(find.text('Detect language'), findsOneWidget);
      expect(find.text('French'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Source language: Detect language'),
        findsOneWidget,
      );
    });

    testWidgets('shows the detected language', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const LanguageBar());
      expect(find.text('English'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Source language: Detected: English'),
        findsOneWidget,
      );
    });

    testWidgets('flags a detection the engine is unsure about', (tester) async {
      // Two words: only the engine's second detection says it is unsure,
      // and the bar agrees with the chips under the translation.
      final harness = TranslateHarness(
        state: translatedState(
          input: 'Bank Gift',
          result: const TranslationResult(
            engineId: 'mozhi:deepl',
            engineName: 'DeepL',
            text: 'Banque cadeau',
            detectedSource: 'en',
            detectionUncertain: true,
            detectedAlternatives: ['de'],
          ),
        ),
      );
      await harness.pump(tester, child: const LanguageBar());
      expect(
        find.bySemanticsLabel('Source language: Detected: English?'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.help_outline), findsOneWidget);
    });

    testWidgets('updates when only the engine verdict changes', (tester) async {
      const certain = TranslationResult(
        engineId: 'mozhi:deepl',
        engineName: 'DeepL',
        text: 'Banque cadeau',
        detectedSource: 'en',
      );
      final initial = translatedState(input: 'Bank Gift', result: certain);
      final harness = TranslateHarness(state: initial);
      final states = StreamController<TranslateState>.broadcast();
      addTearDown(states.close);
      when(() => harness.translate.stream).thenAnswer((_) => states.stream);
      await harness.pump(tester, child: const LanguageBar());
      expect(find.byIcon(Icons.help_outline), findsNothing);

      final unsure = translatedState(
        input: 'Bank Gift',
        result: certain.copyWith(detectionUncertain: true),
      );
      harness.setState(unsure);
      states.add(unsure);
      await tester.pump();
      expect(find.byIcon(Icons.help_outline), findsOneWidget);
    });

    testWidgets('shows the selected source language', (tester) async {
      final harness = TranslateHarness(state: readyState(source: german));
      await harness.pump(tester, child: const LanguageBar());
      expect(find.text('German'), findsOneWidget);
    });

    testWidgets('swap calls swap when allowed', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const LanguageBar());
      await tester.tap(find.byTooltip('Swap languages'));
      verify(harness.translate.swap).called(1);
    });

    testWidgets('swapping does not tick with haptic feedback off', (
      tester,
    ) async {
      final clipboard = FakeClipboard(tester);
      final harness = TranslateHarness(
        state: translatedState(),
        settings: const AppSettings(hapticFeedback: false),
      );
      await harness.pump(tester, child: const LanguageBar());
      await tester.tap(find.byKey(const Key('translate_swap_button')));
      await tester.pump();
      expect(clipboard.haptics, isEmpty);
      verify(harness.translate.swap).called(1);
    });

    testWidgets('swapping ticks and turns the icon', (tester) async {
      final clipboard = FakeClipboard(tester);
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const LanguageBar());
      await tester.tap(find.byKey(const Key('translate_swap_button')));
      await tester.pump();
      expect(clipboard.haptics, ['HapticFeedbackType.selectionClick']);
      final rotation = tester.widget<AnimatedRotation>(
        find.descendant(
          of: find.byKey(const Key('translate_swap_button')),
          matching: find.byType(AnimatedRotation),
        ),
      );
      expect(rotation.turns, 0.5);
      expect(rotation.duration, const Duration(milliseconds: 200));
    });

    testWidgets('swapped names trade places', (tester) async {
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      final initial = readyState(source: english, target: german);
      final harness = TranslateHarness(state: initial);
      whenListen(harness.translate, states.stream, initialState: initial);
      await harness.pump(tester, child: const LanguageBar());
      final source = tester.getTopLeft(find.text('English')).dx;
      final target = tester.getTopLeft(find.text('German')).dx;
      states.add(readyState(source: german, target: english));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Old and new names during the motion (screen readers hear the new
      // ones: the buttons are labelled).
      expect(find.text('German'), findsNWidgets(2));
      expect(find.text('English'), findsNWidgets(2));
      // The names trade places: every copy of each is on its way across,
      // between the two buttons.
      for (final name in ['German', 'English']) {
        for (var i = 0; i < 2; i++) {
          final x = tester.getTopLeft(find.text(name).at(i)).dx;
          expect(x, greaterThan(source + 1), reason: '$name $i');
          expect(x, lessThan(target - 1), reason: '$name $i');
        }
      }
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('German')).dx,
        lessThan(tester.getTopLeft(find.text('English')).dx),
      );
      expect(find.text('German'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.bySemanticsLabel('Source language: German'), findsOneWidget);
    });

    testWidgets('a picked name slides in a little way', (tester) async {
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      final initial = readyState(source: english, target: german);
      final harness = TranslateHarness(state: initial);
      whenListen(harness.translate, states.stream, initialState: initial);
      await harness.pump(tester, child: const LanguageBar());
      states.add(readyState(source: english, target: japanese));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(SlideTransition), findsWidgets);
      expect(find.text('English'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Japanese'), findsOneWidget);
    });

    testWidgets('TranslateLanguageAnchors find their buttons', (tester) async {
      final source = GlobalKey();
      final target = GlobalKey();
      final anchors = TranslateLanguageAnchors(
        source: source,
        target: target,
        child: const SizedBox(),
      );
      // Not on the screen.
      expect(anchors.rectOf(source: true), isNull);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: [
              Positioned(
                left: 10,
                top: 20,
                width: 30,
                height: 40,
                child: SizedBox(key: source),
              ),
            ],
          ),
        ),
      );
      expect(anchors.rectOf(source: true), const Rect.fromLTWH(10, 20, 30, 40));
      expect(anchors.rectOf(source: false), isNull);
      expect(anchors.keyOf(source: false), target);
      expect(
        anchors.updateShouldNotify(
          TranslateLanguageAnchors(
            source: source,
            target: target,
            child: const SizedBox(),
          ),
        ),
        isFalse,
      );
      expect(
        anchors.updateShouldNotify(
          TranslateLanguageAnchors(
            source: GlobalKey(),
            target: target,
            child: const SizedBox(),
          ),
        ),
        isTrue,
      );
    });

    test('translateLanguagesSwapped', () {
      final before = readyState(source: english, target: german);
      expect(
        translateLanguagesSwapped(
          before,
          readyState(source: german, target: english),
        ),
        isTrue,
      );
      // One language picked, or nothing changed: not a swap.
      expect(
        translateLanguagesSwapped(before, readyState(source: english)),
        isFalse,
      );
      expect(translateLanguagesSwapped(before, before), isFalse);
      expect(
        translateLanguagesSwapped(before, readyState(source: german)),
        isFalse,
      );
      // From "Detect language": the detected language becomes the target.
      final detected = translatedState();
      expect(
        translateLanguagesSwapped(
          detected,
          readyState(source: french, target: english),
        ),
        isTrue,
      );
      expect(
        translateLanguagesSwapped(
          readyState(),
          readyState(source: french, target: english),
        ),
        isFalse,
      );
      expect(
        translateLanguagesSwapped(
          translatedState(
            result: const TranslationResult(
              engineId: 'mozhi:deepl',
              engineName: 'DeepL',
              text: 'x',
              detectedSource: 'de',
            ),
          ),
          readyState(source: french, target: english),
        ),
        isFalse,
      );
    });

    testWidgets('swapped names switch at once with reduced motion', (
      tester,
    ) async {
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      final initial = readyState(source: english, target: german);
      final harness = TranslateHarness(state: initial);
      whenListen(harness.translate, states.stream, initialState: initial);
      await harness.pump(
        tester,
        child: const LanguageBar(),
        disableAnimations: true,
      );
      states.add(readyState(source: german, target: english));
      await tester.pump();
      await tester.pump();
      expect(find.text('German'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
    });

    testWidgets('marks a custom source', (tester) async {
      final harness = TranslateHarness(
        state: readyState(
          engine: claude,
          source: const Language.custom('Gen Z slang'),
        ),
      );
      await harness.pump(tester, child: const LanguageBar());
      expect(find.text('Gen Z slang'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('translate_source_button')),
          matching: find.byIcon(Icons.auto_awesome),
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Source language: Gen Z slang'),
        findsOneWidget,
      );
    });

    testWidgets('swap is disabled with "Detect language" before anything '
        'was detected, its tooltip kept, no tick nor turn', (tester) async {
      final clipboard = FakeClipboard(tester);
      final harness = TranslateHarness(state: readyState(input: 'Hallo'));
      await harness.pump(tester, child: const LanguageBar());
      final swap = tester.widget<IconButton>(
        find.byKey(const Key('translate_swap_button')),
      );
      expect(swap.onPressed, isNull);
      expect(find.byTooltip('Swap languages'), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('translate_swap_button')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(clipboard.haptics, isEmpty);
      verifyNever(harness.translate.swap);
      final rotation = tester.widget<AnimatedRotation>(
        find.descendant(
          of: find.byKey(const Key('translate_swap_button')),
          matching: find.byType(AnimatedRotation),
        ),
      );
      expect(rotation.turns, 0);
    });

    testWidgets('swap is disabled for a custom target', (tester) async {
      final harness = TranslateHarness(
        state: readyState(
          engine: claude,
          target: const Language.custom('Pirate speak'),
        ),
      );
      await harness.pump(tester, child: const LanguageBar());
      final swap = tester.widget<IconButton>(
        find.byKey(const Key('translate_swap_button')),
      );
      expect(swap.onPressed, isNull);
      expect(find.text('Pirate speak'), findsOneWidget);
    });
  });

  group('LanguageBar layout', () {
    Rect rectOf(WidgetTester tester, String key) =>
        tester.getRect(find.byKey(Key(key)));

    Future<void> pumpBar(
      WidgetTester tester,
      TranslateHarness harness, {
      double width = 379,
      double textScale = 1,
      TextDirection direction = TextDirection.ltr,
    }) => harness.pump(
      tester,
      textScale: textScale,
      child: Directionality(
        textDirection: direction,
        child: Center(
          child: SizedBox(width: width, child: const LanguageBar()),
        ),
      ),
    );

    testWidgets('options, source, swap, target and go in one bar', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      await pumpBar(tester, harness);
      final bar = rectOf(tester, 'translate_language_bar');
      final options = rectOf(tester, 'translate_options_button');
      final source = rectOf(tester, 'translate_source_button');
      final swap = rectOf(tester, 'translate_swap_button');
      final target = rectOf(tester, 'translate_target_button');
      final go = rectOf(tester, 'translate_translate_button');
      expect(options.left, closeTo(bar.left + 1, 1));
      expect(go.right, closeTo(bar.right - 1, 1));
      expect(options.right, lessThan(source.left));
      expect(source.right, lessThanOrEqualTo(swap.left));
      expect(swap.right, lessThanOrEqualTo(target.left));
      expect(target.right, lessThan(go.left));
      // Both names fit in half: the swap button is in the middle.
      expect(swap.center.dx, closeTo(bar.center.dx, 1));
      expect(source.width, closeTo(target.width, 0.5));
      // 48 dp touch targets.
      for (final rect in [options, source, swap, target, go]) {
        expect(rect.height, greaterThanOrEqualTo(48));
        expect(rect.width, greaterThanOrEqualTo(48));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('a long name takes the room a short one leaves', (
      tester,
    ) async {
      // (The test font is wider than Roboto: a wider bar.)
      final harness = TranslateHarness();
      await pumpBar(tester, harness, width: 600);
      final source = rectOf(tester, 'translate_source_button');
      final target = rectOf(tester, 'translate_target_button');
      expect(source.width, greaterThan(target.width));
      // "Detect language" is not cut.
      final text = tester.renderObject<RenderParagraph>(
        find.text('Detect language'),
      );
      expect(text.didExceedMaxLines, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('fits a 288 dp bar at 200 % text', (tester) async {
      final harness = TranslateHarness(
        state: readyState(source: japanese, target: german),
      );
      await pumpBar(tester, harness, width: 288, textScale: 2);
      expect(tester.takeException(), isNull);
      expect(
        rectOf(tester, 'translate_translate_button').right,
        lessThanOrEqualTo(rectOf(tester, 'translate_language_bar').right),
      );
    });

    // (The test font draws every character 1 em wide: at 100 % text a name
    // takes 14 dp per character, "German" 84 dp, "DE" 28 dp; the chevron
    // takes 18 dp, the sparkle 24 dp.)

    Finder inButton(String key, Finder finder) =>
        find.descendant(of: find.byKey(Key(key)), matching: finder);

    Finder chevronOf(String key) =>
        inButton(key, find.byIcon(Icons.expand_more));

    testWidgets('a name that does not fit first loses the chevron', (
      tester,
    ) async {
      // 90 dp for each button's content.
      final harness = TranslateHarness(
        state: readyState(source: english, target: german),
      );
      await pumpBar(tester, harness, width: 360);
      expect(find.text('German'), findsOneWidget);
      expect(chevronOf('translate_target_button'), findsNothing);
      // "English" needs 98 dp: its code, with the chevron.
      expect(find.text('English'), findsNothing);
      expect(find.text('EN'), findsOneWidget);
      expect(chevronOf('translate_source_button'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('falls back to the language codes, then drops chevrons', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: readyState(source: english, target: german),
      );
      // 51 dp each: "DE" and the chevron.
      await pumpBar(tester, harness, width: 282);
      expect(find.text('EN'), findsOneWidget);
      expect(find.text('DE'), findsOneWidget);
      expect(find.text('German'), findsNothing);
      expect(chevronOf('translate_source_button'), findsOneWidget);
      expect(chevronOf('translate_target_button'), findsOneWidget);

      // 40 dp each: the codes alone.
      await pumpBar(tester, harness, width: 260);
      expect(find.text('EN'), findsOneWidget);
      expect(find.text('DE'), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsNothing);
      // Screen readers and the tooltip still get the names.
      expect(find.bySemanticsLabel('Source language: English'), findsOneWidget);
      expect(find.bySemanticsLabel('Target language: German'), findsOneWidget);
      expect(findTooltipMessage('German'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a regional language falls back to its code, then its base', (
      tester,
    ) async {
      const brazil = Language(code: 'pt-BR', name: 'Portuguese (Brazil)');
      final harness = TranslateHarness(
        state: readyState(source: english, target: brazil),
      );
      await pumpBar(tester, harness, width: 360);
      expect(find.text('PT-BR'), findsOneWidget);
      await pumpBar(tester, harness, width: 282);
      expect(find.text('PT'), findsOneWidget);
      expect(find.text('PT-BR'), findsNothing);
      expect(findTooltipMessage('Portuguese (Brazil)'), findsOneWidget);
    });

    testWidgets('a new name that fits shows whole while it slides in', (
      tester,
    ) async {
      // "Portuguese (Brazil)" does not fit the 90 dp button ("PT-BR");
      // "French" does. The old name, fading out, is not measured: the new
      // one is not shown as "FR" until the motion ends.
      const brazil = Language(code: 'pt-BR', name: 'Portuguese (Brazil)');
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      final initial = readyState(source: english, target: brazil);
      final harness = TranslateHarness(state: initial);
      whenListen(harness.translate, states.stream, initialState: initial);
      await pumpBar(tester, harness, width: 360);
      expect(find.text('PT-BR'), findsOneWidget);

      // The target goes back to the default, French.
      states.add(readyState(source: english));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(SlideTransition), findsWidgets);
      expect(find.text('French'), findsOneWidget);
      expect(find.text('FR'), findsNothing);
      final during = rectOf(tester, 'translate_target_button');

      await tester.pumpAndSettle();
      expect(find.text('French'), findsOneWidget);
      expect(rectOf(tester, 'translate_target_button'), during);
      expect(tester.takeException(), isNull);
    });

    testWidgets('"Detect language" falls back to the sparkle', (tester) async {
      final harness = TranslateHarness(state: readyState(target: german));
      // 90 dp: the sparkle and "Auto".
      await pumpBar(tester, harness, width: 360);
      expect(find.text('Detect language'), findsNothing);
      expect(find.text('Auto'), findsOneWidget);
      expect(
        inButton(
          'translate_source_button',
          find.byIcon(Icons.auto_awesome_outlined),
        ),
        findsOneWidget,
      );
      // 51 dp: the sparkle alone.
      await pumpBar(tester, harness, width: 282);
      expect(find.text('Auto'), findsNothing);
      expect(
        inButton(
          'translate_source_button',
          find.byIcon(Icons.auto_awesome_outlined),
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Source language: Detect language'),
        findsOneWidget,
      );
      expect(findTooltipMessage('Detect language'), findsOneWidget);
    });

    testWidgets('a detected language keeps its code before its sparkle', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      // 60 dp: the sparkle and "EN".
      await pumpBar(tester, harness, width: 300);
      expect(find.text('EN'), findsOneWidget);
      expect(
        inButton(
          'translate_source_button',
          find.byIcon(Icons.auto_awesome_outlined),
        ),
        findsOneWidget,
      );
      // 50 dp: "EN" without the sparkle.
      await pumpBar(tester, harness, width: 280);
      expect(find.text('EN'), findsOneWidget);
      expect(
        inButton(
          'translate_source_button',
          find.byIcon(Icons.auto_awesome_outlined),
        ),
        findsNothing,
      );
      expect(
        find.bySemanticsLabel('Source language: Detected: English'),
        findsOneWidget,
      );
    });

    testWidgets('a custom language falls back to its sparkle', (tester) async {
      final harness = TranslateHarness(
        state: readyState(
          engine: claude,
          target: const Language.custom('Pirate speak'),
        ),
      );
      await pumpBar(tester, harness, width: 282);
      expect(find.text('Pirate speak'), findsNothing);
      expect(find.text('PI'), findsNothing);
      expect(
        inButton('translate_target_button', find.byIcon(Icons.auto_awesome)),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Target language: Pirate speak'),
        findsOneWidget,
      );
    });

    testWidgets('runs from right to left in right-to-left layouts', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      await pumpBar(tester, harness, direction: TextDirection.rtl);
      final options = rectOf(tester, 'translate_options_button');
      final source = rectOf(tester, 'translate_source_button');
      final target = rectOf(tester, 'translate_target_button');
      final go = rectOf(tester, 'translate_translate_button');
      expect(options.left, greaterThan(source.right));
      expect(source.left, greaterThan(target.right));
      expect(target.left, greaterThan(go.right));
    });

    testWidgets('the options button opens the options for every engine', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      await pumpBar(tester, harness);
      await tester.tap(find.byKey(const Key('translate_options_button')));
      await tester.pumpAndSettle();
      expect(find.byType(TranslationOptionsSheet), findsOneWidget);
    });

    testWidgets('the language pair reports intrinsic and dry sizes', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      await pumpBar(tester, harness);
      // The source button is a direct child of the pair's render object.
      final pair =
          tester
                  .renderObject(
                    find.byKey(const Key('translate_source_button')),
                  )
                  .parent!
              as RenderBox;
      final natural = pair.getMaxIntrinsicWidth(double.infinity);
      expect(
        pair.getMinIntrinsicWidth(double.infinity),
        lessThanOrEqualTo(natural),
      );
      expect(pair.getMinIntrinsicHeight(double.infinity), 48);
      expect(pair.getMaxIntrinsicHeight(double.infinity), 48);
      expect(
        pair.getDryLayout(const BoxConstraints.tightFor(width: 300)).width,
        300,
      );
      // Without a width limit every child gets its own width.
      expect(pair.getDryLayout(const BoxConstraints()).width, natural);
    });

    group('on a narrow phone with 200 % text', () {
      /// [finder] in the language bar (the screen has other "EN"s).
      Finder inBar(Finder finder) => find.descendant(
        of: find.byKey(const Key('translate_language_bar')),
        matching: finder,
      );

      /// Every name in the bar is shown whole, never cut.
      void expectNoCutNames(WidgetTester tester) {
        final paragraphs = find.descendant(
          of: find.byKey(const Key('translate_language_bar')),
          matching: find.byType(RichText),
        );
        for (final element in paragraphs.evaluate()) {
          final paragraph = element.renderObject! as RenderParagraph;
          expect(paragraph.didExceedMaxLines, isFalse);
          expect(
            paragraph.size.width,
            greaterThanOrEqualTo(
              paragraph.getMaxIntrinsicWidth(double.infinity) - 0.01,
            ),
            reason: paragraph.text.toPlainText(),
          );
        }
      }

      void expectUsableBar(WidgetTester tester) {
        expect(tester.takeException(), isNull);
        final bar = rectOf(tester, 'translate_language_bar');
        final keys = [
          'translate_options_button',
          'translate_source_button',
          'translate_swap_button',
          'translate_target_button',
          'translate_translate_button',
        ];
        var previous = bar.left;
        for (final key in keys) {
          final rect = rectOf(tester, key);
          expect(rect.left, greaterThanOrEqualTo(previous - 0.01), reason: key);
          expect(rect.width, greaterThanOrEqualTo(48), reason: key);
          expect(rect.height, greaterThanOrEqualTo(48), reason: key);
          previous = rect.right;
        }
        expect(previous, lessThanOrEqualTo(bar.right));
        expectNoCutNames(tester);
      }

      testWidgets('320 dp: names stay in semantics and tooltips', (
        tester,
      ) async {
        final harness = TranslateHarness(state: readyState(target: german));
        await harness.pump(tester, size: const Size(320, 800), textScale: 2);
        expectUsableBar(tester);
        // "Detect language" is the sparkle. (In Roboto "DE" fits, see the
        // golden; the test font's "DE" is wider than the 51 dp left.)
        expect(inBar(find.text('Detect language')), findsNothing);
        expect(inBar(find.text('German')), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(const Key('translate_source_button')),
            matching: find.byIcon(Icons.auto_awesome_outlined),
          ),
          findsOneWidget,
        );
        expect(
          find.bySemanticsLabel('Source language: Detect language'),
          findsOneWidget,
        );
        expect(
          find.bySemanticsLabel('Target language: German'),
          findsOneWidget,
        );
        expect(findTooltipMessage('Detect language'), findsOneWidget);
        expect(findTooltipMessage('German'), findsOneWidget);
      });

      testWidgets('320 dp: a detected language and long names', (tester) async {
        for (final state in [
          translatedState(),
          readyState(
            source: const Language(code: 'pt-BR', name: 'Portuguese (Brazil)'),
            target: const Language(code: 'zh-TW', name: 'Chinese (Taiwan)'),
          ),
        ]) {
          final harness = TranslateHarness(state: state);
          await harness.pump(tester, size: const Size(320, 800), textScale: 2);
          expectUsableBar(tester);
        }
      });

      testWidgets('360 dp: the language code', (tester) async {
        final harness = TranslateHarness(state: readyState(target: german));
        await harness.pump(tester, size: const Size(360, 800), textScale: 2);
        expectUsableBar(tester);
        expect(inBar(find.text('DE')), findsOneWidget);
        expect(inBar(find.text('German')), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(const Key('translate_source_button')),
            matching: find.byIcon(Icons.auto_awesome_outlined),
          ),
          findsOneWidget,
        );
        expect(
          find.bySemanticsLabel('Target language: German'),
          findsOneWidget,
        );
      });

      testWidgets('360 dp: both codes', (tester) async {
        final harness = TranslateHarness(
          state: readyState(source: english, target: japanese),
        );
        await harness.pump(tester, size: const Size(360, 800), textScale: 2);
        expectUsableBar(tester);
        expect(inBar(find.text('EN')), findsOneWidget);
        expect(inBar(find.text('JA')), findsOneWidget);
        // Tapping the code still opens the picker.
        await tester.tap(inBar(find.text('JA')));
        await tester.pumpAndSettle();
        expect(find.byType(LanguagePickerSheet), findsOneWidget);
      });
    });

    group('languageShortNames', () {
      test('is the code in upper case, then its language', () {
        expect(languageShortNames('en'), ['EN']);
        expect(languageShortNames('pt-BR'), ['PT-BR', 'PT']);
        expect(languageShortNames('zh_TW'), ['ZH_TW', 'ZH']);
        // Three letters stay whole (Filipino is not Finnish).
        expect(languageShortNames('fil'), ['FIL']);
        expect(languageShortNames(' '), isEmpty);
      });

      test('languageLabelForms: name, codes, then the icon or nothing', () {
        expect(languageLabelForms(german), [
          (icon: null, text: 'German'),
          (icon: null, text: 'DE'),
          (icon: null, text: null),
        ]);
        expect(languageLabelForms(const Language.custom('Pirate speak')), [
          (icon: Icons.auto_awesome, text: 'Pirate speak'),
          (icon: Icons.auto_awesome, text: null),
        ]);
        expect(languageLabelForms(english, icon: Icons.help_outline), [
          (icon: Icons.help_outline, text: 'English'),
          (icon: Icons.help_outline, text: 'EN'),
          (icon: null, text: 'EN'),
          (icon: Icons.help_outline, text: null),
        ]);
      });
    });

    group('languagePairSplit', () {
      test('gives half each while both fit in half', () {
        expect(languagePairSplit(200, 80, 60), (100.0, 100.0));
      });

      test('lets the longer one take what the shorter one leaves', () {
        expect(languagePairSplit(200, 140, 50), (150.0, 50.0));
        expect(languagePairSplit(200, 50, 140), (50.0, 150.0));
        // Not all of it fits: the shorter one still keeps its width.
        expect(languagePairSplit(200, 180, 60), (140.0, 60.0));
      });

      test('gives half each when neither fits in half', () {
        expect(languagePairSplit(200, 150, 120), (100.0, 100.0));
      });

      test('never goes below zero', () {
        expect(languagePairSplit(-10, 50, 50), (0.0, 0.0));
      });
    });
  });

  group('FirstThatFits', () {
    // The test font: "Long name" is 126 dp wide, "LN" 28 dp, both 14 tall.
    final taps = <String>[];

    Widget child(String text) => GestureDetector(
      onTap: () => taps.add(text),
      child: Text(text, key: ValueKey(text)),
    );

    Future<void> pumpFit(
      WidgetTester tester, {
      double? width,
      bool baseline = false,
    }) {
      taps.clear();
      final fit = FirstThatFits(
        key: const Key('fit'),
        children: [child('Long name'), child('LN')],
      );
      return tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: width,
              child: Row(
                key: const Key('row'),
                crossAxisAlignment: baseline
                    ? CrossAxisAlignment.baseline
                    : CrossAxisAlignment.center,
                textBaseline: TextBaseline.alphabetic,
                children: [Flexible(child: fit)],
              ),
            ),
          ),
        ),
      );
    }

    RenderBox fitBox(WidgetTester tester) =>
        tester.renderObject<RenderBox>(find.byKey(const Key('fit')));

    testWidgets('shows the first child that fits whole', (tester) async {
      await pumpFit(tester, width: 200);
      expect(find.text('Long name'), findsOneWidget);
      expect(find.text('LN'), findsNothing);
      expect(fitBox(tester).size, const Size(126, 14));

      await pumpFit(tester, width: 100);
      expect(find.text('Long name'), findsNothing);
      expect(find.text('LN'), findsOneWidget);
      expect(fitBox(tester).size, const Size(28, 14));
      await tester.tap(find.byKey(const Key('fit')));
      expect(taps, ['LN']);
      // The other child is still there, just not shown.
      expect(find.text('Long name', skipOffstage: false), findsOneWidget);
    });

    testWidgets('shows nothing when nothing fits', (tester) async {
      await pumpFit(tester, width: 20);
      expect(find.text('Long name'), findsNothing);
      expect(find.text('LN'), findsNothing);
      expect(fitBox(tester).size, Size.zero);
      await tester.tapAt(tester.getCenter(find.byKey(const Key('row'))));
      expect(taps, isEmpty);
    });

    testWidgets('only the child shown reaches screen readers', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpFit(tester, width: 100);
      expect(find.bySemanticsLabel('LN'), findsOneWidget);
      expect(find.bySemanticsLabel('Long name'), findsNothing);
      await pumpFit(tester, width: 20);
      expect(find.bySemanticsLabel('LN'), findsNothing);
      semantics.dispose();
    });

    testWidgets('reports its sizes for the child that would be shown', (
      tester,
    ) async {
      await pumpFit(tester, width: 100);
      final box = fitBox(tester);
      // As wide as the first child likes; it can do with nothing.
      expect(box.getMaxIntrinsicWidth(double.infinity), 126);
      expect(box.getMinIntrinsicWidth(double.infinity), 0);
      expect(box.getMinIntrinsicHeight(100), 14);
      expect(box.getMaxIntrinsicHeight(double.infinity), 14);
      expect(box.getMaxIntrinsicHeight(10), 0);
      expect(
        box.getDryLayout(const BoxConstraints(maxWidth: 100)),
        const Size(28, 14),
      );
      expect(box.getDryLayout(const BoxConstraints()), const Size(126, 14));
      expect(box.getDryLayout(const BoxConstraints(maxWidth: 10)), Size.zero);
    });

    testWidgets('has the baseline of the child shown', (tester) async {
      await pumpFit(tester, width: 100, baseline: true);
      expect(tester.takeException(), isNull);
      final row = tester.renderObject<RenderBox>(find.byKey(const Key('row')));
      // The row asks for (dry) baselines.
      expect(
        row.getDryLayout(const BoxConstraints(maxWidth: 100)).height,
        greaterThan(0),
      );
      expect(row.getDryLayout(const BoxConstraints(maxWidth: 10)).height, 0);
      await pumpFit(tester, width: 20, baseline: true);
      expect(tester.takeException(), isNull);
    });
  });

  group('LanguagePickerSheet', () {
    Future<void> openTarget(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('translate_target_button')));
      await tester.pumpAndSettle();
    }

    Future<void> openSource(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('translate_source_button')));
      await tester.pumpAndSettle();
    }

    testWidgets('lists all languages with native names', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      await openTarget(tester);
      expect(find.text('Translate to'), findsOneWidget);
      expect(find.text('All languages'), findsOneWidget);
      expect(find.text('Deutsch'), findsOneWidget);
      expect(find.text('日本語'), findsOneWidget);
      // AI styles are not offered for Mozhi engines.
      expect(find.text('Styles'), findsNothing);
    });

    testWidgets('search filters and picking sets the target', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      await openTarget(tester);
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'deu',
      );
      await tester.pump();
      expect(find.text('German'), findsOneWidget);
      expect(find.text('Japanese'), findsNothing);
      await tester.tap(find.text('German'));
      await tester.pumpAndSettle();
      verify(() => harness.translate.setTarget(german)).called(1);
      expect(find.text('Translate to'), findsNothing);
    });

    testWidgets('submitting the search picks the first match', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      await openTarget(tester);
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'ja',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      verify(() => harness.translate.setTarget(japanese)).called(1);
    });

    testWidgets('shows no results for Mozhi engines', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      await openTarget(tester);
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'Klingon',
      );
      await tester.pump();
      expect(find.text('No languages match “Klingon”'), findsOneWidget);
      expect(find.byKey(const Key('translate_language_custom')), findsNothing);
    });

    testWidgets('offers a custom language for AI engines', (tester) async {
      final harness = TranslateHarness(state: readyState(engine: claude));
      await harness.pump(tester, child: const LanguageBar());
      await openTarget(tester);
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'Yoda speak',
      );
      await tester.pump();
      expect(find.text('Use “Yoda speak” as custom language'), findsOneWidget);
      await tester.tap(find.byKey(const Key('translate_language_custom')));
      await tester.pumpAndSettle();
      verify(
        () => harness.translate.setTarget(const Language.custom('Yoda speak')),
      ).called(1);
    });

    testWidgets('submitting an unknown query picks it as custom (AI)', (
      tester,
    ) async {
      final harness = TranslateHarness(state: readyState(engine: claude));
      await harness.pump(tester, child: const LanguageBar());
      await openTarget(tester);
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'Valley girl',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      verify(
        () => harness.translate.setTarget(const Language.custom('Valley girl')),
      ).called(1);
    });

    testWidgets('offers style suggestions for AI engines', (tester) async {
      final harness = TranslateHarness(state: readyState(engine: claude));
      await harness.pump(tester, child: const LanguageBar());
      await openTarget(tester);
      // Languages first: the styles are behind their segment.
      expect(find.text('All languages'), findsOneWidget);
      expect(find.text('LinkedIn Speak'), findsNothing);
      await tester.tap(find.text('Styles'));
      await tester.pumpAndSettle();
      expect(find.text('All languages'), findsNothing);
      expect(
        find.text(
          'AI models can translate into any dialect or style you describe.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('LinkedIn Speak'));
      await tester.pumpAndSettle();
      verify(
        () => harness.translate.setTarget(
          const Language.custom('LinkedIn Speak'),
        ),
      ).called(1);
    });

    testWidgets('search also filters styles', (tester) async {
      final harness = TranslateHarness(state: readyState(engine: claude));
      await harness.pump(tester, child: const LanguageBar());
      await openTarget(tester);
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'pirate',
      );
      await tester.pump();
      expect(find.text('Pirate speak'), findsOneWidget);
      expect(find.text('LinkedIn Speak'), findsNothing);
      expect(find.text('Use “pirate” as custom language'), findsOneWidget);
    });

    testWidgets('shows recent and pinned sections', (tester) async {
      final harness = TranslateHarness(
        settings: const AppSettings(
          recentLanguages: [german, Language.custom('Pirate speak')],
          pinnedLanguages: [japanese],
        ),
      );
      await harness.pump(
        tester,
        child: const LanguageBar(),
        size: const Size(800, 1600),
      );
      await openTarget(tester);
      expect(find.text('Recent'), findsOneWidget);
      expect(find.text('Pinned'), findsOneWidget);
      expect(find.text('German'), findsNWidgets(2));
      expect(find.text('Japanese'), findsNWidgets(2));
      // Custom recents are hidden for Mozhi engines.
      expect(find.text('Pirate speak'), findsNothing);
      // The pin button shows on the Recent and Pinned rows, not in All
      // languages (only while hovered or focused there).
      expect(find.byTooltip('Unpin Japanese'), findsOneWidget);
      expect(find.byTooltip('Pin German'), findsOneWidget);
    });

    testWidgets('lists the pins the engine offers, numbered on desktop', (
      tester,
    ) async {
      // A pin saved from another engine ("de-DE") is matched like
      // everywhere else; Korean is not offered.
      const germany = Language(code: 'de-DE', name: 'German (Germany)');
      const korean = Language(code: 'ko', name: 'Korean');
      final harness = TranslateHarness(
        settings: const AppSettings(
          pinnedLanguages: [korean, germany, japanese],
        ),
      );
      await harness.pump(
        tester,
        child: const LanguageBar(),
        size: const Size(1000, 1600),
        platform: TargetPlatform.linux,
      );
      await openTarget(tester);
      expect(find.text('Pinned'), findsOneWidget);
      expect(find.text('Korean'), findsNothing);
      final germanShortcut = find.byKey(
        const ValueKey('translate_language_shortcut:de'),
      );
      expect(tester.widget<Text>(germanShortcut).data, 'Alt + 1');
      expect(tester.widget<Text>(germanShortcut).semanticsLabel, 'Alt 1');
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('translate_language_shortcut:ja')),
            )
            .data,
        'Alt + 2',
      );
      // Only the Pinned entries are numbered.
      expect(find.text('Alt + 3'), findsNothing);
      // Unpinning removes the saved pin.
      await tester.tap(find.byTooltip('Unpin German').first);
      verify(() => harness.settings.togglePinnedLanguage(germany)).called(1);
    });

    testWidgets('pins are not numbered on phones or in the source list', (
      tester,
    ) async {
      final harness = TranslateHarness(
        settings: const AppSettings(pinnedLanguages: [german]),
      );
      await harness.pump(
        tester,
        child: const LanguageBar(),
        size: const Size(800, 1600),
      );
      await openTarget(tester);
      expect(find.text('Pinned'), findsOneWidget);
      expect(find.text('Alt + 1'), findsNothing);
    });

    testWidgets('pin button and long press toggle pins', (tester) async {
      final harness = TranslateHarness(
        settings: const AppSettings(recentLanguages: [french]),
      );
      await harness.pump(tester, child: const LanguageBar());
      await openTarget(tester);
      await tester.tap(find.byTooltip('Pin French'));
      verify(() => harness.settings.togglePinnedLanguage(french)).called(1);
      await tester.longPress(find.text('German'));
      verify(() => harness.settings.togglePinnedLanguage(german)).called(1);
    });

    testWidgets('source picker starts with detect language', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const LanguageBar());
      await openSource(tester);
      expect(find.text('Translate from'), findsOneWidget);
      expect(find.byKey(const Key('translate_language_auto')), findsOneWidget);
      expect(find.text('Detected: English'), findsOneWidget);
      // No styles in the source list, even for AI engines.
      expect(find.text('Styles'), findsNothing);
      await tester.tap(find.byKey(const Key('translate_language_auto')));
      await tester.pumpAndSettle();
      verify(() => harness.translate.setSource(Language.auto)).called(1);
    });

    testWidgets('source picker sets a source language', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      await openSource(tester);
      await tester.tap(find.text('French').last);
      await tester.pumpAndSettle();
      verify(() => harness.translate.setSource(french)).called(1);
    });

    testWidgets('source picker offers a custom language for AI engines', (
      tester,
    ) async {
      final harness = TranslateHarness(state: readyState(engine: claude));
      await harness.pump(tester, child: const LanguageBar());
      await openSource(tester);
      // Style suggestions stay in the target list.
      expect(find.text('Styles'), findsNothing);
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'Gen Z slang',
      );
      await tester.pump();
      expect(find.text('Use “Gen Z slang” as custom language'), findsOneWidget);
      expect(
        find.text(
          'AI models can translate from any dialect or style you describe.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('translate_language_custom')));
      await tester.pumpAndSettle();
      verify(
        () => harness.translate.setSource(const Language.custom('Gen Z slang')),
      ).called(1);
    });

    testWidgets('submitting an unknown source query picks it as custom', (
      tester,
    ) async {
      final harness = TranslateHarness(state: readyState(engine: claude));
      await harness.pump(tester, child: const LanguageBar());
      await openSource(tester);
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'Shakespearean English',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      verify(
        () => harness.translate.setSource(
          const Language.custom('Shakespearean English'),
        ),
      ).called(1);
    });

    testWidgets('source picker has no custom language for Mozhi engines', (
      tester,
    ) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      await openSource(tester);
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'Gen Z slang',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(find.byKey(const Key('translate_language_custom')), findsNothing);
      expect(find.text('No languages match “Gen Z slang”'), findsOneWidget);
      verifyNever(() => harness.translate.setSource(any()));
    });

    testWidgets('source picker lists recent custom languages for AI', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: readyState(
          engine: claude,
          source: const Language.custom('Gen Z slang'),
        ),
        settings: const AppSettings(
          recentLanguages: [Language.custom('Gen Z slang')],
        ),
      );
      await harness.pump(tester, child: const LanguageBar());
      await openSource(tester);
      expect(find.text('Recent'), findsOneWidget);
      expect(find.text('Custom'), findsOneWidget);
      // The current custom source is selected.
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('dismissing does not change anything', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      await openSource(tester);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      verifyNever(() => harness.translate.setSource(any()));
    });

    testWidgets('is full screen on phones', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: const LanguageBar(),
        size: const Size(360, 740),
      );
      await openTarget(tester);
      final dialog = tester.widget<Dialog>(find.byType(Dialog));
      expect(dialog.insetPadding, EdgeInsets.zero);
      expect(
        tester.getSize(find.byType(LanguagePickerSheet)),
        const Size(360, 740),
      );
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(LanguagePickerSheet), findsNothing);
      verifyNever(() => harness.translate.setTarget(any()));
    });

    testWidgets('is a dialog on wide windows', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: const LanguageBar(),
        size: const Size(1200, 900),
      );
      await openTarget(tester);
      final size = tester.getSize(find.byType(LanguagePickerSheet));
      expect(size.width, lessThanOrEqualTo(languagePickerDialogSize.width));
      expect(size.height, lessThanOrEqualTo(languagePickerDialogSize.height));
      // Tapping outside closes it.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byType(LanguagePickerSheet), findsNothing);
    });

    testWidgets('finds languages without their diacritics', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      await openTarget(tester);
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'francais',
      );
      await tester.pump();
      expect(find.text('Français'), findsOneWidget);
      expect(find.text('Deutsch'), findsNothing);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      verify(() => harness.translate.setTarget(french)).called(1);
    });

    testWidgets('lists the detected language in the source picker', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(
        tester,
        child: const LanguageBar(),
        size: const Size(800, 1600),
      );
      await openSource(tester);
      final header = find.byKey(
        const Key('translate_language_section_detected'),
      );
      expect(header, findsOneWidget);
      expect(find.text('Detected'), findsOneWidget);
      // Picking it sets the source explicitly.
      final detected = _inPicker(find.text('English')).first;
      expect(
        tester.getTopLeft(detected).dy,
        greaterThan(tester.getTopLeft(header).dy),
      );
      await tester.tap(detected);
      await tester.pumpAndSettle();
      verify(() => harness.translate.setSource(english)).called(1);
    });

    testWidgets('has no detected section in the target picker', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const LanguageBar());
      await openTarget(tester);
      expect(
        find.byKey(const Key('translate_language_section_detected')),
        findsNothing,
      );
    });

    testWidgets('lists other likely languages of an uncertain detection', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: translatedState(
          input: 'Gift',
          result: const TranslationResult(
            engineId: 'mozhi:deepl',
            engineName: 'DeepL',
            text: 'Cadeau',
            detectedSource: 'en',
            detectionUncertain: true,
            detectedAlternatives: ['de'],
          ),
        ),
      );
      await harness.pump(
        tester,
        child: const LanguageBar(),
        size: const Size(800, 1600),
      );
      await openSource(tester);
      // Detected (English, German), then All languages.
      expect(_inPicker(find.text('English')), findsNWidgets(2));
      expect(_inPicker(find.text('German')), findsNWidgets(2));
    });

    testWidgets('marks and lists the languages that work offline', (
      tester,
    ) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: const LanguageBar(),
        size: const Size(800, 1600),
        offline: FakeOfflineTranslator(downloaded: {'de'}),
      );
      await openTarget(tester);
      expect(
        find.byKey(const Key('translate_language_section_downloaded')),
        findsOneWidget,
      );
      expect(find.text('Downloaded (offline)'), findsOneWidget);
      // German and English (the pivot) under Downloaded and All.
      expect(
        find.byKey(const ValueKey('translate_language_offline:de')),
        findsNWidgets(2),
      );
      expect(
        find.byKey(const ValueKey('translate_language_offline:en')),
        findsNWidgets(2),
      );
      expect(
        find.byKey(const ValueKey('translate_language_offline:fr')),
        findsNothing,
      );
      expect(find.bySemanticsLabel(RegExp('Works offline')), findsWidgets);
    });

    testWidgets('marks nothing while only English is on the device', (
      tester,
    ) async {
      for (final offline in [
        FakeOfflineTranslator(),
        FakeOfflineTranslator(isAvailable: false, downloaded: {'de'}),
        FakeOfflineTranslator(downloaded: {'de'}, fails: true),
      ]) {
        final harness = TranslateHarness();
        await harness.pump(
          tester,
          child: const LanguageBar(),
          offline: offline,
        );
        await openTarget(tester);
        expect(
          find.byKey(const Key('translate_language_section_downloaded')),
          findsNothing,
        );
        expect(find.byTooltip('Works offline'), findsNothing);
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('clear button resets the search', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      await openTarget(tester);
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'xyz',
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Clear'));
      await tester.pump();
      expect(find.text('All languages'), findsOneWidget);
    });
  });
}
