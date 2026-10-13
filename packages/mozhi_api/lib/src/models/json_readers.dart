/// Lenient readers for JSON produced by Mozhi's Go structs.
///
/// Go serialises nil slices and maps as `null`, engines leave fields unset,
/// and older instances omit newer keys, so every reader maps a missing,
/// `null` or wrongly typed value to an empty one instead of throwing.
library;

String readString(Object? value) => value is String ? value : '';

List<String> readStringList(Object? value) =>
    value is List ? List.unmodifiable(value.whereType<String>()) : const [];

/// Reads a JSON object of string arrays (Go `map[string][]string`).
Map<String, List<String>> readStringListMap(Object? value) => value is Map
    ? Map.unmodifiable({
        for (final MapEntry(:key, :value) in value.entries)
          if (key is String) key: readStringList(value),
      })
    : const {};

/// Reads a JSON array of objects, skipping elements that are not objects.
List<T> readObjectList<T>(
  Object? value,
  T Function(Map<String, dynamic> json) fromJson,
) => value is List
    ? List.unmodifiable(value.whereType<Map<String, dynamic>>().map(fromJson))
    : const [];
