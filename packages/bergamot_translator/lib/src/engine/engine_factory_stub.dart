import 'package:bergamot_translator/src/engine/bergamot_engine.dart';
import 'package:bergamot_translator/src/model_manager.dart';
import 'package:bergamot_translator/src/native_language_identifier.dart';

/// Whether the native engine can run here: never on the web.
bool get bergamotPlatformSupported => false;

/// An engine that is not available on this platform.
BergamotEngine createBergamotEngine({
  String? libraryPath,
  int maxLoadedModels = 3,
}) => const UnsupportedBergamotEngine();

/// No native language identifier on this platform.
NativeLanguageIdentifier createNativeLanguageIdentifier({
  String? libraryPath,
}) => const UnsupportedNativeLanguageIdentifier();

/// The engine on platforms without `dart:ffi` (web): every call fails.
final class UnsupportedBergamotEngine implements BergamotEngine {
  const new();

  @override
  Future<String> translate(
    List<ModelPaths> chain,
    String text, {
    bool html = false,
  }) => Future.error(
    UnsupportedError('Offline translation is not available on the web'),
  );

  @override
  Future<void> release(String key) async {}

  @override
  Future<void> dispose() async {}
}

/// The language identifier on platforms without `dart:ffi` (web): there is
/// none, so callers use the `LanguageIdentifier` heuristic.
final class UnsupportedNativeLanguageIdentifier
    implements NativeLanguageIdentifier {
  const new();

  @override
  Future<Cld2Detection?> identify(
    String text, {
    List<String> hints = const [],
  }) async => null;
}
