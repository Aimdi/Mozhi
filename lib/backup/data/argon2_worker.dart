// Off-main-thread Argon2id in the web app: runs `web/backup/argon2_worker.js`
// in a dedicated Web Worker (returning null outside a browser or when the
// worker cannot run, so `BackupCodec` falls back to inline `DartArgon2id`).
export 'argon2_worker_stub.dart'
    if (dart.library.js_interop) 'argon2_worker_web.dart';
