import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/phrasebook/models/phrase.dart';
import 'package:mozhi/phrasebook/widgets/phrase_tile.dart';
import 'package:mozhi/translate/widgets/listen_button.dart';

import '../pump.dart';

void main() {
  testWidgets('the two speakers name the language they read', (tester) async {
    final speech = createSpeech();
    when(() => speech.speaking).thenAnswer((_) => const Stream.empty());
    await tester.pumpPhrasebook(
      Scaffold(
        body: PhraseTile(
          phrase: Phrase(
            id: 'p1',
            text: 'Where is the station?',
            translation: 'Où est la gare ?',
            sourceCode: 'en',
            targetCode: 'fr',
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
          ),
        ),
      ),
      speech: speech,
    );
    expect(find.byType(ListenButton), findsNWidgets(2));
    expect(find.text('English'), findsOneWidget);
    expect(find.text('French'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Listen to the phrase (English)'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Listen to the translation (French)'),
      findsOneWidget,
    );
  });

  testWidgets('an unknown language keeps the plain label', (tester) async {
    final speech = createSpeech();
    when(() => speech.speaking).thenAnswer((_) => const Stream.empty());
    await tester.pumpPhrasebook(
      Scaffold(
        body: PhraseTile(
          phrase: Phrase(
            id: 'p1',
            text: 'Hi',
            translation: 'Salut',
            sourceCode: Phrase.unknownLanguage,
            targetCode: 'fr',
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
          ),
        ),
      ),
      speech: speech,
    );
    expect(find.bySemanticsLabel('Listen to the phrase'), findsOneWidget);
  });
}
