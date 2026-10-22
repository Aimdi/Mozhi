import 'dart:async';
import 'dart:developer';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:mozhi/core/network/network_session.dart';
import 'package:mozhi/offline/data/unavailable_offline_translator.dart';
import 'package:mozhi/platform/browser_network.dart';
import 'package:mozhi/platform/current_session_client.dart';
import 'package:translation_repository/translation_repository.dart';

/// The web app's on-device translator: [createWebOfflineTranslator] with
/// the browser's worker.
Future<OfflineTranslator> createOfflineTranslator() =>
    createWebOfflineTranslator();

/// Creates the web app's on-device translator: Mozilla's Bergamot engine
/// and CLD2 compiled to WebAssembly, in the worker [channel] (default:
/// `web/bergamot/worker.js`, [openBergamotWorker]), with the same catalog
/// ([bundle], default `rootBundle`), routing and language identification as
/// the Android app ([createWebBergamotTranslator]). The language packs live
/// in the browser's private storage for this site (the Origin Private File
/// System), are downloaded through [httpClient] (default: the current
/// [NetworkSession]'s client, so its network rules and request log apply)
/// and verified against the catalog's SHA-256 like on Android; each
/// download first asks the browser to keep them ([requestPersistence],
/// default `navigator.storage.persist()`). [isMeteredConnection] (default:
/// what the browser says, see [browserConnectionIsMetered]) drives "Wi-Fi
/// only".
///
/// When the browser lacks something the engine needs (WebAssembly SIMD,
/// the private storage, a secure context, the engine files of this build)
/// it returns an [UnavailableOfflineTranslator] whose
/// [UnavailableOfflineTranslator.webRequirement] says what; the app then
/// works as before, online only. Leftovers of interrupted installs are
/// removed in the background. Never throws.
Future<OfflineTranslator> createWebOfflineTranslator({
  AssetBundle? bundle,
  BergamotWorkerChannel? channel,
  http.Client? httpClient,
  Future<bool> Function()? isMeteredConnection,
  Future<bool> Function()? requestPersistence,
}) async {
  final worker = channel ?? openBergamotWorker();
  if (worker == null) {
    return const UnavailableOfflineTranslator(
      webRequirement: BergamotWebRequirement.engineFiles,
    );
  }
  try {
    final (support, catalog) = await (
      probeBergamotWorker(worker),
      loadBundledCatalog(bundle: bundle),
    ).wait;
    if (!support.isSupported) {
      log('On-device translation unavailable: $support', name: 'mozhi');
      worker.terminate();
      return UnavailableOfflineTranslator(webRequirement: support.reason);
    }
    final translator = createWebBergamotTranslator(
      catalog: catalog,
      channel: worker,
      httpClient: httpClient ?? CurrentSessionClient(),
      isAvailable: true,
      isMeteredConnection: isMeteredConnection ?? browserConnectionIsMetered,
      requestPersistence: requestPersistence ?? requestPersistentBrowserStorage,
    );
    unawaited(translator.models.cleanUp());
    return translator;
  } on Object catch (error, stackTrace) {
    final cause = error is ParallelWaitError ? error.errors : error;
    log(
      'Offline translation unavailable',
      name: 'mozhi',
      error: cause,
      stackTrace: stackTrace,
    );
    worker.terminate();
    return const UnavailableOfflineTranslator();
  }
}

/// Deletes the offline language packs from the browser's private storage
/// (the worker's `models/` and `.downloads/` folders). Delete the languages
/// through the translator first ([OfflineTranslator.deleteLanguage]), so
/// that it releases the models it has loaded. Does nothing where no worker
/// runs. Throws when the browser cannot delete them.
Future<void> deleteOfflineModelFiles({BergamotWorkerChannel? channel}) async {
  final worker = channel ?? openBergamotWorker();
  if (worker == null) return;
  for (final path in ['models', '.downloads']) {
    await worker.request('remove', {'path': path});
  }
}
