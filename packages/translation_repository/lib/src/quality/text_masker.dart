import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:translation_repository/src/quality/protected_patterns.dart';

/// Why a span of a text is protected.
enum ProtectedKind {
  /// Formatting that must come back unchanged (tags, entities, URLs,
  /// placeholders): masked for engines that might translate it, and sent
  /// unmasked again when an engine damages the masks.
  format,

  /// Personal data that must not leave the device (see `PersonalData`):
  /// never sent unmasked.
  personal,

  /// A glossary term (`TranslationOptions.glossary`) for an engine that
  /// cannot apply glossaries itself: masked so that the engine keeps it,
  /// and replaced by its rendering ([ProtectedSpan.replacement]) when
  /// restored. Never merged with other spans: one that overlaps another
  /// span is dropped.
  glossary,
}

/// A span of a text (`text.substring(start, end)`) that must not be
/// translated.
@immutable
class ProtectedSpan {
  const new(
    this.start,
    this.end, {
    this.kind = ProtectedKind.format,
    this.replacement,
  }) : assert(start <= end, 'start must not be after end');

  final int start;
  final int end;
  final ProtectedKind kind;

  /// What [MaskedText.restore] puts back instead of the span's own text
  /// (a glossary term's rendering), or null for the text itself.
  final String? replacement;

  bool get isPersonal => kind == ProtectedKind.personal;

  bool get isGlossary => kind == ProtectedKind.glossary;

  @override
  bool operator ==(Object other) =>
      other is ProtectedSpan &&
      other.start == start &&
      other.end == end &&
      other.kind == kind &&
      other.replacement == replacement;

  @override
  int get hashCode => Object.hash(start, end, kind, replacement);

  @override
  String toString() => 'ProtectedSpan($start-$end, ${kind.name})';
}

/// How masked spans are written for an engine.
enum MaskStyle {
  /// `⟨1⟩` tokens in plain text (Mozhi engines, LibreTranslate, AI
  /// models). Restored also when an engine adds spaces inside them or
  /// writes CJK angle brackets (`〈1〉`).
  brackets,

  /// `<x i="1"/>` elements with the rest of the text XML-escaped, for an
  /// engine that keeps XML tags (DeepL with `tag_handling=xml`). The output
  /// is unescaped while the tokens are put back.
  xml,
}

/// Replaces protected spans of a text by numbered tokens before it is sent
/// to an engine, and puts them back into the engine's output
/// ([MaskedText.restore]): the codec of the translate screen's placeholder
/// protection and of the personal data shield. Pure and cheap (one regular
/// expression pass each way).
abstract final class TextMasker {
  /// Most digits of a token number ([bracketToken] and [xmlToken] match
  /// that many): tokens are numbered from 1 to [maxTokenNumber].
  static const maxTokenDigits = 6;

  /// The highest token number (see [maxTokenDigits]).
  static const maxTokenNumber = 999999;

  /// `⟨n⟩` tokens as [MaskStyle.brackets] writes them, tolerating spaces
  /// and CJK angle brackets some engines substitute.
  static final bracketToken = RegExp(r'[⟨〈]\s*(\d{1,6})\s*[⟩〉]');

  /// `<x i="n"/>` tokens as [MaskStyle.xml] writes them (also
  /// `<x i="n"></x>`, single quotes and extra spaces).
  static final xmlToken = RegExp(
    r'''<x\s+i\s*=\s*["'](\d{1,6})["']\s*(?:/>|>\s*</x\s*>)''',
  );

  static final _xmlRestore = RegExp(
    '${xmlToken.pattern}'
    r'|&(?:lt|gt|amp|quot|apos|#\d{1,7}|#[xX][0-9A-Fa-f]{1,6});',
  );

  /// The token for span [number] in [style].
  static String token(int number, MaskStyle style) => switch (style) {
    MaskStyle.brackets => '⟨$number⟩',
    MaskStyle.xml => '<x i="$number"/>',
  };

  /// The spans of every match of [pattern] in [text] (empty matches are
  /// skipped).
  static List<ProtectedSpan> find(
    String text,
    RegExp pattern, {
    ProtectedKind kind = ProtectedKind.format,
  }) => [
    for (final match in pattern.allMatches(text))
      if (match.end > match.start)
        ProtectedSpan(match.start, match.end, kind: kind),
  ];

  /// The formatting of free text a machine translation engine should not
  /// see as text ([ProtectedPatterns.translation]: tags, entities, URLs,
  /// e-mail addresses, placeholders).
  static List<ProtectedSpan> formatSpans(String text) =>
      text.isEmpty ? const [] : find(text, ProtectedPatterns.translation);

  /// [spans] sorted and without overlaps: overlapping spans are merged into
  /// one, which is [ProtectedKind.personal] when one of them is (a URL with
  /// an e-mail address in it is kept on the device as a whole). A
  /// [ProtectedKind.glossary] span that overlaps another span is dropped
  /// instead (formatting and personal data win; of two glossary spans, the
  /// one that starts first, or the longer one).
  static List<ProtectedSpan> merge(Iterable<ProtectedSpan> spans) {
    final sorted = spans.where((s) => s.end > s.start).toList()
      ..sort((a, b) {
        final byStart = a.start.compareTo(b.start);
        return byStart != 0 ? byStart : b.end.compareTo(a.end);
      });
    final merged = <ProtectedSpan>[];
    for (final span in sorted) {
      final last = merged.lastOrNull;
      if (last == null || span.start >= last.end) {
        merged.add(span);
        continue;
      }
      if (span.isGlossary) continue;
      if (last.isGlossary) {
        // Nothing before the glossary span reaches into [span].
        merged[merged.length - 1] = span;
        continue;
      }
      merged[merged.length - 1] = ProtectedSpan(
        last.start,
        math.max(last.end, span.end),
        kind: last.isPersonal || span.isPersonal
            ? ProtectedKind.personal
            : ProtectedKind.format,
      );
    }
    return merged;
  }

  /// [text] with [spans] (see [merge]) replaced by tokens in [style].
  ///
  /// Identical values of the same kind share one token, so a repeated
  /// e-mail address is one item (the value of a span with a
  /// [ProtectedSpan.replacement] is that replacement). Token numbers start
  /// above any number a token-like sequence of [text] already uses, so the
  /// text's own `⟨1⟩` is left alone by [MaskedText.restore]; when that
  /// would go past [maxTokenNumber] (the text has `⟨999999⟩`), they take
  /// the lowest numbers the text does not use. With [MaskStyle.xml] the
  /// text between the tokens is XML-escaped.
  static MaskedText mask(
    String text,
    Iterable<ProtectedSpan> spans, {
    MaskStyle style = MaskStyle.brackets,
  }) {
    final merged = merge(spans);
    final first = _firstFreeNumber(text, merged.length);
    final values = <String>[];
    final originals = <String>[];
    final kinds = <ProtectedKind>[];
    final numbers = <(String, ProtectedKind), int>{};
    final buffer = StringBuffer();
    var last = 0;
    void plain(int end) {
      final part = text.substring(last, end);
      buffer.write(style == MaskStyle.xml ? escapeXml(part) : part);
    }

    for (final span in merged) {
      plain(span.start);
      final original = text.substring(span.start, span.end);
      final value = span.replacement ?? original;
      final number = numbers.putIfAbsent((value, span.kind), () {
        values.add(value);
        originals.add(original);
        kinds.add(span.kind);
        return first + values.length - 1;
      });
      buffer.write(token(number, style));
      last = span.end;
    }
    plain(text.length);
    return MaskedText._(
      text: merged.isEmpty && style == MaskStyle.brackets
          ? text
          : buffer.toString(),
      original: text,
      style: style,
      first: first,
      values: List.unmodifiable(values),
      originals: List.unmodifiable(originals),
      kinds: List.unmodifiable(kinds),
    );
  }

  /// `&`, `<` and `>` as XML entities.
  static String escapeXml(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  /// The first of [count] consecutive token numbers that [text] does not
  /// already use in a token-like sequence: the one above the highest it
  /// uses (1 when there is none) while all [count] stay within
  /// [maxTokenNumber], otherwise the start of the lowest free range.
  static int _firstFreeNumber(String text, int count) {
    final used = <int>{
      for (final pattern in [bracketToken, xmlToken])
        for (final match in pattern.allMatches(text))
          int.parse(match.group(1)!),
    };
    final highest = used.fold(0, math.max);
    if (highest + count <= maxTokenNumber) return highest + 1;
    var first = 1;
    for (final number in used.toList()..sort()) {
      if (number >= first + count) break;
      if (number >= first) first = number + 1;
    }
    return first;
  }
}

/// A text with its protected spans replaced by tokens ([TextMasker.mask]).
@immutable
class MaskedText {
  const new _({
    required this.text,
    required this.original,
    required this.style,
    required this.first,
    required this.values,
    required this.originals,
    required this.kinds,
  });

  /// What is sent to the engine.
  final String text;

  /// The text before masking.
  final String original;

  final MaskStyle style;

  /// The number of the first token.
  final int first;

  /// The masked values, by token number - [first]: what [restore] puts
  /// back (a glossary term's rendering for [ProtectedKind.glossary]).
  final List<String> values;

  /// The text each of [values] replaced (its first occurrence), by token
  /// number - [first]: the same as [values] except for glossary terms.
  final List<String> originals;

  /// The kind of each of [values].
  final List<ProtectedKind> kinds;

  /// Number of distinct masked values.
  int get count => values.length;

  /// Whether nothing was masked.
  bool get isEmpty => values.isEmpty;

  /// Number of distinct personal data values ([ProtectedKind.personal]).
  int get personalCount =>
      kinds.where((kind) => kind == ProtectedKind.personal).length;

  /// Number of distinct formatting values ([ProtectedKind.format]).
  int get formatCount =>
      kinds.where((kind) => kind == ProtectedKind.format).length;

  /// Number of distinct glossary renderings ([ProtectedKind.glossary]).
  int get glossaryCount =>
      kinds.where((kind) => kind == ProtectedKind.glossary).length;

  /// The value of token [number], or null when it is not one of these
  /// tokens.
  String? valueOf(int number) {
    final index = number - first;
    return index < 0 || index >= values.length ? null : values[index];
  }

  /// [output] (the engine's translation of [text]) with every token put
  /// back, in one pass: tokens the engine moved are restored where they
  /// are, repeated tokens each time, and a restored value is never scanned
  /// again (it may contain text that looks like a token). Token-like text
  /// with a number that is not one of these tokens is left as it is.
  /// [MaskStyle.xml] output is unescaped at the same time.
  ///
  /// A glossary rendering ([ProtectedKind.glossary]) written in lower case
  /// that the engine put at the start of a sentence starts with a capital
  /// letter there. With [original], every token gets the text it replaced
  /// ([originals]) instead, e.g. for a transliteration of the source text.
  RestoredText restore(String output, {bool original = false}) {
    final found = <int>{};
    final pattern = switch (style) {
      MaskStyle.brackets => TextMasker.bracketToken,
      MaskStyle.xml => TextMasker._xmlRestore,
    };
    if (isEmpty && style == MaskStyle.brackets) {
      return RestoredText._(text: output, missing: const {}, kinds: kinds);
    }
    final text = output.replaceAllMapped(pattern, (match) {
      final number = match.group(1);
      if (number == null) return _unescape(match.group(0)!);
      final value = valueOf(int.parse(number));
      if (value == null) return match.group(0)!;
      final index = int.parse(number) - first;
      found.add(index);
      if (original) return originals[index];
      return kinds[index] == ProtectedKind.glossary &&
              _startsSentence(output, match.start)
          ? _capitalized(value)
          : value;
    });
    return RestoredText._(
      text: text,
      missing: {
        for (var i = 0; i < values.length; i++)
          if (!found.contains(i)) i,
      },
      kinds: kinds,
    );
  }

  /// Whether [offset] of [text] starts a sentence: nothing but spaces (and
  /// opening quotes or brackets) before it since the start of the text, a
  /// line break or the end of a sentence.
  static bool _startsSentence(String text, int offset) {
    for (var i = offset - 1; i >= 0; i--) {
      final char = text[i];
      if (_sentencePrefix.contains(char)) continue;
      return _sentenceEnd.contains(char);
    }
    return true;
  }

  static const _sentencePrefix = ' \t\u00A0"\'“‘„«‹(¿¡';
  static const _sentenceEnd = '\n.!?…。！？';

  /// [value] with a capital first letter, when it is all lower case (a
  /// rendering such as `iPhone` stays as it is).
  static String _capitalized(String value) {
    if (value.isEmpty || value != value.toLowerCase()) return value;
    final first = String.fromCharCode(value.runes.first);
    return '${first.toUpperCase()}${value.substring(first.length)}';
  }

  static String _unescape(String entity) => switch (entity) {
    '&lt;' => '<',
    '&gt;' => '>',
    '&amp;' => '&',
    '&quot;' => '"',
    '&apos;' => "'",
    _ when entity.startsWith('&#x') || entity.startsWith('&#X') => _codePoint(
      int.tryParse(entity.substring(3, entity.length - 1), radix: 16),
      entity,
    ),
    _ => _codePoint(
      int.tryParse(entity.substring(2, entity.length - 1)),
      entity,
    ),
  };

  static String _codePoint(int? value, String fallback) =>
      value == null || value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF)
      ? fallback
      : String.fromCharCode(value);
}

/// An engine's output with the tokens of a [MaskedText] put back.
@immutable
class RestoredText {
  const new _({required this.text, required this.missing, required this.kinds});

  final String text;

  /// Indexes (into [MaskedText.values]) of the tokens that were not in the
  /// output: the engine lost or garbled them.
  final Set<int> missing;

  final List<ProtectedKind> kinds;

  /// Whether every token came back.
  bool get isComplete => missing.isEmpty;

  /// Whether a token of personal data is missing.
  bool get lostPersonalData =>
      missing.any((index) => kinds[index] == ProtectedKind.personal);
}
