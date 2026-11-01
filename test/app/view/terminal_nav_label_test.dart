import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/app/view/app_shell.dart';
import 'package:mozhi/l10n/l10n.dart';

import '../../helpers/terminal_font.dart';

void main() {
  setUpAll(loadTerminalFont);

  group('TerminalNavLabel.forms', () {
    test('goes from the numbered label to the number', () {
      expect(TerminalNavLabel.forms(1, 'Übersetzen'), [
        '1:übersetzen',
        'übersetzen',
        '1:übersetze.',
        '1:übersetz.',
        '1:überset.',
        '1:überse.',
        '1:übers.',
        '1:über.',
        '1:übe.',
        '1:üb.',
        '1',
      ]);
    });

    test('abbreviates by characters, not code units', () {
      expect(TerminalNavLabel.forms(2, '翻訳'), ['2:翻訳', '翻訳', '2']);
      final tamil = TerminalNavLabel.forms(3, 'அகராதி');
      // அ க ரா தி: four characters (grapheme clusters).
      expect(tamil, ['3:அகராதி', 'அகராதி', '3:அகரா.', '3:அக.', '3']);
    });
  });

  group('AppShell terminal labels', () {
    final theme = buildAppTheme(
      appColorScheme(
        brightness: Brightness.dark,
        seedColor: const Color(0xFFFFB000),
      ),
      look: AppLook.terminal,
    );

    Future<AppLocalizations> pumpShell(
      WidgetTester tester, {
      required double width,
      required Locale locale,
    }) async {
      tester.view
        ..physicalSize = Size(width, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          locale: locale,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AppShell(
            selectedIndex: 0,
            onDestinationSelected: (_) {},
            child: const SizedBox.expand(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return AppLocalizations.of(tester.element(find.byType(AppShell)));
    }

    /// The texts the bar shows, in order.
    List<String> shown(WidgetTester tester) => [
      for (final element
          in find
              .descendant(
                of: find.byType(TerminalNavLabel),
                matching: find.byType(Text),
              )
              .evaluate())
        (element.widget as Text).data!,
    ];

    for (final width in const [360.0, 390.0]) {
      for (final locale in AppLocalizations.supportedLocales) {
        testWidgets('are never cut at $width dp ($locale)', (tester) async {
          final l10n = await pumpShell(tester, width: width, locale: locale);
          expect(tester.takeException(), isNull);
          final labels = [
            l10n.navTranslate,
            l10n.navDictionary,
            l10n.navProofread,
            l10n.navConversation,
          ];
          final texts = shown(tester);
          expect(texts, hasLength(4));
          final slot = width / 4;
          for (final (index, text) in texts.indexed) {
            expect(
              TerminalNavLabel.forms(index + 1, labels[index]),
              contains(text),
            );
            final rect = tester.getRect(
              find.descendant(
                of: find.byType(TerminalNavLabel),
                matching: find.text(text),
              ),
            );
            expect(rect.width, lessThanOrEqualTo(slot));
          }
        });
      }
    }
  });
}
