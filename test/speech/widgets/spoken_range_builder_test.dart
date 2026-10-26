import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/speech/widgets/spoken_range_builder.dart';

class _MockSpeechService extends Mock implements SpeechService;

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final (hi, lo) = la > lb ? (la, lb) : (lb, la);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  late _MockSpeechService speech;
  late StreamController<String?> speaking;
  late StreamController<SpokenRange?> ranges;
  late List<TextRange?> built;

  setUp(() {
    speech = _MockSpeechService();
    speaking = StreamController<String?>.broadcast();
    ranges = StreamController<SpokenRange?>.broadcast();
    addTearDown(speaking.close);
    addTearDown(ranges.close);
    when(() => speech.speaking).thenAnswer((_) => speaking.stream);
    when(() => speech.spokenRanges).thenAnswer((_) => ranges.stream);
    when(() => speech.current).thenReturn(null);
    built = [];
  });

  Widget builder({String id = 'a', bool enabled = true, String text = 'Hi'}) =>
      SpokenRangeBuilder(
        id: id,
        text: text,
        enabled: enabled,
        builder: (context, spoken) {
          built.add(spoken);
          return const SizedBox();
        },
      );

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    RepositoryProvider<SpeechService>.value(value: speech, child: child),
  );

  /// Delivers the stream events, then rebuilds.
  Future<void> deliver(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  testWidgets('follows the clip while it plays', (tester) async {
    await pump(tester, builder());
    when(() => speech.current).thenReturn('a');
    speaking.add('a');
    await deliver(tester);
    ranges.add(const SpokenRange(0, 2));
    await deliver(tester);
    expect(built.last, const TextRange(start: 0, end: 2));
    when(() => speech.current).thenReturn('b');
    speaking.add('b');
    await deliver(tester);
    expect(built.last, isNull);
    // The other clip's words are not this one's.
    ranges.add(const SpokenRange(0, 1));
    await deliver(tester);
    expect(built.last, isNull);
  });

  testWidgets('turning it off clears the highlight', (tester) async {
    when(() => speech.current).thenReturn('a');
    await pump(tester, builder());
    ranges.add(const SpokenRange(0, 2));
    await deliver(tester);
    expect(built.last, isNotNull);
    await pump(tester, builder(enabled: false));
    expect(built.last, isNull);
    ranges.add(const SpokenRange(0, 1));
    await deliver(tester);
    expect(built.last, isNull);
    await pump(tester, builder());
    ranges.add(const SpokenRange(0, 1));
    await deliver(tester);
    expect(built.last, const TextRange(start: 0, end: 1));
  });

  testWidgets('another id starts afresh', (tester) async {
    when(() => speech.current).thenReturn('a');
    await pump(tester, builder());
    ranges.add(const SpokenRange(0, 2));
    await deliver(tester);
    await pump(tester, builder(id: 'b'));
    expect(built.last, isNull);
  });

  testWidgets('nothing without a speech service', (tester) async {
    await tester.pumpWidget(builder());
    expect(built.single, isNull);
  });

  testWidgets('a service that reports nothing shows nothing', (tester) async {
    final silent = _MockSpeechService();
    await tester.pumpWidget(
      RepositoryProvider<SpeechService>.value(value: silent, child: builder()),
    );
    expect(built.single, isNull);
    expect(tester.takeException(), isNull);
  });

  group('spokenTextSpan', () {
    const highlight = TextStyle(backgroundColor: Color(0xFF00FF00));

    test('marks the range', () {
      final span = spokenTextSpan(
        'Hola mundo',
        const TextRange(start: 5, end: 10),
        highlight: highlight,
        locale: const Locale('es'),
      );
      expect(span.toPlainText(), 'Hola mundo');
      final children = span.children!.cast<TextSpan>();
      expect([for (final child in children) child.text], ['Hola ', 'mundo']);
      expect(children.last.style?.backgroundColor, highlight.backgroundColor);
      expect(children.last.locale, const Locale('es'));
    });

    test('a range at the start', () {
      final span = spokenTextSpan(
        'Hola mundo',
        const TextRange(start: 0, end: 4),
        highlight: highlight,
      );
      expect(
        [for (final child in span.children!) (child as TextSpan).text],
        ['Hola', ' mundo'],
      );
    });

    test('no range, or one outside the text, marks nothing', () {
      for (final range in [
        null,
        TextRange.empty,
        const TextRange.collapsed(2),
        const TextRange(start: 2, end: 99),
      ]) {
        final span = spokenTextSpan('Hola', range, highlight: highlight);
        expect(span.children, isNull);
        expect(span.text, 'Hola');
      }
    });
  });

  test('the highlight keeps its contrast in light and dark', () {
    for (final brightness in Brightness.values) {
      final scheme = ThemeData(brightness: brightness).colorScheme;
      final style = spokenWordStyle(scheme);
      expect(
        _contrast(style.color!, style.backgroundColor!),
        greaterThanOrEqualTo(4.5),
        reason: '$brightness',
      );
    }
  });
}
