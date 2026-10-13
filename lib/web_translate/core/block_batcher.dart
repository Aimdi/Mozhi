/// Groups texts into translation requests and splits the results again.
library;

import 'package:equatable/equatable.dart';

/// A text to translate, identified by [id].
class TranslationItem extends Equatable {
  const TranslationItem(this.id, this.text);

  final int id;
  final String text;

  @override
  List<Object?> get props => [id, text];
}

/// Packs [TranslationItem]s into batches that are sent as one request,
/// separated by blank lines (which translators keep as paragraph breaks).
class BlockBatcher {
  const BlockBatcher({this.maxChars = 1800, this.maxItems = 12});

  /// Soft limit of characters per batch (a longer item is sent alone).
  final int maxChars;

  /// Maximum items per batch.
  final int maxItems;

  /// Separator between the items of a batch.
  static const separator = '\n\n';

  /// Greedily groups consecutive [items], preserving their order.
  List<List<TranslationItem>> batch(Iterable<TranslationItem> items) {
    final batches = <List<TranslationItem>>[];
    var current = <TranslationItem>[];
    var chars = 0;
    for (final item in items) {
      final added = (current.isEmpty ? 0 : separator.length) + item.text.length;
      if (current.isNotEmpty &&
          (chars + added > maxChars || current.length >= maxItems)) {
        batches.add(current);
        current = [];
        chars = 0;
      }
      chars += current.isEmpty ? item.text.length : added;
      current.add(item);
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
  }

  /// The request text of [batch].
  static String join(List<TranslationItem> batch) =>
      batch.map((item) => item.text).join(separator);

  /// Splits a translated batch into [expected] parts at blank lines; null
  /// when the translator merged or split paragraphs (the caller then
  /// translates the items one by one).
  static List<String>? split(String translated, int expected) {
    final parts = translated
        .trim()
        .split(_blankLines)
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    return parts.length == expected ? parts : null;
  }

  static final _blankLines = RegExp(r'\n[ \t\r]*\n[\s]*');
}
