import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:mozhi/image_translate/data/rgba_image_decoder.dart';
import 'package:mozhi/image_translate/data/tesseract_text_recognition_service.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/platform/metered_network.dart';
import 'package:mozhi/platform/offline_engine_io.dart'
    show CurrentSessionClient;
import 'package:path_provider/path_provider.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart';

/// Folder of the app's support directory that holds the text recognition
/// data (`<support>/tesseract/tessdata/<code>.traineddata`).
const textRecognitionFolder = 'tesseract';

TesseractTextRecognitionService? _shared;

/// The app's on-device text recognizer: one
/// [createTesseractTextRecognitionService] with the platform defaults,
/// shared by the image screen and the offline languages screen.
TextRecognitionService defaultTextRecognitionService() =>
    _shared ??= createTesseractTextRecognitionService();

/// Creates the Tesseract recognizer: the bundled language catalog
/// ([bundle], default `rootBundle`), its data in the app-private
/// [supportDirectory] (default `getApplicationSupportDirectory()`: not
/// backed up, removed with the app), downloads through [httpClient]
/// (default: the current `NetworkSession`'s client at the time of each
/// request, so the proxy setting applies) and [isMeteredConnection]
/// (default [MeteredNetwork.isMetered]) for Wi-Fi-only downloads.
///
/// Nothing is loaded until the recognizer is first used; then leftovers of
/// interrupted installs are removed in the background. [isAvailable],
/// [engine] and [decoder] replace the platform's (tests).
TesseractTextRecognitionService createTesseractTextRecognitionService({
  AssetBundle? bundle,
  Future<Directory> Function() supportDirectory =
      getApplicationSupportDirectory,
  Future<bool> Function()? isMeteredConnection,
  http.Client? httpClient,
  bool? isAvailable,
  OcrEngine? engine,
  RgbaImageDecoder decoder = const UiRgbaImageDecoder(),
}) => TesseractTextRecognitionService(
  open: () async {
    final (catalog, support) = await (
      loadBundledTessdataCatalog(bundle: bundle),
      supportDirectory(),
    ).wait;
    final ocr = TesseractOcr(
      catalog: catalog,
      root: Directory(
        '${support.path}${Platform.pathSeparator}$textRecognitionFolder',
      ),
      httpClient: httpClient ?? CurrentSessionClient(),
      engine: engine,
      isAvailable: isAvailable,
    );
    unawaited(_cleanUp(ocr));
    return ocr;
  },
  isSupported: isAvailable ?? tesseractPlatformSupported,
  isMeteredConnection: isMeteredConnection ?? MeteredNetwork.instance.isMetered,
  decoder: decoder,
);

Future<void> _cleanUp(TesseractOcr ocr) async {
  try {
    await ocr.data.cleanUp();
    // coverage:ignore-start
  } on Object catch (error, stackTrace) {
    // cleanUp() already ignores file system errors; this is a safety net
    // so that a start-up chore can never become an uncaught error.
    log(
      'Text recognition clean-up failed',
      name: 'mozhi',
      error: error,
      stackTrace: stackTrace,
    );
  }
  // coverage:ignore-end
}
