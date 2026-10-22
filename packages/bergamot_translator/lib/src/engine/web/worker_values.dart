// Internal: not exported by the package.

/// Reads JSON-like worker results, which a browser may hand over as `num`
/// where Dart expects an `int`.
extension WorkerValues on Object? {
  /// This value as a map with String keys, or empty.
  Map<String, Object?> get asMap => switch (this) {
    final Map<Object?, Object?> map => {
      for (final MapEntry(:key, :value) in map.entries) '$key': value,
    },
    _ => const {},
  };

  /// This value as a list, or empty.
  List<Object?> get asList => switch (this) {
    final List<Object?> list => list,
    _ => const [],
  };

  /// This value as an int, or [fallback].
  int asInt([int fallback = 0]) => switch (this) {
    final num value when value.isFinite => value.toInt(),
    _ => fallback,
  };

  /// This value as a String, or [fallback].
  String asString([String fallback = '']) => switch (this) {
    final String value => value,
    _ => fallback,
  };

  /// This value as a bool (false unless true).
  bool get asBool => this == true;
}
