import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/widgets/widgets.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

void main() {
  group(ConversationLanguagePicker, () {
    late Language? picked;
    late bool closed;

    Future<void> open(
      WidgetTester tester, {
      List<Language> languages = const [
        Language.auto,
        english,
        french,
        german,
        spanish,
        Language.custom('Pirate speak'),
      ],
      List<Language> recent = const [],
      Language selected = english,
      bool upsideDown = false,
    }) async {
      picked = null;
      closed = false;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ConversationOrientation(
              upsideDown: upsideDown,
              child: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    picked = await showConversationLanguagePicker(
                      context,
                      selected: selected,
                      languages: languages,
                      recent: recent,
                    );
                    closed = true;
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('lists concrete languages and marks the selected one', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('Choose a language'), findsOneWidget);
      expect(find.text('Detect language'), findsNothing);
      expect(find.text('Pirate speak'), findsNothing);
      expect(find.text('French'), findsOneWidget);
      expect(find.text('Français'), findsOneWidget);
      final tile = tester.widget<ListTile>(
        find.ancestor(
          of: find.text('English'),
          matching: find.byType(ListTile),
        ),
      );
      expect(tile.selected, isTrue);
      // Same native and English name: no subtitle.
      expect(tile.subtitle, isNull);
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.text('Recent'), findsNothing);
      expect(find.byType(RotatedBox), findsNothing);
    });

    testWidgets('shows recent languages first while not searching', (
      tester,
    ) async {
      await open(
        tester,
        recent: const [german, Language.custom('Pirate'), Language.auto],
      );
      expect(find.text('Recent'), findsOneWidget);
      expect(find.text('All languages'), findsOneWidget);
      expect(find.text('German'), findsNWidgets(2));
      await tester.tap(find.text('German').first);
      await tester.pumpAndSettle();
      expect(picked, german);
    });

    testWidgets('searches names, native names and codes', (tester) async {
      await open(tester, recent: const [german]);
      await tester.enterText(
        find.byKey(const Key('conversation_language_search')),
        'deutsch',
      );
      await tester.pumpAndSettle();
      expect(find.text('Recent'), findsNothing);
      expect(find.text('German'), findsOneWidget);
      expect(find.text('French'), findsNothing);

      await tester.enterText(
        find.byKey(const Key('conversation_language_search')),
        'FR',
      );
      await tester.pumpAndSettle();
      expect(find.text('French'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('conversation_language_search')),
        'klingon',
      );
      await tester.pumpAndSettle();
      expect(find.text('No matching languages'), findsOneWidget);
      // Several or no matches: submitting does nothing.
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(closed, isFalse);
    });

    testWidgets('submitting a search with one match picks it', (tester) async {
      await open(tester);
      await tester.enterText(
        find.byKey(const Key('conversation_language_search')),
        'span',
      );
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(picked, spanish);
    });

    testWidgets('cancel closes without a language', (tester) async {
      await open(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(picked, isNull);
    });

    testWidgets('is turned around when opened upside down', (tester) async {
      await open(tester, upsideDown: true);
      final rotated = tester.widget<RotatedBox>(
        find.ancestor(
          of: find.byType(ConversationLanguagePicker),
          matching: find.byType(RotatedBox),
        ),
      );
      expect(rotated.quarterTurns, 2);
      await tester.tap(find.text('French'));
      await tester.pumpAndSettle();
      expect(picked, french);
    });
  });

  testWidgets('ConversationOrientation notifies on changes only', (
    tester,
  ) async {
    const a = ConversationOrientation(upsideDown: true, child: SizedBox());
    expect(
      a.updateShouldNotify(
        const ConversationOrientation(upsideDown: true, child: SizedBox()),
      ),
      isFalse,
    );
    expect(
      a.updateShouldNotify(
        const ConversationOrientation(upsideDown: false, child: SizedBox()),
      ),
      isTrue,
    );
  });
}
