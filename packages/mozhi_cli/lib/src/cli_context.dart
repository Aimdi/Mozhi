import 'dart:io' as io;

import 'package:mason_logger/mason_logger.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:mozhi_cli/src/config/config_store.dart';
import 'package:mozhi_cli/src/console.dart';
import 'package:translation_repository/translation_repository.dart';

/// Creates the repository a command talks to.
typedef RepositoryFactory = TranslationRepository Function();

/// Creates the configuration store for a file path.
typedef ConfigStoreFactory = ConfigStore Function(String path);

/// Services shared by all commands.
class CliContext {
  new({
    required this.logger,
    Console? console,
    RepositoryFactory? repositoryFactory,
    ConfigStoreFactory? configStoreFactory,
  }) : console = console ?? Console(),
       repositoryFactory = repositoryFactory ?? defaultRepository,
       configStoreFactory = configStoreFactory ?? _defaultStore;

  final Logger logger;
  final Console console;
  final RepositoryFactory repositoryFactory;
  final ConfigStoreFactory configStoreFactory;

  /// Upper bound for each Mozhi request.
  static const mozhiTimeout = Duration(seconds: 20);

  static TranslationRepository defaultRepository() => TranslationRepository(
    mozhiClientFactory: (baseUrl) =>
        MozhiApiClient(baseUrl: baseUrl, timeout: mozhiTimeout),
  );

  static ConfigStore _defaultStore(String path) =>
      ConfigStore(path: path, posix: !io.Platform.isWindows);
}
