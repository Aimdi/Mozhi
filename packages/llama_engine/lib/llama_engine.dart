/// On-device AI for Mozhi with llama.cpp (no Google services): a model
/// catalogue, verified downloads and imports, and an engine running in a
/// background isolate. Safe to import on every platform (the native code
/// is only used where `dart:ffi` exists).
library;

// The model catalogue, its sources and the model manager (W5-B).
export 'src/catalog.dart';
export 'src/catalog_asset.dart';
export 'src/engine/engine_factory.dart';
export 'src/engine/llama_engine.dart';
export 'src/model_manager.dart';
export 'src/model_source.dart';
