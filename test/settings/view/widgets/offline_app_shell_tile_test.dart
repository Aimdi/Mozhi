import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/platform/app_shell.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/offline_app_shell_tile.dart';

import '../../../helpers/helpers.dart';
import '../../../platform/fake_app_shell_bridge.dart';

class _MockSettingsCubit extends MockCubit<AppSettings>
    implements SettingsCubit;

void main() {
  late FakeAppShellBridge bridge;
  late AppShell shell;
  late _MockSettingsCubit settings;

  // Made in each test (the fake async zone of testWidgets): the shell's
  // futures must run there.
  void setUpShell() {
    bridge = FakeAppShellBridge();
    shell = AppShell(bridge: bridge);
    addTearDown(shell.dispose);
    settings = _MockSettingsCubit();
    when(() => settings.state).thenReturn(const AppSettings());
  }

  Future<void> pump(WidgetTester tester, {bool enabled = true}) =>
      tester.pumpApp(
        BlocProvider<SettingsCubit>.value(
          value: settings,
          child: Scaffold(
            body: OfflineAppShellTile(enabled: enabled, shell: shell),
          ),
        ),
      );

  String status(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const Key('settings_offline_app_shell_status')))
      .data!;

  testWidgets('says where the app is as it changes', (tester) async {
    setUpShell();
    bridge.next = const AppShellWorkers(installing: true);
    await shell.setEnabled(enabled: true);
    await pump(tester);
    expect(find.text('Keep the web app for offline use'), findsOneWidget);
    expect(status(tester), 'Saving the app in this browser…');

    bridge.change(const AppShellWorkers(active: true));
    await tester.pumpAndSettle();
    expect(
      status(tester),
      'Opens in this browser without a network, with the offline languages '
      'you downloaded',
    );
    expect(
      find.byKey(const Key('settings_offline_app_shell_reload')),
      findsNothing,
    );
    // Screen readers hear the changes.
    final live = tester.widget<Semantics>(
      find
          .ancestor(
            of: find.byKey(const Key('settings_offline_app_shell_status')),
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(live.properties.liveRegion, isTrue);
  });

  testWidgets('offers Reload once an update is ready', (tester) async {
    setUpShell();
    bridge.next = const AppShellWorkers(active: true, waiting: true);
    await shell.setEnabled(enabled: true);
    await pump(tester);
    expect(status(tester), 'A new version is ready. Reload to use it.');

    await tester.tap(
      find.byKey(const Key('settings_offline_app_shell_reload')),
    );
    await tester.pump();
    expect(bridge.activations, 1);
  });

  testWidgets('says when the browser cannot keep the app', (tester) async {
    setUpShell();
    bridge.next = null;
    await shell.setEnabled(enabled: true);
    await pump(tester);
    expect(
      status(tester),
      'This browser can’t keep the app: it needs an https site and a browser '
      'that allows it',
    );
  });

  testWidgets('off: the app needs a network; the switch turns it on', (
    tester,
  ) async {
    setUpShell();
    bridge.next = const AppShellWorkers(active: true, waiting: true);
    await shell.setEnabled(enabled: true);
    await pump(tester, enabled: false);
    expect(status(tester), 'The app needs a network to open');
    expect(
      find.byKey(const Key('settings_offline_app_shell_reload')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('settings_offline_app_shell')));
    verify(() => settings.setOfflineAppShell(enabled: true)).called(1);
  });
}
