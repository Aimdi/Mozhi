import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/app_bar_title.dart';
import 'package:mozhi/l10n/l10n.dart';

import '../../helpers/terminal_font.dart';

void main() {
  setUpAll(loadTerminalFont);

  group('AppBarTitle', () {
    Future<void> pumpTitle(
      WidgetTester tester,
      String title, {
      double width = 390,
      AppLook look = AppLook.classic,
      int actions = 0,
    }) async {
      tester.view
        ..physicalSize = Size(width, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            appColorScheme(
              brightness: Brightness.light,
              seedColor: kDefaultAccent,
            ),
            look: look,
          ),
          locale: const Locale('de'),
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            appBar: AppBar(
              leading: const BackButton(),
              title: AppBarTitle(title),
              actions: [
                for (var i = 0; i < actions; i++)
                  IconButton(
                    tooltip: '$i',
                    icon: const Icon(Icons.copy),
                    onPressed: () {},
                  ),
              ],
            ),
          ),
        ),
      );
    }

    RenderParagraph paragraph(WidgetTester tester, String title) =>
        tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.byType(AppBarTitle),
            matching: find.text(title),
          ),
        );

    testWidgets('shows a short title as it is', (tester) async {
      await pumpTitle(tester, 'Info');
      expect(find.byType(FittedBox), findsNothing);
      final text = tester.widget<Text>(find.text('Info'));
      expect(text.maxLines, 1);
      expect(paragraph(tester, 'Info').didExceedMaxLines, isFalse);
    });

    for (final look in [AppLook.classic, AppLook.terminal]) {
      for (final (title, actions) in [
        ('Backup & Synchronisierung', 0),
        ('Vorlesen & Spracheingabe', 0),
        ('Netzwerkaktivität', 2),
      ]) {
        testWidgets('never cuts "$title" at 390 dp (${look.style.name})', (
          tester,
        ) async {
          await pumpTitle(tester, title, look: look, actions: actions);
          expect(tester.takeException(), isNull);
          final shown = paragraph(tester, title);
          expect(shown.didExceedMaxLines, isFalse);
          // Inside the app bar.
          final rect = tester.getRect(find.text(title));
          final bar = tester.getRect(find.byType(AppBar));
          expect(rect.top, greaterThanOrEqualTo(bar.top));
          expect(rect.bottom, lessThanOrEqualTo(bar.bottom));
        });
      }
    }

    testWidgets('scales a slightly long title down on one line', (
      tester,
    ) async {
      // The test font: 24 dp per letter in the classic title style; the
      // title has 390 - 56 (back) - 16 (spacing) - 16 = 302 dp.
      await pumpTitle(tester, 'A' * 13);
      expect(find.byType(FittedBox), findsOneWidget);
      expect(tester.widget<Text>(find.text('A' * 13)).maxLines, 1);
    });

    testWidgets('wraps a long title on two smaller lines', (tester) async {
      const title = 'Backup und Synchronisierung';
      await pumpTitle(tester, title);
      expect(find.byType(FittedBox), findsNothing);
      final text = tester.widget<Text>(find.text(title));
      expect(text.maxLines, 2);
      expect(text.style?.fontSize, lessThan(24));
      expect(paragraph(tester, title).didExceedMaxLines, isFalse);
    });
  });
}
