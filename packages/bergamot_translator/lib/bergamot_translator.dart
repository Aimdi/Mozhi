/// Offline on-device translation for Mozhi with Mozilla's open Firefox
/// Translations (Bergamot) models: model catalog, verified downloads, and
/// an [OfflineTranslator] running the native engine and its CLD2 language
/// identifier in background isolates. Safe to import on every platform
/// (the native code is only used where `dart:ffi` exists).
library;

import 'package:translation_repository/translation_repository.dart'
    show OfflineTranslator;

export 'src/bergamot_translator.dart';
export 'src/catalog.dart';
export 'src/catalog_asset.dart';
export 'src/engine/bergamot_engine.dart';
export 'src/engine/engine_factory.dart';
export 'src/language_identifier.dart';
export 'src/model_manager.dart';
export 'src/model_router.dart';
export 'src/native_language_identifier.dart';
export 'src/text_chunker.dart';
