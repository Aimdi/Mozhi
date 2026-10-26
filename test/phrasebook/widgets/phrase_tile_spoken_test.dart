import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/phrasebook/models/phrase.dart';
import 'package:mozhi/phrasebook/widgets/phrase_tile.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/speech/widgets/spoken_range_builder.dart';

import '../pump.dart';

class _MockSettingsCubit extends MockCubit<AppSettings>
    implements SettingsCubit;

final _phrase = Phrase(
  id: 'p1',
  text: 'Where is the station?',
  translation: 'Où est la gare ?',
  sourceCode: 'en',
  targetCode: 'fr',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

/// The texts drawn as the word being read.
List<String?> _spoken(WidgetTester tester) {
  final scheme = Theme.of(tester.element(find.byType(PhraseTile))).colorScheme;
  final background = spokenWordStyle(scheme).backgroundColor;
  final spoken = <String?>[];
  for (final text in tester.widgetList<RichText>(find.byType(RichText))) {
    text.text.visitChildren((span) {
      if (span is TextSpan && span.style?.backgroundColor == background) {
        spoken.add(span.text);
      }
      return true;
    });
  }
  return spoken;
}

void main() {
  late MockSpeechService speech;
  late StreamController<String?> speaking;
  late StreamController<SpokenRange?> ranges;

  setUp(() {
    speech = createSpeech();
    speaking = StreamController<String?>.broadcast();
    ranges = StreamController<SpokenRange?>.broadcast();
    addTearDown(speaking.close);
    addTearDown(ranges.close);
    when(() => speech.speaking).thenAnswer((_) => speaking.stream);
    when(() => speech.spokenRanges).thenAnswer((_) => ranges.stream);
  });

  Future<void> deliver(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the word of the translation being read is highlighted', (
    tester,
  ) async {
    await tester.pumpPhrasebook(
      Scaffold(body: PhraseTile(phrase: _phrase)),
      speech: speech,
    );
    when(() => speech.current).thenReturn('phrasebook:p1:target');
    speaking.add('phrasebook:p1:target');
    await deliver(tester);
    ranges.add(const SpokenRange(7, 9));
    await deliver(tester);
    expect(_spoken(tester), ['la']);
    when(() => speech.current).thenReturn(null);
    speaking.add(null);
    await deliver(tester);
    expect(_spoken(tester), isEmpty);
  });

  testWidgets('and so is the phrase’s', (tester) async {
    when(() => speech.current).thenReturn('phrasebook:p1:source');
    await tester.pumpPhrasebook(
      Scaffold(
        body: PhraseTile(phrase: _phrase, query: 'station'),
      ),
      speech: speech,
    );
    ranges.add(const SpokenRange(0, 5));
    await deliver(tester);
    expect(_spoken(tester), ['Where']);
  });

  testWidgets('not with the setting off', (tester) async {
    final settings = _MockSettingsCubit();
    when(() => settings.state)
        .thenReturn(const AppSettings(highlightSpokenWord: false));
    when(() => speech.current).thenReturn('phrasebook:p1:target');
    await tester.pumpPhrasebook(
      BlocProvider<SettingsCubit>.value(
        value: settings,
        child: Scaffold(body: PhraseTile(phrase: _phrase)),
      ),
      speech: speech,
    );
    ranges.add(const SpokenRange(7, 9));
    await deliver(tester);
    expect(_spoken(tester), isEmpty);
  });
}
