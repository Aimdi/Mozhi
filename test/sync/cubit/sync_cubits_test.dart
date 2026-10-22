import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mozhi/sync/cubit/sync_cubit.dart';
import 'package:mozhi/sync/cubit/sync_setup_cubit.dart';
import 'package:mozhi/sync/data/sync_service.dart';
import 'package:mozhi/sync/models/sync_config.dart';
import 'package:mozhi/sync/models/sync_status.dart';
import 'package:translation_repository/translation_repository.dart'
    show PrivacyMode;

import '../helpers/sync_harness.dart';

void main() {
  group('SyncCubit', () {
    test('mirrors the service and returns the failures of actions', () async {
      final harness = SyncHarness();
      await harness.setUp();
      final cubit = SyncCubit(harness.service);
      expect(cubit.state.isSetUp, isTrue);
      expect(cubit.sectionIds, ['history', 'presets', 'settings']);
      final states = <SyncState>[];
      final subscription = cubit.stream.listen(states.add);

      expect(await cubit.syncNow(), isNull);
      expect(
        await cubit.unlock(passphrase: 'wrong'),
        SyncFailure.wrongPassphrase,
      );
      expect(await cubit.unlock(password: 'app-password'), isNull);
      harness.server.intercept = (request) =>
          request.method == 'PUT' ? http.Response('', 507) : null;
      expect(
        await cubit.changePassphrase('four new long words'),
        SyncFailure.insufficientStorage,
      );
      harness.server.intercept = null;
      expect(await cubit.changePassphrase('four new long words'), isNull);
      await cubit.updateOptions(
        harness.service.state.config!.copyWith(wifiOnly: true),
      );
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.config!.wifiOnly, isTrue);
      harness.mode = PrivacyMode.offlineOnly;
      expect(await cubit.turnOff(deleteRemote: true), SyncFailure.offlineOnly);
      expect(await cubit.turnOff(), isNull);
      await Future<void>.delayed(Duration.zero);
      expect(states.last.isSetUp, isFalse);
      expect(states.any((state) => state.running), isTrue);
      await subscription.cancel();
      await cubit.close();
      await harness.service.dispose();
    });
  });

  group('SyncSetupCubit', () {
    test('tests, then turns sync on', () async {
      final harness = SyncHarness();
      final cubit = SyncSetupCubit(harness.service);
      expect(cubit.state, const SyncSetupState());
      expect(cubit.sectionIds, hasLength(3));
      // Nothing to turn on before a test.
      await cubit.turnOn(
        passphrase: 'p',
        options: SyncConfig(server: harnessServer, username: 'alice'),
      );
      expect(cubit.state.step, SyncSetupStep.editing);

      final testing = cubit.test(harness.connection());
      expect(cubit.state.step, SyncSetupStep.testing);
      expect(cubit.state.busy, isTrue);
      await testing;
      expect(cubit.state.step, SyncSetupStep.tested);
      expect(cubit.state.probe!.hasSyncFile, isFalse);

      // The same connection keeps the test; another one drops it.
      cubit.edited(harness.connection());
      expect(cubit.state.step, SyncSetupStep.tested);
      cubit.edited(harness.connection(password: 'other'));
      expect(cubit.state, const SyncSetupState());
      cubit.edited(harness.connection(password: 'third'));
      expect(cubit.state, const SyncSetupState());

      await cubit.test(harness.connection());
      final turning = cubit.turnOn(
        passphrase: 'four random long words',
        options: SyncConfig(server: harnessServer, username: 'alice'),
      );
      expect(cubit.state.step, SyncSetupStep.turningOn);
      cubit.edited(harness.connection(password: 'ignored while busy'));
      expect(cubit.state.step, SyncSetupStep.turningOn);
      await turning;
      expect(cubit.state.step, SyncSetupStep.done);
      expect(harness.service.state.isSetUp, isTrue);
      await cubit.close();
    });

    test('keeps the failure of a test and of turning on', () async {
      final harness = SyncHarness(mode: PrivacyMode.offlineOnly);
      final cubit = SyncSetupCubit(harness.service);
      await cubit.test(harness.connection());
      expect(cubit.state.failure, SyncFailure.offlineOnly);
      expect(cubit.state.step, SyncSetupStep.editing);
      cubit.edited(harness.connection(password: 'x'));
      expect(cubit.state.failure, isNull);

      harness.mode = PrivacyMode.online;
      await cubit.test(harness.connection());
      harness.mode = PrivacyMode.offlineOnly;
      await cubit.turnOn(
        passphrase: 'four random long words',
        options: SyncConfig(server: harnessServer, username: 'alice'),
      );
      expect(cubit.state.step, SyncSetupStep.tested);
      expect(cubit.state.failure, SyncFailure.offlineOnly);
      expect(cubit.state.probe, isNotNull);
      await cubit.close();
    });
  });
}
