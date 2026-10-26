import 'dart:convert';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';

void main() {
  group(AppLockTimeout, () {
    test('has the delays of the contract', () {
      expect(AppLockTimeout.off.delay, isNull);
      expect(AppLockTimeout.immediately.delay, Duration.zero);
      expect(AppLockTimeout.after1Minute.delay, const Duration(minutes: 1));
      expect(AppLockTimeout.after5Minutes.delay, const Duration(minutes: 5));
      expect(AppLockTimeout.after15Minutes.delay, const Duration(minutes: 15));
    });

    test('is on unless off', () {
      expect(AppLockTimeout.off.isOn, isFalse);
      for (final timeout in AppLockTimeout.values.skip(1)) {
        expect(timeout.isOn, isTrue, reason: timeout.name);
      }
    });

    test('reads every timeout by name and anything else as off', () {
      for (final timeout in AppLockTimeout.values) {
        expect(AppLockTimeout.fromName(timeout.name), timeout);
      }
      expect(AppLockTimeout.fromName('after60Minutes'), AppLockTimeout.off);
      expect(AppLockTimeout.fromName(5), AppLockTimeout.off);
      expect(AppLockTimeout.fromName(null), AppLockTimeout.off);
    });
  });

  group('AppSettings.appLock', () {
    test('is off by default', () {
      expect(const AppSettings().appLock, AppLockTimeout.off);
    });

    test('is stored by name and read back', () {
      const settings = AppSettings(appLock: AppLockTimeout.after5Minutes);
      final json =
          jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>;

      expect(json['appLock'], 'after5Minutes');
      expect(AppSettings.fromJson(json).appLock, AppLockTimeout.after5Minutes);
    });

    test('reads missing, unknown and invalid values as off', () {
      expect(AppSettings.fromJson(const {}).appLock, AppLockTimeout.off);
      expect(
        AppSettings.fromJson(const {'appLock': 'sometimes'}).appLock,
        AppLockTimeout.off,
      );
      expect(
        AppSettings.fromJson(const {'appLock': true}).appLock,
        AppLockTimeout.off,
      );
    });

    test('is replaced by copyWith and kept otherwise', () {
      const settings = AppSettings(appLock: AppLockTimeout.immediately);

      expect(settings.copyWith().appLock, AppLockTimeout.immediately);
      expect(
        settings.copyWith(appLock: AppLockTimeout.off).appLock,
        AppLockTimeout.off,
      );
    });

    test('takes part in equality', () {
      expect(
        const AppSettings(appLock: AppLockTimeout.immediately),
        isNot(const AppSettings()),
      );
      expect(
        const AppSettings(appLock: AppLockTimeout.immediately),
        const AppSettings(appLock: AppLockTimeout.immediately),
      );
    });
  });

  group('SettingsCubit.setAppLock', () {
    late MemoryStore prefs;
    late SettingsRepository repository;

    setUp(() {
      prefs = MemoryStore();
      repository = SettingsRepository(prefs: prefs, secrets: MemoryStore());
    });

    blocTest<SettingsCubit, AppSettings>(
      'emits and saves the timeout',
      build: () => SettingsCubit(repository: repository),
      act: (cubit) => cubit.setAppLock(AppLockTimeout.after1Minute),
      expect: () => [const AppSettings(appLock: AppLockTimeout.after1Minute)],
      verify: (_) async {
        await pumpEventQueue();
        final stored = jsonDecode(
          (await prefs.read(SettingsRepository.settingsKey))!,
        ) as Map<String, dynamic>;
        expect(stored['appLock'], 'after1Minute');
        expect((await repository.load()).appLock, AppLockTimeout.after1Minute);
      },
    );

    blocTest<SettingsCubit, AppSettings>(
      'emits nothing for the current timeout',
      build: () => SettingsCubit(repository: repository),
      act: (cubit) => cubit.setAppLock(AppLockTimeout.off),
      expect: () => const <AppSettings>[],
    );
  });
}
