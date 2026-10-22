import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart' show BuildContext;
import 'package:mozhi/core/network/network_session.dart';
import 'package:mozhi/dictionary/data/dictionary_catalog_data.dart';
import 'package:mozhi/dictionary/data/dictionary_pack_storage_platform.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/platform/metered_network.dart';
import 'package:mozhi/settings/models/model_source.dart';
import 'package:translation_repository/translation_repository.dart';

DictionaryPacks? _shared;

/// The app's offline dictionaries: one [DictionaryPacks] with the bundled
/// catalogue ([bundledDictionaryCatalog]), the platform's storage (app
/// files on Android, OPFS in a browser), downloads through the current
/// `NetworkSession` (its proxy and network rules; recorded in its ledger)
/// from the model source the settings choose (`ModelSource.current`: the
/// release on GitHub, or `<mirror>/dictionary/<id>.mzd`), and the
/// device's metered network check for Wi-Fi-only downloads.
///
/// Created on first use; nothing is read until a pack is listed or looked
/// up. The app provides it (`RepositoryProvider<DictionaryPacks>`) to the
/// dictionary, the translate screen and the offline languages screen
/// ([maybeDictionaryPacks]).
DictionaryPacks defaultDictionaryPacks() => _shared ??= DictionaryPacks(
  catalog: bundledDictionaryCatalog(),
  storage: createDictionaryPackStorage(),
  httpClient: _SessionClient(),
  isMeteredConnection: MeteredNetwork.instance.isMetered,
  downloadUrls: (pack) {
    final source = ModelSource.current;
    return dictionaryPackDownloadUrls(
      pack,
      mirror: source.mirror(),
      fallbackToDefault: source.fallsBackToDefault,
    );
  },
);

/// The catalogue bundled with the app ([dictionaryCatalogJson]), or an
/// empty one when it cannot be read.
DictionaryPackCatalog bundledDictionaryCatalog([
  String json = dictionaryCatalogJson,
]) {
  try {
    return DictionaryPackCatalog.parse(json);
  } on FormatException {
    return DictionaryPackCatalog(const []);
  }
}

/// The [DictionaryPacks] provided above [context], or null (none in tests
/// that do not provide one: the dictionary then works as before, with AI
/// only).
DictionaryPacks? maybeDictionaryPacks(BuildContext context) {
  try {
    return context.read<DictionaryPacks>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// Sends every request with the client of [NetworkSession.current] at that
/// moment. Closing it does nothing: the session owns the client.
class _SessionClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      NetworkSession.current.client.send(request);
}
