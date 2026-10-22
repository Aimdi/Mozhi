import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/view/about_page.dart';
import 'package:mozhi/settings/view/settings_page.dart';
import 'package:mozhi/settings/view/widgets/settings_search.dart';

import 'helpers.dart';

void main() {
  setUpAll(registerFallbacks);

  group('settings routes', () {
    test('every category has a location below /settings', () {
      final router = createAppRouter(quickTranslateWindow: false);
      addTearDown(router.dispose);
      for (final category in SettingsCategory.values) {
        final match = router.configuration.findMatch(
          Uri.parse(category.location(row: 'x')),
        );
        expect(match.isError, isFalse, reason: category.name);
        expect(match.fullPath, '/settings/${category.path}');
      }
      expect(SettingsCategory.about.location(), AppRoutes.about);
      expect(SettingsCategory.tryParse('privacy'), SettingsCategory.privacy);
      expect(SettingsCategory.tryParse('nope'), isNull);
    });

    Future<GoRouter> open(WidgetTester tester, String location) async {
      tester.setScreenSize(const Size(412, 900));
      final router = createAppRouter(
        initialLocation: location,
        quickTranslateWindow: false,
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<SettingsCubit>.value(value: createSettingsCubit()),
            BlocProvider<HistoryCubit>.value(value: createHistoryCubit()),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return router;
    }

    testWidgets('a category link opens its page at the row, above the '
        'settings', (tester) async {
      final router = await open(tester, '/settings/privacy?row=incognito');
      final page = tester.widget<SettingsCategoryPage>(
        find.byType(SettingsCategoryPage),
      );
      expect(page.category, SettingsCategory.privacy);
      expect(page.highlight, 'incognito');
      expect(find.byKey(SettingsAnchor.highlightKey('incognito')), findsOne);
      await tester.pump(SettingsAnchor.highlightDuration);
      await tester.pumpAndSettle();

      router.pop();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsCategoryPage), findsNothing);
      expect(find.byType(SettingsPage), findsOneWidget);
    });

    testWidgets('the About page takes a row too', (tester) async {
      await open(tester, '/settings/about?row=licenses');
      final page = tester.widget<AboutPage>(find.byType(AboutPage));
      expect(page.highlight, 'licenses');
      await tester.pump(SettingsAnchor.highlightDuration);
      await tester.pumpAndSettle();
    });
  });
}
