import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/sync/data/sync_service.dart';
import 'package:mozhi/sync/models/sync_config.dart';
import 'package:translation_repository/translation_repository.dart'
    show PrivacyMode;

import 'fake_webdav_server.dart';
import 'memory_section.dart';

/// The path of the sync file on a [SyncHarness]'s server.
const syncFilePath = '/dav/Mozhi/${SyncConfig.fileName}';

/// The server address a [SyncHarness]'s server answers at.
final Uri harnessServer = Uri.parse('https://cloud.example.org/dav/');

/// A sync service on an in-memory WebDAV server, with three sections.
class SyncHarness {
  new({this.mode = PrivacyMode.offlineFirst, FakeWebDavServer? server})
    : server = server ?? FakeWebDavServer();

  final FakeWebDavServer server;
  final prefs = MemoryStore();
  final secrets = MemoryStore();
  final history = MemorySection('history');
  final presets = MemorySection('presets');
  final settings = MemorySection('settings');
  PrivacyMode mode;

  late final SyncService service = SyncService(
    registry: registryOf([history, presets, settings]),
    prefs: prefs,
    secrets: secrets,
    codec: testCodec,
    httpClient: () => server.client,
    privacyMode: () => mode,
    isMetered: () async => false,
    clock: () => DateTime(2026, 10, 22, 9, 30),
    debounce: const Duration(hours: 1),
  );

  late final SettingsCubit settingsCubit = SettingsCubit(
    repository: SettingsRepository(
      prefs: MemoryStore(),
      secrets: MemoryStore(),
    ),
    initial: AppSettings(privacyMode: mode),
  );

  /// The connection the server accepts.
  SyncConnection connection({String password = 'app-password'}) =>
      SyncConnection(
        server: harnessServer,
        username: 'alice',
        password: password,
      );

  /// Sets sync up with [passphrase].
  Future<void> setUp([String passphrase = 'correct horse battery']) async {
    final probe = await service.probe(connection());
    await service.setUp(
      connection: connection(),
      passphrase: passphrase,
      config: SyncConfig(server: harnessServer, username: 'alice'),
      probed: probe,
    );
  }

  /// [child] with the service and a settings cubit above it.
  Widget wrap(Widget child) => RepositoryProvider<SyncService>.value(
    value: service,
    child: BlocProvider<SettingsCubit>.value(
      value: settingsCubit,
      child: child,
    ),
  );
}
