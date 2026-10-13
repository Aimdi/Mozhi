import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';

/// Asserts that [document] reproduces [original] exactly, both untranslated
/// and when every segment is "translated" to itself.
void expectRoundTrip(ParsedDocument document, String original) {
  expect(document.render(), original, reason: 'render() without translations');
  expect(
    document.render([for (final segment in document.segments) segment.text]),
    original,
    reason: 'render() with identity translations',
  );
  for (var i = 0; i < document.segments.length; i++) {
    final text = document.segments[i].text;
    expect(text, text.trim(), reason: 'segment $i is trimmed');
    expect(text.isNotEmpty, isTrue, reason: 'segment $i is not empty');
  }
}

/// Segment texts of [document].
List<String> texts(ParsedDocument document) => [
  for (final segment in document.segments) segment.text,
];

/// "Translates" every segment by upper-casing it (placeholders survive).
String renderUpper(ParsedDocument document) => document.render([
  for (final segment in document.segments) segment.text.toUpperCase(),
]);
