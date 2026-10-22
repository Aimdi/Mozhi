import 'package:tesseract_ocr/src/catalog.dart';

/// The folder of a model mirror that holds the Tesseract language data
/// (see [tessdataMirrorUrl]).
const tessdataMirrorFolder = 'tesseract';

/// Where [language]'s data is on a mirror of the model files at [mirror]
/// (a base URL, e.g. `https://example.org/models/`):
/// `<mirror>/tesseract/<code>.traineddata`
/// ([TessdataLanguage.fileName], as tessdata_fast publishes it).
///
/// The mirror is not trusted: a download from it is checked against the
/// catalog's size and SHA-256 like one from GitHub. The layout is that of
/// every model mirror (`tool/mirror_models.py` writes it), next to the
/// `bergamot/` and `whisper/` folders of the translation and speech models.
///
/// Throws [ArgumentError] when [mirror] is not an absolute `http` or
/// `https` URL without query and fragment.
Uri tessdataMirrorUrl(Uri mirror, TessdataLanguage language) =>
    _mirrorUrl(mirror, [tessdataMirrorFolder, language.fileName]);

/// The URLs to download [language]'s data from, in the order to try them:
/// without a [mirror], [TessdataLanguage.url] (GitHub); with one, its copy
/// ([tessdataMirrorUrl]), then [TessdataLanguage.url] when
/// [fallbackToDefault] (for a file the mirror does not serve: an HTTP error
/// or a failed connection).
///
/// Whichever URL answers, the file must match the catalog's size and
/// SHA-256.
List<Uri> tessdataDownloadUrls(
  TessdataLanguage language, {
  Uri? mirror,
  bool fallbackToDefault = false,
}) => [
  if (mirror != null) tessdataMirrorUrl(mirror, language),
  if (mirror == null || fallbackToDefault) language.url,
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
