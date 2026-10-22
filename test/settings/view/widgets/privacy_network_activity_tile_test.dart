import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/router.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/privacy_settings_section.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

void main() {
  setUpAll(() {
    registerFallbacks();
    registerFallbackValue(PrivacyMode.online);
  });

  testWidgets('"Network activity" opens the network activity page', (
    tester,
  ) async {
    final router = createRouter();
    when(() => router.push<void>(any())).thenAnswer((_) async {});
    const state = AppSettings();
    tester.setScreenSize(const Size(800, 3000));
    await tester.pumpView(
      Scaffold(
        body: ListView(
          children: const [PrivacySettingsSection(settings: state)],
        ),
      ),
      settings: createSettingsCubit(),
      router: router,
    );

    final tile = find.byKey(const Key('settings_network_activity'));
    expect(tile, findsOneWidget);
    expect(find.text('Network activity'), findsOneWidget);
    expect(
      find.text('What left this device this session, and where it went'),
      findsOneWidget,
    );

    await tester.tap(tile);
    await tester.pump();

    verify(() => router.push<void>(AppRoutes.networkActivity)).called(1);
  });
}
