import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/platform/web_share.dart';
import 'package:mozhi/translate/widgets/output_card.dart';
import 'package:mozhi/translate/widgets/terminal_chrome.dart';

import '../../helpers/terminal_font.dart';
import '../helpers/helpers.dart';

void main() {
  setUpAll(() async {
    registerTranslateFallbacks();
    await loadTerminalFont();
  });

  tearDown(() => debugCanShareText = null);

  group('actionsLayout', () {
    test('keeps the spacing when everything fits', () {
      final layout = actionsLayout(
        maxWidth: 400,
        count: 5,
        overflowable: 2,
        spacing: 8,
      );
      expect(layout.menu, isFalse);
      expect(layout.spacing, 8);
    });

    test('keeps the spacing in an unbounded width', () {
      final layout = actionsLayout(
        maxWidth: double.infinity,
        count: 5,
        overflowable: 2,
        spacing: 8,
      );
      expect(layout, (spacing: 8.0, menu: false));
    });

    test('shrinks the spacing before using the menu', () {
      // 5 × 48 = 240, with 4 gaps of 5 dp.
      final layout = actionsLayout(
        maxWidth: 260,
        count: 5,
        overflowable: 2,
        spacing: 8,
      );
      expect(layout.menu, isFalse);
      expect(layout.spacing, closeTo(5, 1e-9));
    });

    test('moves the overflowable actions into the menu', () {
      // 6 × 48 = 288 does not fit 250; 5 (4 + the menu) do.
      final layout = actionsLayout(
        maxWidth: 250,
        count: 6,
        overflowable: 2,
        spacing: 8,
      );
      expect(layout.menu, isTrue);
      expect(layout.spacing, closeTo(2.5, 1e-9));
    });

    test('never makes a menu for a single action', () {
      final layout = actionsLayout(
        maxWidth: 100,
        count: 5,
        overflowable: 1,
        spacing: 8,
      );
      expect(layout.menu, isFalse);
      expect(layout.spacing, 0);
    });

    test('one action keeps the spacing', () {
      expect(
        actionsLayout(maxWidth: 40, count: 1, overflowable: 0, spacing: 8),
        (spacing: 8.0, menu: false),
      );
    });
  });

  group('OutputCard actions', () {
    Future<TranslateHarness> pumpCard(
      WidgetTester tester, {
      required double width,
      ThemeData? theme,
    }) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(
        tester,
        size: const Size(800, 900),
        theme: theme,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, child: const OutputCard()),
        ),
      );
      await tester.pump();
      return harness;
    }

    Finder actions(Finder finder) => find.descendant(
      of: find.byKey(const Key('translate_output_actions')),
      matching: finder,
    );

    testWidgets('all on one line where they fit', (tester) async {
      debugCanShareText = true;
      await pumpCard(tester, width: 600);

      expect(
        actions(find.byKey(const Key('translate_share_button'))),
        findsOne,
      );
      expect(actions(find.byKey(const Key('translate_show_button'))), findsOne);
      expect(
        find.byKey(const Key('translate_more_actions_button')),
        findsNothing,
      );
    });

    testWidgets('share and full screen go into More options on a narrow '
        'card, never alone on a second line', (tester) async {
      debugCanShareText = true;
      await pumpCard(tester, width: 230);

      final more = find.byKey(const Key('translate_more_actions_button'));
      expect(more, findsOneWidget);
      expect(find.byKey(const Key('translate_share_button')), findsNothing);
      expect(find.byKey(const Key('translate_show_button')), findsNothing);
      // One line: every action at the same height.
      final row = tester.getTopLeft(
        find.byKey(const Key('translate_copy_button')),
      );
      expect(tester.getTopLeft(more).dy, row.dy);

      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('translate_share_button')), findsOneWidget);
      expect(find.byKey(const Key('translate_show_button')), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
      expect(find.text('Show full screen'), findsOneWidget);

      // A full-screen view from the menu.
      await tester.tap(find.byKey(const Key('translate_show_button')));
      await tester.pumpAndSettle();
      expect(find.text('Bonjour le monde'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no Share where the platform cannot share text', (
      tester,
    ) async {
      debugCanShareText = false;
      await pumpCard(tester, width: 600);

      expect(find.byKey(const Key('translate_share_button')), findsNothing);
      expect(find.byKey(const Key('translate_show_button')), findsOneWidget);
    });

    testWidgets('Copy and Listen are 48 dp like the others with a mouse', (
      tester,
    ) async {
      debugCanShareText = true;
      await pumpCard(
        tester,
        width: 600,
        theme: ThemeData(
          useMaterial3: true,
          platform: TargetPlatform.linux,
          visualDensity: VisualDensity.compact,
        ),
      );

      final copy = tester.getSize(
        find.byKey(const Key('translate_copy_button')),
      );
      final favorite = tester.getSize(
        find.byKey(const Key('translate_favorite_button')),
      );
      final listen = tester.getSize(actions(find.byType(IconButton)).at(1));
      expect(copy, const Size.square(48));
      expect(listen, const Size.square(48));
      expect(favorite.height, 48);
    });

    testWidgets('the terminal frames are one size with a mouse', (
      tester,
    ) async {
      debugCanShareText = true;
      await pumpCard(
        tester,
        width: 600,
        theme: terminalTestTheme().copyWith(
          platform: TargetPlatform.linux,
          visualDensity: VisualDensity.compact,
        ),
      );

      final frames = actions(find.byType(TerminalFrame));
      expect(frames, findsAtLeast(5));
      for (final frame in tester.widgetList(frames)) {
        expect(tester.getSize(find.byWidget(frame)), const Size.square(48));
      }
    });
  });

  group('OutputCard header', () {
    testWidgets('keeps the separator with the engine when it wraps', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(
        tester,
        size: const Size(800, 900),
        child: const Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 150, child: OutputCard()),
        ),
      );
      await tester.pump();

      final engine = find.byKey(const Key('translate_output_engine'));
      expect(
        find.descendant(of: engine, matching: find.text(' · ')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: engine,
          matching: find.byKey(const Key('translate_output_footer')),
        ),
        findsOneWidget,
      );
      // Wrapped under the language, the separator starts the line.
      final language = tester.getRect(
        find.byKey(const Key('translate_output_language')),
      );
      final separator = tester.getRect(find.text(' · '));
      expect(separator.top, greaterThanOrEqualTo(language.bottom - 1));
      expect(tester.takeException(), isNull);
    });
  });
}
