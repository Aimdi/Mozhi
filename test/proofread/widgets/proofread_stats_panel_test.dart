import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/widgets/proofread_stats_panel.dart';

import '../../helpers/helpers.dart';

const _original = 'I has a apple. It are red.';
const _corrected = 'I have an apple. It is red.';

void main() {
  group('proofreadNumberLocale', () {
    test('uses the locale, else its language, else English', () {
      expect(proofreadNumberLocale(const Locale('de')), 'de');
      expect(proofreadNumberLocale(const Locale('pt', 'BR')), 'pt_BR');
      expect(proofreadNumberLocale(const Locale('fr', 'XX')), 'fr');
      expect(proofreadNumberLocale(const Locale('xx')), 'en');
    });
  });

  group('ProofreadStatsPanel', () {
    Future<void> pumpPanel(
      WidgetTester tester, {
      String original = _original,
      String corrected = _corrected,
      String? languageCode = 'en',
      Locale locale = const Locale('en'),
      TextDirection? direction,
      double textScale = 1,
      Size size = const Size(800, 1600),
      ThemeData? theme,
    }) async {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Widget panel = ProofreadStatsPanel(
        original: original,
        corrected: corrected,
        languageCode: languageCode,
      );
      if (direction != null) {
        panel = Directionality(textDirection: direction, child: panel);
      }
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          theme: theme ?? ThemeData(useMaterial3: true),
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: panel,
                ),
              ),
            ),
          ),
        ),
      );
    }

    Future<void> expand(WidgetTester tester, {String? title}) async {
      await tester.tap(find.text(title ?? 'Writing statistics'));
      await tester.pumpAndSettle();
    }

    testWidgets('is collapsed with the corrected word count and time', (
      tester,
    ) async {
      await pumpPanel(tester);
      expect(find.text('Writing statistics'), findsOneWidget);
      expect(find.text('7 words · 2 sec read'), findsOneWidget);
      expect(find.text('Words'), findsNothing);
      expect(find.byIcon(Icons.insights_outlined), findsOneWidget);
    });

    testWidgets('expands to every statistic before and after', (tester) async {
      await pumpPanel(tester);
      await expand(tester);
      expect(find.text('Words'), findsOneWidget);
      expect(find.text('Characters'), findsOneWidget);
      expect(find.text('Sentences'), findsOneWidget);
      expect(find.text('Paragraphs'), findsOneWidget);
      expect(find.text('Words per sentence'), findsOneWidget);
      expect(find.text('Reading time'), findsOneWidget);
      expect(find.text('Flesch reading ease'), findsOneWidget);
      expect(find.text('0–100, higher is easier to read'), findsOneWidget);
      // Changed: characters 26 -> 27 (the arrow is an icon). Unchanged:
      // words, sentences, paragraphs, words per sentence and reading time.
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText &&
              widget.text.toPlainText(includePlaceholders: false) == '2627',
        ),
        findsOneWidget,
      );
      expect(find.text('7'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('3.5'), findsOneWidget);
      expect(find.text('2 sec'), findsOneWidget);
    });

    testWidgets('shows a legend of the original and corrected values', (
      tester,
    ) async {
      await pumpPanel(tester);
      await expand(tester);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText &&
              widget.text.toPlainText(includePlaceholders: false) ==
                  'OriginalCorrected',
        ),
        findsOneWidget,
      );
    });

    testWidgets('reads each statistic as one item with before and after', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpPanel(tester);
      await expand(tester);
      expect(
        find.bySemanticsLabel(
          'Characters\n26 originally, 27 after corrections',
        ),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Words\n7'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Original|Corrected')), findsNothing);
      semantics.dispose();
    });

    testWidgets('shows the Flesch score and band for English', (tester) async {
      await pumpPanel(
        tester,
        original:
            'Comprehensive documentation facilitates organizational '
            'understanding.',
        corrected: 'Good notes help people understand.',
      );
      await expand(tester);
      final flesch = find.byKey(const Key('proofread_stats_flesch'));
      expect(flesch, findsOneWidget);
      String plain(Finder finder) => tester
          .widgetList<RichText>(find.descendant(of: flesch, matching: finder))
          .map((t) => t.text.toPlainText(includePlaceholders: false))
          .join('|');
      final text = plain(find.byType(RichText));
      // 5 words, 1 sentence, 8 syllables: 206.835 - 5.075 - 135.36.
      expect(text, contains('0.0'));
      expect(text, contains('66.4'));
      expect(text, contains('Very difficult'));
      expect(text, contains('Plain English'));
    });

    testWidgets('hides the Flesch score for other or unknown languages', (
      tester,
    ) async {
      await pumpPanel(tester, languageCode: 'de');
      await expand(tester);
      expect(find.text('Flesch reading ease'), findsNothing);

      await pumpPanel(tester, languageCode: null);
      expect(find.text('Flesch reading ease'), findsNothing);
      expect(find.text('Words'), findsOneWidget);
    });

    testWidgets('shows minutes for longer texts', (tester) async {
      await pumpPanel(
        tester,
        original: 'word ' * 300,
        corrected: 'word ' * 600,
      );
      expect(find.text('600 words · 3 min read'), findsOneWidget);
      await expand(tester);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText &&
              widget.text.toPlainText(includePlaceholders: false) ==
                  '1 min3 min',
        ),
        findsOneWidget,
      );
    });

    testWidgets('uses singular forms', (tester) async {
      await pumpPanel(tester, original: 'Hi.', corrected: 'Hi.');
      expect(find.text('1 word · 1 sec read'), findsOneWidget);
    });

    testWidgets('formats numbers for the locale', (tester) async {
      await pumpPanel(
        tester,
        original: 'word ' * 1234,
        corrected: 'word ' * 1234,
        languageCode: 'de',
        locale: const Locale('de'),
      );
      await expand(tester, title: 'Textstatistik');
      expect(find.text('1.234'), findsWidgets);
      expect(find.text('1.234,0'), findsOneWidget);
    });

    testWidgets('follows changes of the corrected text', (tester) async {
      await pumpPanel(tester);
      await expand(tester);
      expect(find.text('7'), findsOneWidget);
      await pumpPanel(tester, corrected: 'I have an apple. It is very red.');
      // Still expanded.
      expect(find.text('Words'), findsOneWidget);
      expect(find.text('8 words · 3 sec read'), findsOneWidget);
      expect(find.text('7'), findsNothing);
    });

    testWidgets('collapses again', (tester) async {
      await pumpPanel(tester);
      await expand(tester);
      await expand(tester);
      expect(find.text('Words'), findsNothing);
    });

    testWidgets('lays out right to left', (tester) async {
      await pumpPanel(tester, direction: TextDirection.rtl);
      await expand(tester);
      final label = tester.getTopLeft(find.text('Words'));
      final value = tester.getTopLeft(find.text('7'));
      expect(value.dx, lessThan(label.dx));
      expect(tester.takeException(), isNull);
    });

    testWidgets('fits a narrow screen at 200% text', (tester) async {
      await pumpPanel(
        tester,
        textScale: 2,
        size: const Size(320, 2400),
        original:
            'Comprehensive documentation facilitates organizational '
            'understanding.',
        corrected: 'Good notes help people understand.',
      );
      await expand(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Flesch reading ease'), findsOneWidget);
    });

    testWidgets('renders in dark mode', (tester) async {
      await pumpPanel(
        tester,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      );
      await expand(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Words'), findsOneWidget);
    });

    testWidgets('header is a 48dp target', (tester) async {
      await pumpPanel(tester);
      expect(
        tester.getSize(find.byType(ListTile)).height,
        greaterThanOrEqualTo(48),
      );
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    });

    testWidgets('pumpApp works with the panel', (tester) async {
      await tester.pumpApp(
        const Scaffold(
          body: ProofreadStatsPanel(original: '', corrected: ''),
        ),
      );
      expect(find.text('0 words · 0 sec read'), findsOneWidget);
    });
  });
}
