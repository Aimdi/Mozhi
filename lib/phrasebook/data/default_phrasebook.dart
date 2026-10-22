import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/dictionary/data/default_dictionary_packs.dart'
    show SessionHttpClient;
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/phrasebook/data/starter_catalog_data.dart';
import 'package:mozhi/settings/models/model_source.dart';

/// The folder of a model mirror that holds the starter phrasebooks (see
/// [starterPhrasebookUrls]).
const starterPhrasebookMirrorFolder = 'phrasebooks';

/// The app's phrasebook: stored in [preferences] (encrypted, its key in
/// the platform's secure storage, see [PhrasebookRepository]), with the
/// starter phrasebooks of [createStarterPhrasebooks] and, given [history]
/// (or later with `attachFavorites(HistoryCubitFavorites(cubit))`), its
/// favourites as the Favorites collection.
///
/// Created at startup (its backup section is registered with the app's
/// backup registry) and provided as `RepositoryProvider<
/// PhrasebookRepository>`; nothing is read until a screen asks.
PhrasebookRepository createPhrasebookRepository({
  required KeyValueStore preferences,
  HistoryCubit? history,
}) => PhrasebookRepository(
  store: preferences,
  favorites: history == null ? null : HistoryCubitFavorites(history),
  starter: createStarterPhrasebooks(preferences),
);

/// The starter phrasebooks of the bundled catalogue
/// ([bundledStarterCatalog]), kept in [store], downloaded through the
/// current `NetworkSession` (its proxy, network rules and request log, as
/// model downloads) from the model source ([starterPhrasebookUrls]).
StarterPhrasebooks createStarterPhrasebooks(KeyValueStore store) =>
    StarterPhrasebooks(
      catalog: bundledStarterCatalog(),
      store: store,
      httpClient: SessionHttpClient(),
      downloadUrls: starterPhrasebookUrls,
    );

/// Where [pack] is downloaded from with [source] (default
/// [ModelSource.current], the settings' model source): its mirror's
/// `phrasebooks/<id>.json.gz`, then the catalogue's URL when the source
/// falls back to the original publishers; the catalogue's URL (the GitHub
/// release) without a mirror. Whichever answers, the file must match the
/// catalogue's size and SHA-256.
List<Uri> starterPhrasebookUrls(
  StarterPhrasebookInfo pack, {
  ModelSource? source,
}) {
  final model = source ?? ModelSource.current;
  final mirror = model.mirror();
  if (mirror == null) return [pack.url];
  return [
    mirror.resolve('$starterPhrasebookMirrorFolder/${pack.fileName}'),
    if (model.fallsBackToDefault) pack.url,
  ];
}

/// The catalogue bundled with the app ([starterCatalogJson]), or an empty
/// one when it cannot be read.
StarterPhrasebookCatalog bundledStarterCatalog([
  String json = starterCatalogJson,
]) {
  try {
    return StarterPhrasebookCatalog.parse(json);
  } on FormatException {
    return StarterPhrasebookCatalog(const []);
  }
}
