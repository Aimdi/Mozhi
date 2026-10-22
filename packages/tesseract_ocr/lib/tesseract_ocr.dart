/// On-device text recognition for Mozhi with the open-source Tesseract
/// engine (LSTM) and its tessdata_fast language data (no Google services):
/// language catalog, verified downloads and imports, and the native engine
/// in a background isolate. Safe to import on every platform (the native
/// code is only used where `dart:ffi` exists).
library;

export 'src/catalog.dart';
export 'src/catalog_asset.dart';
export 'src/engine/engine_factory.dart';
export 'src/engine/ocr_engine.dart';
export 'src/engine/ocr_layout.dart';
export 'src/model_manager.dart';
export 'src/tesseract_ocr.dart';
