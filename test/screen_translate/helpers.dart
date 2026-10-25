import 'dart:async';

import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app_lock/data/app_lock.dart';
import 'package:mozhi/screen_translate/data/screen_translate_controls.dart';
import 'package:mozhi/screen_translate/screen_translate_host.dart';

class MockScreenTranslateHost extends Mock implements ScreenTranslateHost;

class MockScreenTranslateControls extends Mock
    implements ScreenTranslateControls;

/// A [MockScreenTranslateHost] whose window actions succeed.
MockScreenTranslateHost mockScreenTranslateHost() {
  final host = MockScreenTranslateHost();
  when(host.close).thenAnswer((_) async {});
  when(() => host.openTextInApp(any())).thenAnswer((_) async {});
  when(() => host.openLocationInApp(any())).thenAnswer((_) async {});
  return host;
}

/// An app lock whose prompt answers [unlockResult] (and unlocks with it).
class FakeAppLock implements AppLock {
  new({this.locked = false});

  bool locked;
  bool unlockResult = true;
  Exception? unlockError;
  int prompts = 0;

  /// When set, the prompt waits for it.
  Completer<void>? gate;
  final _changes = StreamController<bool>.broadcast();

  void setLocked({required bool locked}) {
    this.locked = locked;
    _changes.add(locked);
  }

  @override
  bool get isLocked => locked;

  @override
  Stream<bool> get changes => _changes.stream;

  @override
  Future<bool> unlock() async {
    prompts++;
    await gate?.future;
    final error = unlockError;
    if (error != null) throw error;
    if (unlockResult) setLocked(locked: false);
    return unlockResult;
  }

  @override
  void noteBackground() {}

  @override
  void noteForeground() {}
}
