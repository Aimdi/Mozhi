/// Lenient readers for API JSON: a missing, `null` or wrongly typed value
/// becomes an empty/default one instead of throwing.
library;

import 'package:meta/meta.dart';

@internal
String readString(Object? value) => value is String ? value : '';

@internal
String? readOptionalString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

@internal
int readInt(Object? value) => value is num ? value.toInt() : 0;

@internal
double readDouble(Object? value) => value is num ? value.toDouble() : 0;

@internal
bool readBool(Object? value) => value == true;

@internal
List<String> readStringList(Object? value) =>
    value is List ? List.unmodifiable(value.whereType<String>()) : const [];

@internal
DateTime? readDateTime(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

/// Element-wise equality of two lists.
@internal
bool listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
