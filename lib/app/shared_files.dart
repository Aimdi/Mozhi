import 'package:flutter/foundation.dart';
import 'package:mozhi/app/shared_files_io.dart'
    if (dart.library.js_interop) 'package:mozhi/app/shared_files_web.dart'
    as platform;

/// A file another app shared with Mozhi.
@immutable
class SharedFile {
  const new({required this.name, required this.bytes, this.path});

  /// The file's name as the sharing app gave it (cleaned up), for display
  /// and to tell its format.
  final String name;
  final Uint8List bytes;

  /// Where it is stored while the app uses it (images, for on-device text
  /// recognition); null once it has been deleted.
  final String? path;

  @override
  String toString() => 'SharedFile($name, ${bytes.length} bytes)';
}

/// Files shared from other apps (Android `ACTION_SEND` with a stream,
/// `ShareReceiverActivity.kt`): the platform copies each one into the
/// app's cache, `<cache>/[folder]/<token>/<name>`, and opens
/// `/image?shared=<token>` (images) or `/documents?shared=<token>`
/// (subtitles, text, Markdown, JSON). The screen then takes it from here
/// ([take]); nothing is sent anywhere because a file was shared.
///
/// Tokens are 32 lower-case hex digits ([isToken]); anything else, as in a
/// `mozhi://` link made up by another app, is ignored, and a token only
/// finds a file the platform stored for this app.
///
/// A file the platform could not store (too large, unreadable) has a token
/// too, with no file, and says why ([errorParameter], [SharedFileError])
/// and what its name was ([nameParameter]). When more than one item was
/// shared at once, only the first is opened and [countParameter] says how
/// many there were.
abstract final class SharedFiles {
  /// The query parameter of the token.
  static const parameter = 'shared';

  /// The query parameter of why the shared file is missing
  /// ([SharedFileError.value]).
  static const errorParameter = 'shared_error';

  /// The query parameter of the missing file's name.
  static const nameParameter = 'name';

  /// The query parameter of the number of items shared at once.
  static const countParameter = 'shared_count';

  /// Whether [query] (of a shared file's link) says that more than one item
  /// was shared ([countParameter]).
  static bool sharedSeveral(Map<String, String> query) =>
      (int.tryParse(query[countParameter] ?? '') ?? 1) > 1;

  /// The cache folder of the shared files.
  static const folder = 'shared_files';

  /// How long an unopened shared file is kept.
  static const maxAge = Duration(hours: 1);

  /// Largest file read (larger ones are not read at all).
  static const int maxBytes = 40 * 1024 * 1024;

  static final _token = RegExp(r'^[0-9a-f]{32}$');

  /// Whether [value] is a well-formed token.
  static bool isToken(String? value) => value != null && _token.hasMatch(value);

  /// The file of [token], or null (an unknown or malformed token, no file
  /// support on this platform). With [keep] (images: on-device text
  /// recognition reads the file) it stays, until a later [take] finds it
  /// older than [maxAge]; otherwise it is deleted once read. Shared files
  /// older than [maxAge] are deleted on the way. [cacheDirectory] replaces
  /// the app's cache directory and [clock] the time (tests).
  static Future<SharedFile?> take(
    String? token, {
    bool keep = false,
    Future<String> Function()? cacheDirectory,
    DateTime Function()? clock,
  }) async {
    if (!isToken(token)) return null;
    try {
      return await platform.takeSharedFile(
        token!,
        keep: keep,
        cacheDirectory: cacheDirectory,
        now: (clock ?? DateTime.now)(),
      );
    } on Object {
      // Unreadable: as if nothing was shared.
      return null;
    }
  }
}

/// Why a shared file could not be opened ([SharedFiles.errorParameter]).
enum SharedFileError {
  /// Larger than the screen opens (Android copies no more than that).
  tooLarge('too_large'),

  /// The sharing app's file could not be read.
  unreadable('unreadable');

  new(this.value);

  /// Its value in the link.
  final String value;

  /// The error of [value], or null (none, or one this version does not
  /// know).
  static SharedFileError? tryParse(String? value) {
    for (final error in values) {
      if (error.value == value) return error;
    }
    return null;
  }
}
