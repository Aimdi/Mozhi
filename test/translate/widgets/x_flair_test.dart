import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

Widget _app(Widget child, {ThemeData? theme}) => MaterialApp(
  theme: theme,
  home: Scaffold(body: child),
);

void main() {
  setUpAll(registerTranslateFallbacks);

  group('InputCard compose toolbar', () {
    testWidgets('shows the count ring only once there is text', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const InputCard());
      expect(find.byType(CountRing), findsNothing);
      expect(find.byKey(const Key('translate_clear_button')), findsNothing);
    });

    testWidgets('shows the count ring, the count and clear with text', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const InputCard());
      final ring = tester.widget<CountRing>(find.byType(CountRing));
      expect(ring.count, 'Hello world'.length);
      expect(ring.limit, TranslateCubit.maxInputLength);
      expect(find.text('11 characters'), findsOneWidget);
      expect(find.byKey(const Key('translate_clear_button')), findsOneWidget);
    });

    testWidgets('paints the toolbar icons in the accent colour', (
      tester,
    ) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const InputCard());
      final context = tester.element(
        find.byKey(const Key('translate_paste_button')),
      );
      final style = IconButtonTheme.of(context).style;
      expect(
        style?.foregroundColor?.resolve({}),
        Theme.of(context).colorScheme.primary,
      );
    });

    testWidgets('is flat: no filled box', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const InputCard());
      final card = tester.widget<Card>(
        find.descendant(
          of: find.byKey(const Key('translate_input_card')),
          matching: find.byType(Card),
        ),
      );
      expect(card.color, Colors.transparent);
    });
  });

  group('OutputCard X post', () {
    testWidgets('header names the target in bold with the meta line', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const OutputCard());
      final name = tester.widget<Text>(
        find.byKey(const Key('translate_output_language')),
      );
      expect(name.data, 'French');
      expect(name.style?.fontWeight, FontWeight.w800);
      expect(find.text('DeepL · 0.8 s'), findsOneWidget);
      expect(find.text(' · '), findsOneWidget);
    });

    testWidgets('screen readers hear the language, then the engine', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const OutputCard());
      final node = tester.getSemantics(
        find.byKey(const Key('translate_output_language')),
      );
      expect(node.label, startsWith('French'));
      expect(node.label, contains('DeepL · 0.8 s'));
      expect(node.label, isNot(contains(' ·  · ')));
      handle.dispose();
    });

    testWidgets('header shows the language while translating', (tester) async {
      final harness = TranslateHarness(
        state: readyState(input: 'Hi', status: TranslateStatus.translating),
      );
      await harness.pump(tester, child: const OutputCard());
      expect(
        find.byKey(const Key('translate_output_language')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('translate_output_footer')), findsNothing);
    });

    testWidgets('favourite is a heart', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const OutputCard());
      final button = tester.widget<XActionButton>(
        find.byKey(const Key('translate_favorite_button')),
      );
      expect(button.icon, Icons.favorite_border);
      expect(button.activeIcon, Icons.favorite);
      expect(button.active, isFalse);
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    });

    testWidgets('a favourite shows the filled heart in the like colour', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: translatedState(),
        history: HistoryState(
          status: HistoryStatus.ready,
          entries: [
            HistoryEntry(
              id: '1',
              text: 'Hello world',
              translation: 'Bonjour le monde',
              source: Language.auto,
              target: french,
              engineId: 'mozhi:deepl',
              engineName: 'DeepL',
              createdAt: DateTime(2026),
              isFavorite: true,
            ),
          ],
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      final context = tester.element(
        find.byKey(const Key('translate_favorite_button')),
      );
      final button = tester.widget<XActionButton>(
        find.byKey(const Key('translate_favorite_button')),
      );
      expect(button.active, isTrue);
      expect(button.activeColor, AppPalette.of(context).like);
      expect(find.byIcon(Icons.favorite), findsOneWidget);
    });

    testWidgets('copy shows a check mark briefly', (tester) async {
      FakeClipboard(tester);
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const OutputCard());
      XActionButton copy() => tester.widget<XActionButton>(
        find.byKey(const Key('translate_copy_button')),
      );
      expect(copy().active, isFalse);
      expect(copy().icon, Icons.copy_outlined);

      await tester.tap(find.byTooltip('Copy'));
      await tester.pump();
      expect(copy().active, isTrue);
      expect(copy().icon, Icons.check);
      final context = tester.element(
        find.byKey(const Key('translate_copy_button')),
      );
      expect(copy().activeColor, AppPalette.of(context).success);

      await tester.pump(const Duration(seconds: 3));
      expect(copy().active, isFalse);
      expect(copy().icon, Icons.copy_outlined);
    });

    testWidgets('spreads the actions evenly', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const OutputCard());
      final row = tester.widget<Row>(
        find.byKey(const Key('translate_output_actions')),
      );
      expect(row.mainAxisAlignment, MainAxisAlignment.spaceBetween);
    });
  });

  group('TranslateHero', () {
    testWidgets('greets with a big bold headline', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const TranslateHero());
      final title = tester.widget<Text>(
        find.byKey(const Key('translate_greeting')),
      );
      expect(title.style?.fontWeight, FontWeight.w800);
      expect(title.style?.fontSize, greaterThanOrEqualTo(26));
    });
  });

  group('TranslateFlatCard', () {
    testWidgets('a section has a top hairline and no fill', (tester) async {
      await tester.pumpWidget(
        _app(const TranslateFlatCard(child: SizedBox(height: 20))),
      );
      final card = tester.widget<Card>(find.byType(Card));
      expect(card.color, Colors.transparent);
      expect(card.shape, isA<Border>());
      final border = card.shape! as Border;
      final context = tester.element(find.byType(Card));
      expect(border.top.color, AppPalette.of(context).hairline);
      expect(border.bottom, BorderSide.none);
    });

    testWidgets('a quote is an outlined rounded box', (tester) async {
      await tester.pumpWidget(
        _app(
          const TranslateFlatCard(
            look: TranslateCardLook.quote,
            child: SizedBox(height: 20),
          ),
        ),
      );
      final card = tester.widget<Card>(find.byType(Card));
      final shape = card.shape! as RoundedRectangleBorder;
      expect(shape.borderRadius, TranslateLayout.cardBorderRadius);
      expect(card.clipBehavior, Clip.antiAlias);
    });

    testWidgets('plain has no line', (tester) async {
      await tester.pumpWidget(
        _app(
          const TranslateFlatCard(
            look: TranslateCardLook.plain,
            child: SizedBox(height: 20),
          ),
        ),
      );
      final card = tester.widget<Card>(find.byType(Card));
      expect(card.shape, const Border());
    });
  });

  group('TranslateThreadRow', () {
    testWidgets('draws an avatar and, on request, the connector', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const Column(
            children: [
              TranslateThreadRow(
                code: 'en',
                connector: true,
                child: SizedBox(height: 120),
              ),
              TranslateThreadRow(code: 'fr', child: SizedBox(height: 60)),
            ],
          ),
        ),
      );
      expect(find.byType(LanguageAvatar), findsNWidgets(2));
      final line = find.byKey(const Key('translate_thread_connector'));
      expect(line, findsOneWidget);
      final rect = tester.getRect(line);
      expect(rect.width, TranslateLayout.connectorWidth);
      final avatar = tester.getRect(find.byType(LanguageAvatar).first);
      expect(rect.top, greaterThan(avatar.bottom));
      expect(rect.center.dx, closeTo(avatar.center.dx, 0.01));
    });

    testWidgets('mirrors in right-to-left layouts', (tester) async {
      await tester.pumpWidget(
        _app(
          const Directionality(
            textDirection: TextDirection.rtl,
            child: TranslateThreadRow(
              code: 'ar',
              child: SizedBox(height: 60, width: double.infinity),
            ),
          ),
        ),
      );
      final avatar = tester.getRect(find.byType(LanguageAvatar));
      expect(avatar.right, 800);
    });
  });

  group('TranslatePills', () {
    testWidgets('outlines chips with a hairline, accent when selected', (
      tester,
    ) async {
      await tester.pumpWidget(_app(const TranslatePills(child: SizedBox())));
      final context = tester.element(find.byType(SizedBox).last);
      final chips = Theme.of(context).chipTheme;
      final side = chips.side! as WidgetStateBorderSide;
      final palette = AppPalette.of(context);
      final scheme = Theme.of(context).colorScheme;
      expect(side.resolve({})?.color, palette.hairline);
      expect(side.resolve({WidgetState.selected})?.color, scheme.primary);
      expect(chips.color?.resolve({}), Colors.transparent);
      expect(chips.shape, const StadiumBorder());
      expect(chips.labelStyle?.fontWeight, FontWeight.w700);
    });
  });

  group('TranslateLayout', () {
    testWidgets('motion is off with reduced motion', (tester) async {
      late Duration normal;
      late Duration reduced;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) {
              normal = TranslateLayout.motion(context);
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: Builder(
                  builder: (context) {
                    reduced = TranslateLayout.motion(context);
                    return const SizedBox();
                  },
                ),
              );
            },
          ),
        ),
      );
      expect(normal, greaterThan(Duration.zero));
      expect(reduced, Duration.zero);
    });

    testWidgets('uses a 20 px compose text for short texts', (tester) async {
      late TextStyle? short;
      late TextStyle? long;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) {
              short = TranslateLayout.textStyle(context, 10);
              long = TranslateLayout.outputTextStyle(
                context,
                TranslateLayout.longTextLength + 1,
              );
              return const SizedBox();
            },
          ),
        ),
      );
      expect(short?.fontSize, 20);
      expect(long?.fontSize, lessThan(20));
    });
  });

  group('TranslateView thread', () {
    testWidgets('joins input and translation on phones', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, size: const Size(400, 900));
      expect(find.byKey(const Key('translate_input_thread')), findsOneWidget);
      expect(find.byKey(const Key('translate_output_thread')), findsOneWidget);
      expect(
        find.byKey(const Key('translate_thread_connector')),
        findsOneWidget,
      );
    });

    testWidgets('has no reply before there is a translation', (tester) async {
      final harness = TranslateHarness(state: readyState());
      await harness.pump(tester, size: const Size(400, 900));
      expect(find.byKey(const Key('translate_output_thread')), findsNothing);
      expect(find.byKey(const Key('translate_thread_connector')), findsNothing);
      // The greeting shows instead.
      expect(find.byKey(const Key('translate_greeting')), findsOneWidget);
    });

    testWidgets('detected source shows in the input avatar', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, size: const Size(400, 900));
      final avatar = tester.widget<LanguageAvatar>(
        find.descendant(
          of: find.byKey(const Key('translate_input_thread')),
          matching: find.byType(LanguageAvatar),
        ),
      );
      expect(avatar.code, 'en');
    });

    testWidgets('separates the wide columns with a vertical hairline', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, size: const Size(1200, 900));
      expect(find.byKey(const Key('translate_wide_layout')), findsOneWidget);
      final vertical = tester
          .widgetList<Hairline>(find.byType(Hairline))
          .where((line) => line.vertical);
      expect(vertical, hasLength(1));
      // Columns have avatars but no connector between them.
      expect(find.byKey(const Key('translate_thread_connector')), findsNothing);
    });
  });

  group('helpers', () {
    test('sourceAvatarCode prefers the chosen, then the detected language', () {
      expect(sourceAvatarCode(readyState(source: english)), 'en');
      expect(sourceAvatarCode(readyState()), 'auto');
      expect(sourceAvatarCode(translatedState()), 'en');
      expect(
        sourceAvatarCode(
          readyState(source: const Language.custom('Old English')),
        ),
        'Old English',
      );
    });

    test('targetAvatarCode uses a custom target text', () {
      expect(targetAvatarCode(readyState()), 'fr');
      expect(
        targetAvatarCode(
          readyState(target: const Language.custom('Pirate speak')),
        ),
        'Pirate speak',
      );
    });

    test('outputJoinsThread needs a translation or one in progress', () {
      expect(outputJoinsThread(readyState()), isFalse);
      expect(outputJoinsThread(translatedState()), isTrue);
      expect(
        outputJoinsThread(
          readyState(input: 'Hi', status: TranslateStatus.translating),
        ),
        isTrue,
      );
    });
  });
}
