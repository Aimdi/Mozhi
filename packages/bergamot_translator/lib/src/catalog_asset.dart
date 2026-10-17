import 'package:bergamot_translator/src/catalog.dart';
import 'package:flutter/services.dart';

/// Loads the catalog bundled with this package (`assets/catalog.json`).
Future<ModelCatalog> loadBundledCatalog({AssetBundle? bundle}) async =>
    ModelCatalog.parse(
      await (bundle ?? rootBundle).loadString(ModelCatalog.assetKey),
    );
