import 'package:whisper_speech/src/catalog.dart';

/// The folder of a model mirror that holds the Whisper models (see
/// [whisperMirrorUrl]).
const whisperMirrorFolder = 'whisper';

/// Where [model] is on a mirror of the model files at [mirror] (a base
/// URL, e.g. `https://example.org/models/`):
/// `<mirror>/whisper/<name>`, the file under its published name
/// ([WhisperCatalogModel.name], e.g. `ggml-tiny.bin`).
///
/// The mirror is not trusted: a download from it is checked against the
/// catalog's size and checksums like one from Hugging Face. The layout is
/// that of every model mirror (`tool/mirror_models.py` writes it), next to
/// the `bergamot/` and `tesseract/` folders of the translation and text
/// recognition models.
///
/// Throws [ArgumentError] when [mirror] is not an absolute `http` or
/// `https` URL without query and fragment.
Uri whisperMirrorUrl(Uri mirror, WhisperCatalogModel model) =>
    _mirrorUrl(mirror, [whisperMirrorFolder, model.name]);

/// The URLs to download [model] from, in the order to try them: without a
/// [mirror], [WhisperCatalogModel.url] (Hugging Face); with one, its copy
/// ([whisperMirrorUrl]), then [WhisperCatalogModel.url] when
/// [fallbackToDefault] (for a file the mirror does not serve: an HTTP error
/// or a failed connection).
///
/// Whichever URL answers, the file must match the catalog's size and
/// checksums.
List<Uri> whisperDownloadUrls(
  WhisperCatalogModel model, {
  Uri? mirror,
  bool fallbackToDefault = false,
}) => [
  if (mirror != null) whisperMirrorUrl(mirror, model),
  if (mirror == null || fallbackToDefault) model.url,
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
