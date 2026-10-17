import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:mozhi/core/network/network_session.dart';
import 'package:mozhi/offline/data/unavailable_offline_translator.dart';
import 'package:mozhi/platform/metered_network.dart';
import 'package:path_provider/path_provider.dart';
import 'package:translation_repository/translation_repository.dart';

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
/// ([BergamotModelManager.cleanUp]); nothing here waits for it.
/// [isAvailable] and [engine] replace the platform's (tests).
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
}) async {
  try {
    final (catalog, support) = await (
      loadBundledCatalog(bundle: bundle),
      supportDirectory(),
    ).wait;
    final translator = BergamotTranslator(
      catalog: catalog,
      root: Directory(
        '${support.path}${Platform.pathSeparator}$offlineModelsFolder',
      ),
      isMeteredConnection:
          isMeteredConnection ?? MeteredNetwork.instance.isMetered,
      httpClient: httpClient ?? CurrentSessionClient(),
      engine: engine,
      isAvailable: isAvailable,
    );
    if (translator.isAvailable) unawaited(_cleanUp(translator));
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

Future<void> _cleanUp(BergamotTranslator translator) async {
  try {
    await translator.models.cleanUp();
  } on Object catch (error, stackTrace) {
    log(
      'Offline model clean-up failed',
      name: 'mozhi',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

/// An [http.Client] that sends every request with the client of
/// [NetworkSession.current] at that moment (the proxy and network policy
/// of this run). Closing it does nothing: the session owns the client.
class CurrentSessionClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      NetworkSession.current.client.send(request);
}
