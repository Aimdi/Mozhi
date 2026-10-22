// gzip for backups: dart:io's codec on Android (and in tests), the
// browser's CompressionStream in the web app (Chrome 80+, Firefox 113+,
// Safari 16.4+). Both write and read standard gzip, so a backup made in
// one opens in the other.
export 'backup_gzip_io.dart'
    if (dart.library.js_interop) 'backup_gzip_web.dart';
