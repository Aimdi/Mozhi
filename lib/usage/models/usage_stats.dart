import 'package:equatable/equatable.dart';
import 'package:mozhi/usage/token_estimate.dart';

/// Usage of one AI provider in one month.
///
/// Characters are Unicode code points. Tokens are estimates (see
/// [estimateTokens]); providers bill by their own tokenizer.
class UsageStats extends Equatable {
  const UsageStats({
    this.requests = 0,
    this.inputChars = 0,
    this.outputChars = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
  });

  /// Tolerant counterpart of [toJson]: missing or invalid counters become 0,
  /// negative ones are clamped to 0, and missing token counts are estimated
  /// from the character counts.
  factory UsageStats.fromJson(Map<String, dynamic> json) {
    final inputChars = _count(json['inputChars']);
    final outputChars = _count(json['outputChars']);
    return UsageStats(
      requests: _count(json['requests']),
      inputChars: inputChars,
      outputChars: outputChars,
      inputTokens: json['inputTokens'] is num
          ? _count(json['inputTokens'])
          : estimateTokensForChars(inputChars),
      outputTokens: json['outputTokens'] is num
          ? _count(json['outputTokens'])
          : estimateTokensForChars(outputChars),
    );
  }

  static const zero = UsageStats();

  final int requests;

  /// Characters sent to the provider (source text, not the prompt wrapper).
  final int inputChars;

  /// Characters received from the provider.
  final int outputChars;

  /// Estimated tokens of [inputChars].
  final int inputTokens;

  /// Estimated tokens of [outputChars].
  final int outputTokens;

  int get totalChars => inputChars + outputChars;

  /// Estimated input + output tokens.
  int get estimatedTokens => inputTokens + outputTokens;

  bool get isEmpty => requests == 0 && totalChars == 0 && estimatedTokens == 0;

  UsageStats operator +(UsageStats other) => UsageStats(
    requests: requests + other.requests,
    inputChars: inputChars + other.inputChars,
    outputChars: outputChars + other.outputChars,
    inputTokens: inputTokens + other.inputTokens,
    outputTokens: outputTokens + other.outputTokens,
  );

  Map<String, dynamic> toJson() => {
    'requests': requests,
    'inputChars': inputChars,
    'outputChars': outputChars,
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
  };

  static int _count(Object? value) =>
      value is num && value.isFinite && value > 0 ? value.toInt() : 0;

  @override
  List<Object?> get props => [
    requests,
    inputChars,
    outputChars,
    inputTokens,
    outputTokens,
  ];
}
