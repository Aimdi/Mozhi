import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/platform/app_shell.dart';
import 'package:mozhi/platform/app_shell_scope.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';

import '../helpers/helpers.dart';
import 'fake_app_shell_bridge.dart';

class _MockSettingsCubit extends MockCubit<AppSettings>
    implements SettingsCubit;

void main() {
  late FakeAppShellBridge bridge;
  late AppShell shell;
  late _MockSettingsCubit settings;
  late StreamController<AppSettings> changes;

  // Made in each test (the fake async zone of testWidgets): the shell's
  // futures must run there.
  void setUpShell() {
    bridge = FakeAppShellBridge()..next = const AppShellWorkers(active: true);
    shell = AppShell(bridge: bridge);
    settings = _MockSettingsCubit();
    changes = StreamController<AppSettings>();
    whenListen(settings, changes.stream, initialState: const AppSettings());
    addTearDown(() async {
      // Not awaited: the cubit's stream keeps a subscription to it.
      unawaited(changes.close());
      await shell.dispose();
    });
  }

  Future<void> pump(WidgetTester tester, {AppShell? using}) => tester.pumpApp(
    BlocProvider<SettingsCubit>.value(
      value: settings,
      child: Scaffold(
        body: AppShellScope(
          shell: using ?? shell,
          child: Builder(
            builder: (context) => Text(
              identical(appShellOf(context), using ?? shell)
                  ? 'provided'
                  : 'other',
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('follows the setting and provides the shell', (tester) async {
    setUpShell();
    await pump(tester);
    await tester.pump();
    expect(bridge.registered, 1);
    expect(shell.current, AppShellStatus.ready);
    expect(find.text('provided'), findsOneWidget);

    changes.add(const AppSettings(offlineAppShell: false));
    await tester.pump();
    await tester.pump();
    expect(bridge.unregistered, 1);
    expect(shell.current, AppShellStatus.unsupported);
  });

  testWidgets('says once that an update is ready, with Reload', (tester) async {
    setUpShell();
    await pump(tester);
    await tester.pump();
    bridge.change(const AppShellWorkers(active: true, waiting: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Update ready'), findsOneWidget);

    await tester.tap(find.text('Reload'));
    await tester.pump();
    expect(bridge.activations, 1);

    // Not again in this session.
    bridge.change(const AppShellWorkers(active: true));
    await tester.pump();
    bridge.change(const AppShellWorkers(active: true, waiting: true));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Update ready'), findsNothing);
  });

  testWidgets('the notice goes away by itself', (tester) async {
    setUpShell();
    bridge.next = const AppShellWorkers(active: true, waiting: true);
    await pump(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Update ready'), findsOneWidget);
    await tester.pump(AppShellScope.noticeDuration);
    await tester.pumpAndSettle();
    expect(find.text('Update ready'), findsNothing);
  });

  testWidgets('without a scope, the app-wide shell', (tester) async {
    setUpShell();
    await tester.pumpApp(
      Builder(
        builder: (context) => Text(
          identical(appShellOf(context), AppShell.instance)
              ? 'instance'
              : 'other',
        ),
      ),
    );
    expect(find.text('instance'), findsOneWidget);
  });
}
