import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:tesseract_ocr/src/catalog.dart';
import 'package:tesseract_ocr/src/download_cancel.dart';
import 'package:tesseract_ocr/src/engine/engine_factory.dart';
import 'package:tesseract_ocr/src/engine/ocr_engine.dart';
import 'package:tesseract_ocr/src/model_manager.dart';

/// [TesseractOcr.recognize] was asked for languages whose data is not
/// installed ([missing]); nothing was recognised. [TesseractOcr.recognize]
/// never downloads.
@immutable
final class TessdataMissingException implements Exception {
  const new(this.missing);

  /// Tesseract codes without installed data.
  final List<String> missing;

  @override
  String toString() => 'TessdataMissingException(${missing.join(', ')})';
}

/// On-device text recognition with Tesseract (LSTM, tessdata_fast): the
/// language data of [catalog], managed by [data] under `<root>/tessdata/`,
/// and the native engine in a background isolate.
///
/// * [recognize] reads raw pixels (decode images with `dart:ui` first) and
///   never touches the network; languages whose data is missing throw
///   [TessdataMissingException].
/// * [download] fetches one language's data (SHA-256 verified, resumable;
///   only when asked), [importFiles] installs copies made by hand without
///   the network, [delete] removes one.
/// * [isAvailable] is false where the engine cannot run (web, desktop, a
///   32-bit ARM CPU without NEON) unless an [OcrEngine] is injected.
class TesseractOcr {
  /// [engine] and [isAvailable] replace the platform's (tests);
  /// [httpClient] is used for downloads (default: a new client, closed by
  /// [dispose]); [freeSpace] (the free bytes of the file system of a path)
  /// lets downloads and imports check for room first ([TessdataManager]).
  new({
    required this.catalog,
    required Directory root,
    http.Client? httpClient,
    OcrEngine? engine,
    bool? isAvailable,
    Duration requestTimeout = const Duration(seconds: 60),
    Future<int?> Function(String path)? freeSpace,
  }) : data = TessdataManager(
         root: root,
         httpClient: httpClient,
         requestTimeout: requestTimeout,
         freeSpace: freeSpace,
       ),
       _engine = engine,
       _isAvailable =
           isAvailable ?? (engine != null || tesseractPlatformSupported);

  final TessdataCatalog catalog;

  /// The installed language data.
  final TessdataManager data;

  final bool _isAvailable;
  OcrEngine? _engine;

  /// Whether text can be recognised here.
  bool get isAvailable => _isAvailable;

  /// Codes of the catalog languages whose data is installed (any version:
  /// an older one still reads text).
  Future<Set<String>> installedLanguages() async => {
    for (final language in await data.installed())
      if (catalog.byCode(language.code) != null) language.code,
  };

  /// Recognises the text in [pixels] ([width] x [height]; RGBA with
  /// premultiplied alpha by default, see [OcrImage]) with [languages]
  /// (Tesseract codes, main language first; at most 8). With [layout] the
  /// result also says where the text is ([OcrResult.layout]: blocks,
  /// paragraphs, lines and words with their boxes in pixels of this image,
  /// and the colours of each paragraph's text and background).
  ///
  /// Throws [ArgumentError] for no or invalid languages,
  /// [TessdataMissingException] when one is not installed,
  /// [UnsupportedError] when [isAvailable] is false and
  /// [TesseractEngineException] when the engine fails.
  Future<OcrResult> recognize(
    Uint8List pixels,
    int width,
    int height, {
    required List<String> languages,
    int bytesPerPixel = 4,
    int? bytesPerLine,
    bool layout = false,
  }) async {
    if (!isAvailable) {
      throw UnsupportedError('On-device text recognition is not available');
    }
    if (languages.isEmpty || languages.length > 8) {
      throw ArgumentError.value(languages, 'languages', 'Give 1 to 8');
    }
    for (final code in languages) {
      if (!isTesseractCode(code)) {
        throw ArgumentError.value(code, 'languages', 'Invalid Tesseract code');
      }
    }
    final image = OcrImage(
      pixels,
      width: width,
      height: height,
      bytesPerPixel: bytesPerPixel,
      bytesPerLine: bytesPerLine,
    );
    final installed = {
      for (final language in await data.installed()) language.code,
    };
    final missing = [
      for (final code in {...languages})
        if (!installed.contains(code)) code,
    ];
    if (missing.isNotEmpty) throw TessdataMissingException(missing);
    return await _engineOrCreate().recognize(
      image,
      dataPath: data.dataDirectory.path,
      languages: [
        ...{...languages},
      ],
      layout: layout,
    );
  }

  /// Downloads and installs the data of [code] (or a newer version of it).
  /// Throws [ArgumentError] for a code not in [catalog],
  /// [TessdataInstallException] when the download fails and
  /// [TessdataDownloadCancelledException] once [cancelDownload] stopped it.
  Future<InstalledTessdata> download(
    String code, {
    void Function(TessdataDownloadProgress progress)? onProgress,
  }) async {
    final language = catalog.byCode(code);
    if (language == null) {
      throw ArgumentError.value(code, 'code', 'Not in the catalog');
    }
    final installed = await data.install(language, onProgress: onProgress);
    await _release();
    return installed;
  }

  /// Stops the running [download]s of [code] (see
  /// [TessdataManager.cancelInstall]): nothing is installed by them, and
  /// what was received is kept for the next download to resume. Completes
  /// once they have stopped. Never throws.
  Future<void> cancelDownload(String code) => data.cancelInstall(code);

  /// Installs language data from files copied to the device by hand; see
  /// [TessdataManager.importFiles]. Never uses the network.
  Future<TessdataImportResult> importFiles(Iterable<File> files) async {
    final result = await data.importFiles(files, catalog: catalog);
    if (result.installed.isNotEmpty) await _release();
    return result;
  }

  /// Deletes the data of [code].
  Future<void> delete(String code) async {
    await _release();
    await data.delete(code);
  }

  /// Stops the engine and closes the HTTP client this created.
  Future<void> dispose() async {
    final engine = _engine;
    _engine = null;
    data.close();
    await engine?.dispose();
  }

  OcrEngine _engineOrCreate() => _engine ??= createTesseractEngine();

  /// Lets the engine load changed data on its next use.
  Future<void> _release() async {
    try {
      await _engine?.release();
    } on Object {
      // Nothing loaded, or the isolate is gone: nothing to release.
    }
  }
}
