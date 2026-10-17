import 'package:flutter/services.dart';
import 'package:tesseract_ocr/src/catalog.dart';

/// Loads the catalog bundled with this package (`assets/catalog.json`).
Future<TessdataCatalog> loadBundledTessdataCatalog({
  AssetBundle? bundle,
}) async => TessdataCatalog.parse(
  await (bundle ?? rootBundle).loadString(TessdataCatalog.assetKey),
);
