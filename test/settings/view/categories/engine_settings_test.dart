import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/categories/engine_settings.dart';

import '../helpers.dart';

void main() {
  setUpAll(registerFallbacks);

  late MockSettingsCubit settings;

  setUp(() {
    settings = createSettingsCubit();
    when(() => settings.setFallbackToDuckDuckGo(enabled: any(named: 'enabled')))
        .thenReturn(null);
  });

  Future<void> pump(WidgetTester tester, AppSettings state) async {
    when(() => settings.state).thenReturn(state);
    await tester.pumpView(
      Scaffold(
        body: SingleChildScrollView(child: EngineSettings(settings: state)),
      ),
      settings: settings,
      router: createRouter(),
    );
    await tester.pump();
  }

  SwitchListTile tile(WidgetTester tester) => tester.widget<SwitchListTile>(
    find.byKey(const Key('settings_duckduckgo_fallback')),
  );

  group('If Google fails, use DuckDuckGo', () {
    testWidgets('is off by default and says where the text goes', (
      tester,
    ) async {
      await pump(tester, const AppSettings());
      expect(find.text('If Google fails, use DuckDuckGo'), findsOneWidget);
      expect(
        find.text(
          'When Google fails on every volunteer server, your text is sent to '
          "DuckDuckGo's translator through the same servers instead. "
          "DuckDuckGo's translations come from Microsoft Translator.",
        ),
        findsOneWidget,
      );
      expect(tile(tester).value, isFalse);
    });

    testWidgets('sits with the Mozhi instances', (tester) async {
      await pump(tester, const AppSettings());
      final instances = tester.getTopLeft(
        find.byKey(const Key('settings_instances')),
      );
      final fallback = tester.getTopLeft(
        find.byKey(const Key('settings_duckduckgo_fallback')),
      );
      final services = tester.getTopLeft(
        find.byKey(const Key('settings_mt_services')),
      );
      expect(fallback.dy, greaterThan(instances.dy));
      expect(fallback.dy, lessThan(services.dy));
    });

    testWidgets('turns the fallback on', (tester) async {
      await pump(tester, const AppSettings());
      await tester.tap(find.byKey(const Key('settings_duckduckgo_fallback')));
      verify(() => settings.setFallbackToDuckDuckGo(enabled: true)).called(1);
    });

    testWidgets('turns it off again', (tester) async {
      await pump(tester, const AppSettings(fallbackToDuckDuckGo: true));
      expect(tile(tester).value, isTrue);
      await tester.tap(find.byKey(const Key('settings_duckduckgo_fallback')));
      verify(() => settings.setFallbackToDuckDuckGo(enabled: false)).called(1);
    });
  });
}
