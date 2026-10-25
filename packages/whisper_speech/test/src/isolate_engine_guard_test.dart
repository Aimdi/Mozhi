// The CPU variant guard of the engine isolates with the real engine
// (libmozhi_whisper.so from tool/build_native_linux.sh) standing in for a
// guarded variant. Skipped when the library is not built.
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper_speech/src/engine/cpu_variant_guard.dart';
import 'package:whisper_speech/src/engine/ffi/isolate_engine.dart';
import 'package:whisper_speech/whisper_speech.dart';

import '../helpers/native_library.dart';

const _vadModel = 'for-tests-silero-v6.2.0-ggml.bin';

void main() {
  group('guarded engine isolates', skip: nativeLibrarySkip(), () {
    late Directory root;
    late String library;

    setUp(() {
      root = Directory.systemTemp.createTempSync('whisper_iso_guard_');
      library = nativeLibraryPath()!;
    });
    tearDown(() => root.deleteSync(recursive: true));

    CpuVariantGuard guard() => CpuVariantGuard(
      directory: root.path,
      variants: {library},
      processId: 1,
    );

    List<String> markers() => [
      for (final entry in root.listSync())
        if (entry.path.endsWith('.marker')) p.basename(entry.path),
    ];

    test('a first transcription verifies the library', () async {
      final path = library;
      final engine = IsolateWhisperEngine(
        resolveLibrary: (_) => path,
        variantGuard: guard(),
      );
      addTearDown(engine.dispose);
      await engine.transcribe(testModelPath()!, Float32List(16000));
      expect(markers(), isEmpty);
      expect(guard().read().verified.keys, [library]);
      expect(guard().needsCheck(library), isFalse);
      // Verified: later ones write no marker.
      await engine.transcribe(testModelPath()!, Float32List(16000));
      expect(markers(), isEmpty);
    });

    test('a first detection verifies it too, a failure does not', () async {
      final path = library;
      final engine = IsolateWhisperVadEngine(
        resolveLibrary: (_) => path,
        variantGuard: guard(),
      );
      addTearDown(engine.dispose);
      // Not a VAD model: an engine error, no crash.
      await expectLater(
        engine.detect(testModelPath()!, Float32List(512)),
        throwsA(isA<WhisperEngineException>()),
      );
      expect(markers(), isEmpty);
      expect(guard().read().verified, isEmpty);

      final vad = testModelPath(_vadModel);
      if (vad == null) return;
      await engine.detect(vad, Float32List(512));
      expect(markers(), isEmpty);
      expect(guard().read().verified.keys, [library]);
    });
  });
}
