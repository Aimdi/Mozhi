import 'dart:async';
import 'dart:convert';

/// Decodes newline-delimited JSON (one JSON value per line) as used by the
/// Ollama native API.
///
/// The input is decoded text in chunks of any size. Blank lines are
/// skipped; a line that is not valid JSON is reported as a
/// [FormatException] error event.
class NdjsonDecoder extends StreamTransformerBase<String, Object?> {
  const new();

  @override
  Stream<Object?> bind(Stream<String> stream) => stream
      .transform(const LineSplitter())
      .where((line) => line.trim().isNotEmpty)
      .map(jsonDecode);
}
