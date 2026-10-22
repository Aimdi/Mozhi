import 'dart:async';

import 'package:collection/collection.dart';
import 'package:mt_api/mt_api.dart';

/// The DeepL glossaries the app creates from `TranslationOptions.glossary`:
/// one per (glossary, language pair), named after a hash of the entries
/// ([nameFor]), so that it is found again after a restart without storing
/// anything on the device.
///
/// [idFor] reuses a glossary of that name (listed once per connection and
/// session), else creates it; creating one deletes the app's glossaries of
/// the same pair that were made from other entries (stale after the user
/// edited the glossary). Failures (an unsupported pair, a full glossary
/// quota, invalid terms) give null: the text is translated without a
/// glossary, and that combination is not tried again this session.
class DeeplGlossaries {
  /// Prefix of the names of the glossaries the app creates.
  static const namePrefix = 'mozhi-';

  final Map<(String, String), Future<String?>> _ids = {};
  final Map<String, Future<List<DeeplGlossary>>> _lists = {};

  /// The glossary name for [entries] between [source] and [target]
  /// (glossary language codes, see `DeeplClient.glossaryLanguage`):
  /// `mozhi-<hash>-<source>-<target>`.
  static String nameFor(
    Map<String, String> entries, {
    required String source,
    required String target,
  }) => '$namePrefix${hashOf(entries)}-$source-$target';

  /// A stable hash of [entries] (independent of their order; the same on
  /// every platform), as 14 hex digits.
  static String hashOf(Map<String, String> entries) {
    final keys = entries.keys.toList()..sort();
    var a = 7;
    var b = 11;
    for (final key in keys) {
      for (final unit in '$key\t${entries[key]}\n'.codeUnits) {
        a = (a * 131 + unit) % 2147483629;
        b = (b * 257 + unit) % 1000000007;
      }
    }
    return '${a.toRadixString(16).padLeft(8, '0')}'
        '${(b % 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  }

  /// What `DeeplClient.glossaryTsv` rejects in a term: control characters
  /// and line or paragraph separators.
  static final _forbidden = RegExp(r'[\x00-\x1F\x7F-\x9F\u2028\u2029]');

  /// [glossary] without entries DeepL would reject (empty terms, tabs, line
  /// breaks or other control characters), trimmed.
  static Map<String, String> validEntries(Map<String, String> glossary) {
    final valid = <String, String>{};
    for (final MapEntry(:key, :value) in glossary.entries) {
      final term = key.trim();
      final target = value.trim();
      if (term.isEmpty ||
          target.isEmpty ||
          _forbidden.hasMatch(term) ||
          _forbidden.hasMatch(target)) {
        continue;
      }
      valid[term] = target;
    }
    return valid;
  }

  /// The id of the glossary of [entries] (valid, see [validEntries]) for
  /// [sourceLanguage] > [targetLanguage] (app or DeepL codes) on
  /// [connection] (the provider's connection key), or null when there is
  /// none and it cannot be created.
  Future<String?> idFor(
    DeeplClient client, {
    required String connection,
    required String sourceLanguage,
    required String targetLanguage,
    required Map<String, String> entries,
  }) {
    final source = DeeplClient.glossaryLanguage(sourceLanguage);
    final target = DeeplClient.glossaryLanguage(targetLanguage);
    if (entries.isEmpty || source == target) return Future.value();
    final name = nameFor(entries, source: source, target: target);
    return _ids[(connection, name)] ??= _resolve(
      client,
      connection: connection,
      name: name,
      source: source,
      target: target,
      entries: entries,
    );
  }

  Future<String?> _resolve(
    DeeplClient client, {
    required String connection,
    required String name,
    required String source,
    required String target,
    required Map<String, String> entries,
  }) async {
    try {
      final existing = await (_lists[connection] ??= client.listGlossaries());
      final match = existing.firstWhereOrNull(
        (glossary) =>
            glossary.name == name &&
            glossary.sourceLang.toLowerCase() == source &&
            glossary.targetLang.toLowerCase() == target,
      );
      if (match != null) return match.id;
      final created = await client.createGlossary(
        name: name,
        sourceLang: source,
        targetLang: target,
        entries: entries,
      );
      for (final glossary in existing) {
        if (glossary.name.startsWith(namePrefix) &&
            glossary.name != name &&
            glossary.sourceLang.toLowerCase() == source &&
            glossary.targetLang.toLowerCase() == target) {
          unawaited(client.deleteGlossary(glossary.id).catchError((_) {}));
        }
      }
      return created.id;
    } on Object {
      _lists.removeWhere((key, _) => key == connection);
      return null;
    }
  }

  /// Forgets every glossary id and list (e.g. after the connection
  /// changed).
  void clear() {
    _ids.clear();
    _lists.clear();
  }
}
