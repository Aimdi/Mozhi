import 'dart:typed_data';

/// Not a browser: Argon2id runs in a Dart isolate (or inline in tests)
/// instead of a Web Worker.
Future<Uint8List?> deriveArgon2idInWorker({
  required List<int> passphraseBytes,
  required Uint8List saltBytes,
  required int memoryKiB,
  required int iterations,
  required int parallelism,
  required int hashLength,
}) async => null;
