import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/app_lock/data/app_lock.dart';
import 'package:mozhi/app_lock/data/app_lock_link_hold.dart';

class _FakeLock implements AppLock {
  final controller = StreamController<bool>.broadcast();

  @override
  bool isLocked = false;

  void set({required bool locked}) {
    isLocked = locked;
    controller.add(locked);
  }

  @override
  Stream<bool> get changes => controller.stream;

  @override
  Future<bool> unlock() async => true;

  @override
  void noteBackground() {}

  @override
  void noteForeground() {}
}

/// Answers every pushed route, to see whether the hold let it through.
class _Router with WidgetsBindingObserver {
  final pushed = <String>[];

  @override
  Future<bool> didPushRouteInformation(RouteInformation info) async {
    pushed.add(info.uri.toString());
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeLock lock;
  late List<RouteInformation> opened;
  late AppLockLinkHold hold;
  late _Router router;

  setUp(() {
    lock = _FakeLock();
    opened = [];
    hold = AppLockLinkHold(lock: lock, open: opened.add)..attach();
    // Registered after the hold, like the router's provider.
    router = _Router();
    WidgetsBinding.instance.addObserver(router);
  });

  tearDown(() async {
    WidgetsBinding.instance.removeObserver(router);
    await hold.dispose();
    await lock.controller.close();
  });

  test('lets links through while unlocked', () async {
    await WidgetsBinding.instance.handlePushRoute('/history');

    expect(router.pushed, ['/history']);
    expect(hold.held, isNull);
    expect(opened, isEmpty);
  });

  test(
    'holds links while locked and opens the last one once unlocked',
    () async {
      lock.set(locked: true);
      await WidgetsBinding.instance.handlePushRoute('/translate?text=hola');
      await WidgetsBinding.instance.handlePushRoute('/image?source=camera');

      expect(router.pushed, isEmpty, reason: 'nothing reaches the router');
      expect(hold.held?.uri.toString(), '/image?source=camera');

      lock.set(locked: false);
      await pumpEventQueue();

      expect(opened.map((info) => info.uri.toString()), [
        '/image?source=camera',
      ]);
      expect(hold.held, isNull);

      // Unlocking again opens nothing more.
      lock
        ..set(locked: true)
        ..set(locked: false);
      await pumpEventQueue();
      expect(opened, hasLength(1));
    },
  );

  test('opens nothing when nothing was held', () async {
    lock
      ..set(locked: true)
      ..set(locked: false);
    await pumpEventQueue();

    expect(opened, isEmpty);
  });

  test('drops what it held when disposed', () async {
    lock.set(locked: true);
    await WidgetsBinding.instance.handlePushRoute('/history');

    await hold.dispose();
    lock.set(locked: false);
    await pumpEventQueue();
    expect(opened, isEmpty);
    expect(hold.held, isNull);

    // No longer in the way.
    lock.set(locked: true);
    await WidgetsBinding.instance.handlePushRoute('/proofread');
    expect(router.pushed, ['/proofread']);
  });
}
