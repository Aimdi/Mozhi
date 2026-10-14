import 'package:meta/meta.dart';

/// A pair of corresponding phrases in a text and its translation, as
/// character ranges (UTF-16 code unit offsets, like [String.substring]):
/// `source.substring(sourceStart, sourceEnd)` corresponds to
/// `translation.substring(targetStart, targetEnd)`.
///
/// Starts are inclusive, ends exclusive. Produced by
/// `TranslationRepository.align` so the UI can highlight a phrase and its
/// counterpart together.
@immutable
class AlignedSpan {
  const new({
    required this.sourceStart,
    required this.sourceEnd,
    required this.targetStart,
    required this.targetEnd,
  });

  /// Reads the [toJson] keys; also accepts snake_case keys
  /// (`source_start`, ...). Throws a [FormatException] when an offset is
  /// missing, not an integer, negative, or an end lies before its start.
  factory fromJson(Map<String, dynamic> json) {
    int offset(String key, String snake) {
      final value = json[key] ?? json[snake];
      if (value is int && value >= 0) return value;
      if (value is num && value >= 0 && value == value.truncate()) {
        return value.toInt();
      }
      throw FormatException('Invalid AlignedSpan.$key', value);
    }

    final span = AlignedSpan(
      sourceStart: offset('sourceStart', 'source_start'),
      sourceEnd: offset('sourceEnd', 'source_end'),
      targetStart: offset('targetStart', 'target_start'),
      targetEnd: offset('targetEnd', 'target_end'),
    );
    if (span.sourceEnd < span.sourceStart ||
        span.targetEnd < span.targetStart) {
      throw FormatException('AlignedSpan ends before it starts', json);
    }
    return span;
  }

  /// Start of the phrase in the source text (inclusive).
  final int sourceStart;

  /// End of the phrase in the source text (exclusive).
  final int sourceEnd;

  /// Start of the corresponding phrase in the translation (inclusive).
  final int targetStart;

  /// End of the corresponding phrase in the translation (exclusive).
  final int targetEnd;

  /// The phrase in [source] (the text this span was computed for).
  String sourceIn(String source) => source.substring(sourceStart, sourceEnd);

  /// The phrase in [translation] (the text this span was computed for).
  String targetIn(String translation) =>
      translation.substring(targetStart, targetEnd);

  /// Whether the source phrase covers the character at [offset].
  bool coversSource(int offset) => offset >= sourceStart && offset < sourceEnd;

  /// Whether the target phrase covers the character at [offset].
  bool coversTarget(int offset) => offset >= targetStart && offset < targetEnd;

  Map<String, dynamic> toJson() => {
    'sourceStart': sourceStart,
    'sourceEnd': sourceEnd,
    'targetStart': targetStart,
    'targetEnd': targetEnd,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AlignedSpan &&
          other.sourceStart == sourceStart &&
          other.sourceEnd == sourceEnd &&
          other.targetStart == targetStart &&
          other.targetEnd == targetEnd;

  @override
  int get hashCode =>
      Object.hash(sourceStart, sourceEnd, targetStart, targetEnd);

  @override
  String toString() =>
      'AlignedSpan($sourceStart-$sourceEnd -> $targetStart-$targetEnd)';
}
