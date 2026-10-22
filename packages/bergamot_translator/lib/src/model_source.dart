import 'package:bergamot_translator/src/catalog.dart';

/// The folder of a model mirror that holds the offline translation models
/// (see [bergamotMirrorUrl]).
const bergamotMirrorFolder = 'bergamot';

/// Where [file] of [model] is on a mirror of the model files at [mirror]
/// (a base URL, e.g. `https://example.org/models/`):
/// `<mirror>/bergamot/<source>-<target>/<version>/<name>.gz`, the file as
/// Mozilla publishes it (gzip-compressed, under its published name, see
/// [CatalogFile.url]).
///
/// The mirror is not trusted: a download from it is checked against the
/// catalog's size and SHA-256 like one from Mozilla. Every model file is
/// in the mirror layout (`tool/mirror_models.py` writes it), next to the
/// `whisper/` and `tesseract/` folders of the speech and text recognition
/// models.
///
/// Throws [ArgumentError] when [mirror] is not an absolute `http` or
/// `https` URL without query and fragment.
Uri bergamotMirrorUrl(Uri mirror, CatalogModel model, CatalogFile file) =>
    _mirrorUrl(mirror, [
      bergamotMirrorFolder,
      model.pair,
      model.version,
      file.url.pathSegments.last,
    ]);

/// The URLs to download [file] of [model] from, in the order to try them:
/// without a [mirror], [CatalogFile.url] (Mozilla's bucket on Google Cloud
/// Storage); with one, its copy ([bergamotMirrorUrl]), then
/// [CatalogFile.url] when [fallbackToDefault] (for a file the mirror does
/// not serve: an HTTP error or a failed connection).
///
/// Whichever URL answers, the file must match the catalog's size and
/// SHA-256. This is the one place that decides where model files come
/// from, for every platform's downloads.
List<Uri> bergamotDownloadUrls(
  CatalogModel model,
  CatalogFile file, {
  Uri? mirror,
  bool fallbackToDefault = false,
}) => [
  if (mirror != null) bergamotMirrorUrl(mirror, model, file),
  if (mirror == null || fallbackToDefault) file.url,
];

/// [mirror] with [segments] appended to its path.
Uri _mirrorUrl(Uri mirror, List<String> segments) {
  if (!(mirror.isScheme('https') || mirror.isScheme('http')) ||
      mirror.host.isEmpty ||
      mirror.hasQuery ||
      mirror.hasFragment) {
    throw ArgumentError.value(mirror, 'mirror', 'Not an http(s) base URL');
  }
  for (final segment in segments) {
    if (segment.isEmpty ||
        segment == '.' ||
        segment == '..' ||
        segment.contains('/')) {
      throw ArgumentError.value(segment, 'segments', 'Unsafe path segment');
    }
  }
  return mirror.replace(
    pathSegments: [
      for (final segment in mirror.pathSegments)
        if (segment.isNotEmpty) segment,
      ...segments,
    ],
  );
}
