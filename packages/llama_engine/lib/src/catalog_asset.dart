import 'package:flutter/services.dart';
import 'package:llama_engine/src/catalog.dart';

/// Loads the catalog bundled with this package (`assets/models.json`).
Future<LlamaModelCatalog> loadBundledLlamaCatalog({
  AssetBundle? bundle,
}) async => LlamaModelCatalog.parse(
  await (bundle ?? rootBundle).loadString(LlamaModelCatalog.assetKey),
);
