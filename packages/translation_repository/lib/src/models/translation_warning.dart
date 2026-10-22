import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// What a [TranslationWarning] is about (see `TranslationQa`).
enum TranslationWarningKind {
  /// Placeholders (`%s`, `{name}`, `{{name}}`, `${name}`, masked `⟨1⟩`
  /// tokens) of the input are missing or changed in the output.
  placeholders,

  /// HTML/XML tags or entities of the input are missing or changed.
  markup,

  /// URLs of the input are missing or changed.
  links,

  /// E-mail addresses of the input are missing or changed.
  emails,

  /// Numbers (digit sequences) of the input are missing or changed.
  numbers,

  /// Required glossary targets (`TranslationOptions.glossary`) of source
  /// terms in the input do not appear in the output.
  glossary,

  /// The output is the input, although the input is not in the target
  /// language.
  echo,

  /// The output is not written in the target language (wrong script, or
  /// still in the source language).
  wrongLanguage,

  /// The output is far shorter or longer than a translation would be
  /// (truncated, or garbage).
  length,

  /// An AI model answered, commented or chatted instead of translating
  /// (prompt injection, "Sure! Here is...").
  notATranslation,

  /// Personal data that was kept on the device (see
  /// `TranslationResult.maskedPersonalData`) could not all be put back: the
  /// engine lost some of its placeholders.
  personalDataLost;

  /// Whether a result with this warning is suspect: it is probably not a
  /// translation at all, so another engine should be tried.
  bool get isSuspect => switch (this) {
    echo || wrongLanguage || length || notATranslation => true,
    _ => false,
  };
}

/// A problem the checks after a translation found (see `TranslationQa`).
@immutable
class TranslationWarning {
  const new(this.kind, {this.items = const []});

  final TranslationWarningKind kind;

  /// The affected parts of the input (missing placeholders, links, numbers,
  /// glossary targets), at most a few; empty for the other kinds. They come
  /// from the user's text: show them, never log them.
  final List<String> items;

  /// Whether this warning makes the result suspect
  /// ([TranslationWarningKind.isSuspect]).
  bool get isSuspect => kind.isSuspect;

  static const _list = ListEquality<String>();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TranslationWarning &&
          other.kind == kind &&
          _list.equals(other.items, items);

  @override
  int get hashCode => Object.hash(kind, _list.hash(items));

  @override
  String toString() =>
      'TranslationWarning(${kind.name}'
      '${items.isEmpty ? '' : ', ${items.length} items'})';
}
