import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:mozhi/core/network/network_session.dart';
import 'package:mozhi/offline/data/unavailable_offline_translator.dart';
import 'package:mozhi/platform/current_session_client.dart';
import 'package:mozhi/platform/free_space.dart';
import 'package:mozhi/platform/metered_network.dart';
import 'package:mozhi/platform/native_memory.dart';
import 'package:path_provider/path_provider.dart';
import 'package:translation_repository/translation_repository.dart';

export 'package:mozhi/platform/current_session_client.dart';

/// Folder of the app's support directory that holds the offline models
/// (`<support>/bergamot/models/<pair>/<version>/`).
const offlineModelsFolder = 'bergamot';

/// The build's on-device translator: [createBergamotOfflineTranslator] with
/// the platform defaults.
Future<OfflineTranslator> createOfflineTranslator() =>
    createBergamotOfflineTranslator();

/// Creates the on-device translator: a [BergamotTranslator] with the
/// bundled model catalog ([bundle], default `rootBundle`), its models in
/// the app-private [supportDirectory] (default
/// `getApplicationSupportDirectory()`: not backed up, removed with the
/// app), downloads through [httpClient] (default: the current
/// [NetworkSession]'s client at the time of each request, so the proxy
/// setting applies) and [isMeteredConnection] (default
/// [MeteredNetwork.isMetered]) for Wi-Fi-only downloads.
///
/// Leftovers of interrupted installs are removed in the background
/// ([BergamotModelManager.cleanUp]); nothing here waits for it. A download
/// first checks the free space ([freeSpace], default [FreeSpace.instance]).
/// [isAvailable] and [engine] replace the platform's (tests).
///
/// Memory: the engine keeps [DeviceMemory.bergamotModelCacheSize] models
/// loaded ([deviceMemory], default [DeviceMemory.query], asked while the
/// catalog loads), and on memory pressure ([memoryBudget], default
/// [NativeMemoryBudget.instance]) unloads all but those of the last
/// translation ([BergamotTranslator.trimMemory]).
///
/// Never throws: when the catalog or the directory cannot be loaded (for
/// example on a desktop host without path_provider), it logs the error and
/// returns an [UnavailableOfflineTranslator].
Future<OfflineTranslator> createBergamotOfflineTranslator({
  AssetBundle? bundle,
  Future<Directory> Function() supportDirectory =
      getApplicationSupportDirectory,
  Future<bool> Function()? isMeteredConnection,
  http.Client? httpClient,
  bool? isAvailable,
  BergamotEngine? engine,
  Future<DeviceMemory?> Function()? deviceMemory,
  NativeMemoryBudget? memoryBudget,
  FreeSpace? freeSpace,
}) async {
  try {
    final (catalog, support, memory) = await (
      loadBundledCatalog(bundle: bundle),
      supportDirectory(),
      (deviceMemory ?? DeviceMemory.query)(),
    ).wait;
    final translator = BergamotTranslator(
      catalog: catalog,
      root: Directory(
        '${support.path}${Platform.pathSeparator}$offlineModelsFolder',
      ),
      isMeteredConnection:
          isMeteredConnection ?? MeteredNetwork.instance.isMetered,
      httpClient: httpClient ?? CurrentSessionClient(),
      engine:
          engine ??
          createBergamotEngine(
            maxLoadedModels:
                memory?.bergamotModelCacheSize ??
                const DeviceMemory().bergamotModelCacheSize,
          ),
      isAvailable: isAvailable,
      // Every download first checks that it fits.
      freeSpace: (freeSpace ?? FreeSpace.instance).call,
    );
    if (translator.isAvailable) {
      unawaited(_cleanUp(translator));
      (memoryBudget ?? NativeMemoryBudget.instance).onMemoryPressure(
        translator.trimMemory,
      );
    }
    return translator;
  } on Object catch (error, stackTrace) {
    final cause = error is ParallelWaitError ? error.errors : error;
    log(
      'Offline translation unavailable',
      name: 'mozhi',
      error: cause,
      stackTrace: stackTrace,
    );
    return const UnavailableOfflineTranslator();
  }
}

/// Deletes the offline models folder (`<support>/bergamot`, see
/// [offlineModelsFolder]) with everything in it: models, partial downloads
/// and leftovers of interrupted installs. Delete the languages through the
/// translator first ([OfflineTranslator.deleteLanguage]), so that it
/// releases the models it has loaded. Throws when the folder cannot be
/// deleted.
Future<void> deleteOfflineModelFiles({
  Future<Directory> Function() supportDirectory =
      getApplicationSupportDirectory,
}) async {
  final support = await supportDirectory();
  final folder = Directory(
    '${support.path}${Platform.pathSeparator}$offlineModelsFolder',
  );
  if (folder.existsSync()) await folder.delete(recursive: true);
}

Future<void> _cleanUp(BergamotTranslator translator) async {
  try {
    await translator.models.cleanUp();
    // coverage:ignore-start
  } on Object catch (error, stackTrace) {
    // cleanUp() already ignores file system errors; this is a safety net
    // so that a start-up chore can never become an uncaught error.
    log(
      'Offline model clean-up failed',
      name: 'mozhi',
      error: error,
      stackTrace: stackTrace,
    );
  }
  // coverage:ignore-end
}
