import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/platform/app_shell.dart';
import 'package:mozhi/platform/app_shell_stub.dart';

import 'fake_app_shell_bridge.dart';

void main() {
  late FakeAppShellBridge bridge;
  late AppShell shell;
  late List<AppShellStatus> statuses;
  late StreamSubscription<AppShellStatus> subscription;

  setUp(() {
    bridge = FakeAppShellBridge();
    shell = AppShell(
      bridge: bridge,
      reloadTimeout: const Duration(milliseconds: 50),
    );
    statuses = [];
    subscription = shell.status.listen(statuses.add);
  });

  tearDown(() async {
    await subscription.cancel();
    await shell.dispose();
  });

  Future<void> settle() => pumpEventQueue();

  group('AppShellWorkers.status', () {
    test('maps the workers to a status', () {
      expect(const AppShellWorkers().status, AppShellStatus.unsupported);
      expect(
        const AppShellWorkers(installing: true).status,
        AppShellStatus.installing,
      );
      expect(
        const AppShellWorkers(waiting: true).status,
        AppShellStatus.installing,
      );
      expect(const AppShellWorkers(active: true).status, AppShellStatus.ready);
      // An update downloading in the background: still ready.
      expect(
        const AppShellWorkers(active: true, installing: true).status,
        AppShellStatus.ready,
      );
      expect(
        const AppShellWorkers(active: true, waiting: true).status,
        AppShellStatus.updateReady,
      );
      expect(
        const AppShellWorkers(active: true),
        isNot(const AppShellWorkers(active: true, controlled: true)),
      );
    });
  });

  group('AppShell', () {
    test('starts unsupported and says so first', () async {
      await settle();
      expect(shell.current, AppShellStatus.unsupported);
      expect(statuses, [AppShellStatus.unsupported]);
      expect(shell.isSupported, isTrue);
    });

    test('registers, installs and is ready', () async {
      bridge.next = const AppShellWorkers(installing: true);
      await shell.setEnabled(enabled: true);
      expect(bridge.registered, 1);
      expect(shell.current, AppShellStatus.installing);

      bridge.change(const AppShellWorkers(active: true));
      await settle();
      expect(shell.current, AppShellStatus.ready);
      // The fonts the page loaded before the worker was there.
      expect(bridge.keptLoaded, 1);
      expect(statuses, [
        AppShellStatus.unsupported,
        AppShellStatus.installing,
        AppShellStatus.ready,
      ]);
    });

    test('an update in the background, then ready to reload', () async {
      bridge.next = const AppShellWorkers(active: true, controlled: true);
      await shell.setEnabled(enabled: true);
      expect(shell.current, AppShellStatus.ready);

      bridge.change(
        const AppShellWorkers(active: true, installing: true, controlled: true),
      );
      await settle();
      expect(shell.current, AppShellStatus.ready);
      bridge.change(
        const AppShellWorkers(active: true, waiting: true, controlled: true),
      );
      await settle();
      expect(shell.current, AppShellStatus.updateReady);
      expect(bridge.keptLoaded, 1);
    });

    test('applyUpdate activates the waiting worker, then reloads', () async {
      bridge.next = const AppShellWorkers(active: true, waiting: true);
      await shell.setEnabled(enabled: true);
      expect(shell.current, AppShellStatus.updateReady);

      await shell.applyUpdate();
      expect(bridge.activations, 1);
      expect(bridge.reloads, 0);
      bridge.emit(AppShellEvent.controllerChanged);
      await settle();
      expect(bridge.reloads, 1);
      // The timeout does not reload a second time.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(bridge.reloads, 1);
    });

    test(
      'applyUpdate reloads anyway when the update never takes over',
      () async {
        bridge.next = const AppShellWorkers(active: true, waiting: true);
        await shell.setEnabled(enabled: true);
        await shell.applyUpdate();
        expect(bridge.reloads, 0);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(bridge.reloads, 1);
      },
    );

    test('applyUpdate without a waiting worker just reloads', () async {
      bridge
        ..next = const AppShellWorkers(active: true)
        ..hasWaiting = false;
      await shell.setEnabled(enabled: true);
      await shell.applyUpdate();
      expect(bridge.activations, 1);
      expect(bridge.reloads, 1);

      bridge.failActivation = true;
      await shell.applyUpdate();
      expect(bridge.reloads, 2);
    });

    test('a page of the old version reloads when another took over', () async {
      bridge.next = const AppShellWorkers(active: true, controlled: true);
      await shell.setEnabled(enabled: true);
      bridge.emit(AppShellEvent.controllerChanged);
      await settle();
      expect(bridge.reloads, 1);
    });

    test('a page loaded before the worker was there does not reload', () async {
      bridge.next = const AppShellWorkers(active: true);
      await shell.setEnabled(enabled: true);
      bridge.emit(AppShellEvent.controllerChanged);
      await settle();
      expect(bridge.reloads, 0);
    });

    test('off unregisters and deletes the caches', () async {
      bridge.next = const AppShellWorkers(active: true);
      await shell.setEnabled(enabled: true);
      await shell.setEnabled(enabled: false);
      expect(bridge.unregistered, 1);
      expect(shell.current, AppShellStatus.unsupported);
      // Later changes of the old registration are ignored.
      bridge.change(const AppShellWorkers(active: true, waiting: true));
      await settle();
      expect(shell.current, AppShellStatus.unsupported);

      // On again: registered again, the loaded files kept again.
      bridge.next = const AppShellWorkers(active: true);
      await shell.setEnabled(enabled: true);
      expect(bridge.registered, 2);
      expect(shell.current, AppShellStatus.ready);
      expect(bridge.keptLoaded, 2);
    });

    test('off at the start cleans up what an earlier session kept', () async {
      await shell.setEnabled(enabled: false);
      expect(bridge.unregistered, 1);
      expect(bridge.registered, 0);
    });

    test('a repeated value does nothing; calls run in order', () async {
      bridge.next = const AppShellWorkers(active: true);
      unawaited(shell.setEnabled(enabled: true));
      unawaited(shell.setEnabled(enabled: true));
      unawaited(shell.setEnabled(enabled: false));
      await shell.setEnabled(enabled: true);
      expect(bridge.registered, 2);
      expect(bridge.unregistered, 1);
      expect(shell.current, AppShellStatus.ready);
    });

    test('a browser that refuses stays unsupported', () async {
      bridge.next = null;
      await shell.setEnabled(enabled: true);
      expect(shell.current, AppShellStatus.unsupported);

      bridge.failRegister = true;
      await shell.setEnabled(enabled: false);
      await shell.setEnabled(enabled: true);
      expect(shell.current, AppShellStatus.unsupported);
    });

    test('a failed install is unsupported', () async {
      bridge.next = const AppShellWorkers(installing: true);
      await shell.setEnabled(enabled: true);
      bridge.change(const AppShellWorkers());
      await settle();
      expect(shell.current, AppShellStatus.unsupported);
      // A refreshing error leaves the status as it is.
      bridge
        ..failWorkers = true
        ..emit(AppShellEvent.changed);
      await settle();
      expect(shell.current, AppShellStatus.unsupported);
    });

    test('does nothing where it is not supported', () async {
      final unsupported = AppShell(bridge: const UnsupportedAppShellBridge());
      addTearDown(unsupported.dispose);
      await unsupported.setEnabled(enabled: true);
      await unsupported.applyUpdate();
      expect(unsupported.isSupported, isFalse);
      expect(unsupported.current, AppShellStatus.unsupported);
      expect(await unsupported.status.first, AppShellStatus.unsupported);
    });
  });

  group('UnsupportedAppShellBridge', () {
    test('does nothing', () async {
      const stub = UnsupportedAppShellBridge();
      expect(stub.isSupported, isFalse);
      expect(await stub.register(), isNull);
      expect(await stub.workers(), isNull);
      expect(await stub.activateWaiting(), isFalse);
      await stub.keepLoaded();
      await stub.unregister();
      stub.reload();
      expect(await stub.events.isEmpty, isTrue);
      expect(createAppShellBridge(), isA<UnsupportedAppShellBridge>());
      expect(AppShell.instance.isSupported, isFalse);
    });
  });
}
