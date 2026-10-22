/// Offline dictionary packs: a compact, versioned format (a front-coded,
/// sorted key index and gzip'd 64 KB blocks), its reader and writer, the
/// download catalogue, and the [OfflineDictionary] contract the app
/// implements with them. Pure Dart: works on Android and on the web.
library;

import 'package:translation_repository/src/dictionary_packs/offline_dictionary.dart';

export 'gzip.dart' show gzipDecode, gzipEncodeStored;
export 'key_folder.dart';
export 'offline_dictionary.dart';
export 'pack_answer.dart';
export 'pack_catalog.dart';
export 'pack_entry.dart';
export 'pack_header.dart';
export 'pack_reader.dart';
export 'pack_source.dart';
export 'pack_writer.dart';
export 'sha256.dart';
