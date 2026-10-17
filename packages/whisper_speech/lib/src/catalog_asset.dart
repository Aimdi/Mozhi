import 'package:flutter/services.dart';
import 'package:whisper_speech/src/catalog.dart';

/// Loads the catalog bundled with this package (`assets/models.json`).
Future<WhisperModelCatalog> loadBundledWhisperCatalog({
  AssetBundle? bundle,
}) async => WhisperModelCatalog.parse(
  await (bundle ?? rootBundle).loadString(WhisperModelCatalog.assetKey),
);
