import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';

Widget _app(Locale locale, List<LocalizationsDelegate<dynamic>> delegates) {
  return MaterialApp(
    locale: locale,
    localizationsDelegates: delegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => Scaffold(
        appBar: AppBar(title: Text(context.l10n.appTitle)),
        body: const TextField(),
        bottomNavigationBar: NavigationBar(
          destinations: [
            NavigationDestination(
              icon: const Icon(Icons.translate),
              label: context.l10n.navTranslate,
            ),
            NavigationDestination(
              icon: const Icon(Icons.history),
              label: context.l10n.navHistory,
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  group('appLocalizationsDelegates', () {
    for (final code in ['ar', 'ta', 'zh', 'de', 'en']) {
      testWidgets('renders material widgets in $code', (tester) async {
        await tester.pumpWidget(_app(Locale(code), appLocalizationsDelegates));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(NavigationBar), findsOneWidget);
        expect(
          MaterialLocalizations.of(tester.element(find.byType(NavigationBar))),
          isNotNull,
        );
      });
    }

    testWidgets('uses right-to-left layout for Arabic', (tester) async {
      await tester.pumpWidget(
        _app(const Locale('ar'), appLocalizationsDelegates),
      );
      await tester.pumpAndSettle();
      final direction = Directionality.of(
        tester.element(find.byType(NavigationBar)),
      );
      expect(direction, TextDirection.rtl);
    });
  });
}
