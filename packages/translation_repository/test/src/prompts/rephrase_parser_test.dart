import 'dart:convert';

import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group('ResponseParsers.parseRephrasings', () {
    const span = 'The report is late.';

    List<String> parse(Object output, {String span = span, int count = 3}) =>
        ResponseParsers.parseRephrasings(
          output is String ? output : jsonEncode(output),
          span: span,
          count: count,
        );

    test('reads an object with alternatives', () {
      expect(
        parse({
          'alternatives': ['The report is overdue.', 'The report is behind.'],
        }),
        ['The report is overdue.', 'The report is behind.'],
      );
    });

    test('reads a plain array', () {
      expect(parse(['The report is overdue.']), ['The report is overdue.']);
    });

    test('reads a plain array in a code fence or prose', () {
      expect(parse('```json\n["The report is overdue."]\n```'), [
        'The report is overdue.',
      ]);
      expect(parse('Here you go: ["The report is overdue."] Enjoy.'), [
        'The report is overdue.',
      ]);
      expect(parse('<think>hmm</think>["The report is overdue."]'), [
        'The report is overdue.',
      ]);
    });

    test('reads code fences and prose around them', () {
      expect(
        parse(
          'Sure!\n```json\n{"alternatives": ["The report is overdue."]}\n```',
        ),
        ['The report is overdue.'],
      );
    });

    test('reads objects with a text field and other list names', () {
      expect(
        parse({
          'rephrasings': [
            {'text': 'The report is overdue.', 'explanation': 'shorter'},
            {'alternative': 'We have not received the report yet.'},
            42,
            null,
          ],
        }),
        ['The report is overdue.', 'We have not received the report yet.'],
      );
      expect(
        parse({
          'whatever': ['The report is overdue.'],
        }),
        ['The report is overdue.'],
      );
    });

    test('trims, drops blanks, the span itself and duplicates', () {
      expect(
        parse({
          'alternatives': [
            '  The report is overdue.  ',
            '',
            '   ',
            'The report is late.',
            ' the  report is LATE. ',
            'The report is overdue.',
            'THE REPORT IS OVERDUE.',
            'The report is behind schedule.',
          ],
        }),
        ['The report is overdue.', 'The report is behind schedule.'],
      );
    });

    test('caps the list at count', () {
      final items = ['A one.', 'A two.', 'A three.', 'A four.'];
      expect(parse(items), hasLength(3));
      expect(parse(items, count: 2), ['A one.', 'A two.']);
      expect(parse(items, count: 0), ['A one.']);
    });

    test('removes quotes around an item unless the span is quoted', () {
      expect(parse(['"The report is overdue."']), ['The report is overdue.']);
      expect(parse(['“The report is overdue.”']), ['The report is overdue.']);
      expect(parse(['"It is overdue."'], span: '"It is late."'), [
        '"It is overdue."',
      ]);
    });

    test('restores defused tags', () {
      expect(parse(['a <​b> c']), ['a <b> c']);
    });

    test('returns an empty list for an empty or odd reply', () {
      expect(parse({'alternatives': <String>[]}), isEmpty);
      expect(parse({'note': 'none'}), isEmpty);
    });

    test('throws without JSON', () {
      expect(
        () => ResponseParsers.parseRephrasings('no json here', span: span),
        throwsFormatException,
      );
    });
  });
}
