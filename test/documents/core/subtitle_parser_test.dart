import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';

import '../helpers/document_helpers.dart';

void main() {
  group('parseSubtitles (SRT)', () {
    const srt =
        '1\n'
        '00:00:01,000 --> 00:00:02,500\n'
        'Hello there.\n'
        '\n'
        '2\n'
        '00:00:03,000 --> 00:00:05,000 X1:100 X2:200 Y1:10 Y2:20\n'
        '<i>Two lines,</i>\n'
        '{\\an8}second line.\n'
        '\n';

    test('translates cue text only', () {
      final document = parseSubtitles(srt, DocumentFormat.srt);
      expect(document.format, DocumentFormat.srt);
      expect(texts(document), [
        'Hello there.',
        '⟨1⟩Two lines,⟨2⟩\n⟨3⟩second line.',
      ]);
      expect(document.segments.map((Segment s) => s.label), ['1', '2']);
      expectRoundTrip(document, srt);
    });

    test('renders translations into the cue layout', () {
      final document = parseSubtitles(srt, DocumentFormat.srt);
      expect(
        document.render(['Hola.', '⟨1⟩Dos líneas,⟨2⟩\n⟨3⟩segunda línea.']),
        '1\n'
        '00:00:01,000 --> 00:00:02,500\n'
        'Hola.\n'
        '\n'
        '2\n'
        '00:00:03,000 --> 00:00:05,000 X1:100 X2:200 Y1:10 Y2:20\n'
        '<i>Dos líneas,</i>\n'
        '{\\an8}segunda línea.\n'
        '\n',
      );
    });

    test('bilingual export keeps the original above the translation', () {
      final document = parseSubtitles(srt, DocumentFormat.srt);
      final output = document.renderBilingual(['Hola.', null]);
      expect(output, startsWith('1\n00:00:01,000 --> 00:00:02,500\n'));
      expect(output, contains('Hello there.\nHola.\n\n2\n'));
      expect(output, contains('<i>Two lines,</i>\n{\\an8}second line.\n\n'));
    });

    test('identity translations do not duplicate bilingual lines', () {
      final document = parseSubtitles(srt, DocumentFormat.srt);
      expect(document.renderBilingual(texts(document)), srt);
    });

    test('handles CRLF, a BOM-less last cue without newline', () {
      const text =
          '1\r\n00:00:01,000 --> 00:00:02,000\r\nFirst\r\n\r\n'
          '2\r\n00:00:02,000 --> 00:00:03,000\r\nLast\r\nline';
      final document = parseSubtitles(text, DocumentFormat.srt);
      expect(texts(document), ['First', 'Last\nline']);
      expectRoundTrip(document, text);
      expect(
        document.render(['Erste', 'Letzte\nZeile']),
        '1\r\n00:00:01,000 --> 00:00:02,000\r\nErste\r\n\r\n'
        '2\r\n00:00:02,000 --> 00:00:03,000\r\nLetzte\r\nZeile',
      );
    });

    test('splits cues that lack blank separator lines', () {
      const text =
          '1\n00:00:01,000 --> 00:00:02,000\nOne\n'
          '2\n00:00:02,000 --> 00:00:03,000\nTwo\n';
      final document = parseSubtitles(text, DocumentFormat.srt);
      expect(texts(document), ['One', 'Two']);
      expectRoundTrip(document, text);
      expect(
        renderUpper(document),
        '1\n00:00:01,000 --> 00:00:02,000\nONE\n'
        '2\n00:00:02,000 --> 00:00:03,000\nTWO\n',
      );
    });

    test('keeps cues without text and blocks without timing', () {
      const text =
          'garbage block\n\n'
          '1\n00:00:01,000 --> 00:00:02,000\n\n'
          '2\n00:00:02,000 --> 00:00:03,000\n♪ ♪\n';
      final document = parseSubtitles(text, DocumentFormat.srt);
      expect(document.segments, isEmpty);
      expectRoundTrip(document, text);
    });
  });

  group('parseSubtitles (WebVTT)', () {
    const vtt =
        'WEBVTT - Some title\n'
        '\n'
        'NOTE This is a comment\n'
        'spanning two lines\n'
        '\n'
        'STYLE\n'
        '::cue { color: yellow }\n'
        '\n'
        'intro\n'
        '00:01.000 --> 00:04.000 align:start position:10%\n'
        '<v Roger Bingham>We are in New York City\n'
        '\n'
        '00:00:05.000 --> 00:00:06.000\n'
        '<c.yellow>Karaoke</c> <00:00:05.500>style &amp; more\n';

    test('translates only cue payloads', () {
      final document = parseSubtitles(vtt, DocumentFormat.vtt);
      expect(texts(document), [
        '⟨1⟩We are in New York City',
        '⟨1⟩Karaoke⟨2⟩ ⟨3⟩style ⟨4⟩ more',
      ]);
      expect(document.segments.map((Segment s) => s.label), ['1', '2']);
      expectRoundTrip(document, vtt);
    });

    test('renders translations keeping header, notes and settings', () {
      final document = parseSubtitles(vtt, DocumentFormat.vtt);
      final output = document.render([
        '⟨1⟩Estamos en Nueva York',
        '⟨1⟩ Karaoke ⟨2⟩ ⟨3⟩estilo ⟨4⟩ más',
      ]);
      expect(output, startsWith('WEBVTT - Some title\n\nNOTE This is'));
      expect(output, contains('::cue { color: yellow }\n'));
      expect(
        output,
        contains(
          'intro\n00:01.000 --> 00:04.000 align:start position:10%\n'
          '<v Roger Bingham>Estamos en Nueva York\n',
        ),
      );
      // Spaces engines add next to glued tags are removed again.
      expect(
        output,
        endsWith('<c.yellow>Karaoke</c> <00:00:05.500>estilo &amp; más\n'),
      );
    });
  });
}
