import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

/// A button that opens [text] full screen.
Widget _opener(String text, {TextDirection? textDirection, Locale? locale}) =>
    Builder(
      builder: (context) => TextButton(
        onPressed: () => showTranslationFullScreen(
          context,
          text: text,
          textDirection: textDirection,
          locale: locale,
        ),
        child: const Text('Open'),
      ),
    );

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

double _fontSize(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const Key('translate_show_mode_text')))
    .style!
    .fontSize!;

void main() {
  setUpAll(registerTranslateFallbacks);

  group('ShowModeView', () {
    testWidgets('shows the translation as large as it fits', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: _opener('Bonjour'),
        size: const Size(400, 800),
      );
      await _open(tester);
      expect(find.byKey(const Key('translate_show_mode')), findsOneWidget);
      expect(find.text('Bonjour', findRichText: true), findsOneWidget);
      final short = _fontSize(tester);
      expect(short, greaterThan(40));
      expect(short, lessThanOrEqualTo(ShowModeView.maxFontSize));
      // Black on white in the light theme.
      final scaffold = tester.widget<Scaffold>(
        find.byKey(const Key('translate_show_mode')),
      );
      expect(scaffold.backgroundColor, Colors.white);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('translate_show_mode_text')))
            .style
            ?.color,
        Colors.black,
      );
      expect(find.text('Tap anywhere to close'), findsOneWidget);
    });

    testWidgets('fits a longer text with a smaller size', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: _opener('Où est la gare la plus proche, s’il vous plaît ?'),
        size: const Size(400, 800),
      );
      await _open(tester);
      final size = _fontSize(tester);
      expect(size, greaterThanOrEqualTo(ShowModeView.minFontSize));
      expect(size, lessThan(ShowModeView.maxFontSize));
      expect(
        tester.getSize(find.byKey(const Key('translate_show_mode_text'))).width,
        lessThanOrEqualTo(400 - 48),
      );
    });

    testWidgets('lays the text out again when the device turns', (
      tester,
    ) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: _opener('Une table pour deux, s’il vous plaît'),
        size: const Size(400, 800),
      );
      await _open(tester);
      final portrait = _fontSize(tester);
      tester.view.physicalSize = const Size(800, 400);
      await tester.pumpAndSettle();
      expect(_fontSize(tester), isNot(portrait));
      expect(tester.takeException(), isNull);
    });

    testWidgets('scrolls a text too long to fit', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: _opener(List.filled(400, 'mot').join(' ')),
        size: const Size(400, 800),
      );
      await _open(tester);
      expect(_fontSize(tester), ShowModeView.minFontSize);
      expect(
        find.ancestor(
          of: find.byKey(const Key('translate_show_mode_text')),
          matching: find.byType(SingleChildScrollView),
        ),
        findsWidgets,
      );
    });

    testWidgets('keeps the direction and language of the text', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: _opener(
          'مرحبا',
          textDirection: TextDirection.rtl,
          locale: const Locale('ar'),
        ),
      );
      await _open(tester);
      final text = tester.widget<Text>(
        find.byKey(const Key('translate_show_mode_text')),
      );
      expect(text.textDirection, TextDirection.rtl);
      expect((text.textSpan! as TextSpan).locale, const Locale('ar'));
    });

    testWidgets('white on black in the dark theme', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: _opener('Bonjour'),
        themeMode: ThemeMode.dark,
      );
      await _open(tester);
      final scaffold = tester.widget<Scaffold>(
        find.byKey(const Key('translate_show_mode')),
      );
      expect(scaffold.backgroundColor, Colors.black);
    });

    testWidgets('a tap anywhere closes it', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: _opener('Bonjour'));
      await _open(tester);
      await tester.tap(find.byKey(const Key('translate_show_mode_area')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('translate_show_mode')), findsNothing);
    });

    testWidgets('the close button and Escape close it', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: _opener('Bonjour'));
      await _open(tester);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('translate_show_mode')), findsNothing);

      await _open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('translate_show_mode')), findsNothing);
    });

    testWidgets('Back closes it', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: _opener('Bonjour'));
      await _open(tester);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      await navigator.maybePop();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('translate_show_mode')), findsNothing);
    });

    testWidgets('the text can be copied', (tester) async {
      final clipboard = FakeClipboard(tester);
      final harness = TranslateHarness();
      await harness.pump(tester, child: _opener('Bonjour'));
      await _open(tester);
      await tester.tap(find.byKey(const Key('translate_show_mode_copy')));
      await tester.pump();
      expect(clipboard.copied, 'Bonjour');
      // Still open.
      expect(find.byKey(const Key('translate_show_mode')), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('screen readers hear its name, the text and the buttons', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final harness = TranslateHarness();
      await harness.pump(tester, child: _opener('Bonjour'));
      await _open(tester);
      expect(find.bySemanticsLabel('Translation, full screen'), findsOneWidget);
      expect(find.bySemanticsLabel('Bonjour'), findsOneWidget);
      expect(find.byTooltip('Copy'), findsOneWidget);
      expect(find.byTooltip('Close'), findsOneWidget);
      // The hint is for sighted users (the close button says it).
      expect(find.bySemanticsLabel('Tap anywhere to close'), findsNothing);
      handle.dispose();
    });

    testWidgets('opens at once with reduced motion', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: _opener('Bonjour'),
        disableAnimations: true,
      );
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('translate_show_mode')), findsOneWidget);
    });
  });

  group('OutputCard', () {
    testWidgets('"Show full screen" shows the translation', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(
          result: const TranslationResult(
            engineId: 'mozhi:deepl',
            engineName: 'DeepL',
            text: 'Bonjour le monde',
          ),
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      await tester.tap(find.byTooltip('Show full screen'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('translate_show_mode_text')))
            .textSpan
            ?.toPlainText(),
        'Bonjour le monde',
      );
      expect(
        (tester
                    .widget<Text>(
                      find.byKey(const Key('translate_show_mode_text')),
                    )
                    .textSpan!
                as TextSpan)
            .locale,
        const Locale('fr'),
      );
    });
  });
}
