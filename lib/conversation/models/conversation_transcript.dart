import 'package:mozhi/conversation/models/conversation_turn.dart';

/// Formats a conversation as plain text for copying or sharing.
abstract final class ConversationTranscript {
  /// One block per turn, separated by blank lines:
  ///
  /// ```text
  /// [10:42] English: Hello, how are you?
  /// → Spanish: Hola, ¿cómo estás?
  /// ```
  ///
  /// The translation line is left out while it is still empty (failed or
  /// not started). [title], when given, is the first line followed by a
  /// blank line. [formatTime] renders each turn's time (e.g. with
  /// `MaterialLocalizations.formatTimeOfDay`); null leaves the time out.
  static String format(
    List<ConversationTurn> turns, {
    String? title,
    String Function(DateTime time)? formatTime,
  }) {
    final blocks = <String>[
      if (title != null && title.trim().isNotEmpty) title.trim(),
      for (final turn in turns) _turn(turn, formatTime),
    ];
    return blocks.join('\n\n');
  }

  static String _turn(
    ConversationTurn turn,
    String Function(DateTime time)? formatTime,
  ) {
    final time = formatTime == null ? '' : '[${formatTime(turn.createdAt)}] ';
    final translation = turn.translation.trim();
    return [
      '$time${turn.source.name}: ${turn.original.trim()}',
      if (translation.isNotEmpty) '→ ${turn.target.name}: $translation',
    ].join('\n');
  }
}
