import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/phrasebook/widgets/add_to_phrasebook.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../pump.dart';

const _hello = PhraseDraft(
  text: 'Hello',
  translation: 'Olá',
  sourceCode: 'en',
  targetCode: 'pt',
);

class _FailingRepository extends Mock implements PhrasebookRepository;

void main() {
  setUpAll(() => registerFallbackValue(_hello));

  /// A button that opens the sheet for [draft].
  Widget opener(PhraseDraft draft) => Scaffold(
    body: Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => showAddToPhrasebook(context, draft),
          child: const Text('open'),
        ),
      ),
    ),
  );

  testWidgets('a new collection takes the phrase, with Open in the snack '
      'bar', (tester) async {
    final repository = createPhrasebook();
    final router = createRouter();
    await tester.pumpPhrasebook(
      opener(_hello),
      repository: repository,
      router: router,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Add to phrasebook'), findsOneWidget);
    // The phrase is shown under the title.
    expect(find.text('Olá'), findsOneWidget);

    await tester.tap(find.byKey(const Key('phrasebook_choose_new')));
    await tester.pumpAndSettle();
    final save = find.byKey(const Key('phrasebook_collection_name_save'));
    expect(tester.widget<TextButton>(save).onPressed, isNull);
    await tester.enterText(
      find.byKey(CollectionNameDialog.fieldKey),
      ' Trip to Lisbon ',
    );
    await tester.pump();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(find.text('Added to Trip to Lisbon'), findsOneWidget);
    final collections = await repository.collections();
    final lisbon = collections.last;
    expect(lisbon.name, 'Trip to Lisbon');
    expect(lisbon.sourceCode, 'en');
    expect(lisbon.targetCode, 'pt');
    expect(
      (await repository.phrases(collectionId: lisbon.id)).single.text,
      'Hello',
    );
    await tester.tap(find.text('Open'));
    verify(
      () => router.push<void>(
        phrasebookLocation(collectionId: lisbon.id),
        extra: any(named: 'extra'),
      ),
    ).called(1);
  });

  testWidgets('lists the last used collection first and ticks the ones that '
      'have the phrase', (tester) async {
    final repository = createPhrasebook();
    final lisbon = await repository.createCollection('Lisbon');
    final porto = await repository.createCollection('Porto');
    await repository.addPhrase(_hello, lisbon.id);
    await repository.addPhrase(
      const PhraseDraft(
        text: 'Bye',
        translation: 'Adeus',
        sourceCode: 'en',
        targetCode: 'pt',
      ),
      porto.id,
    );
    await tester.pumpPhrasebook(opener(_hello), repository: repository);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final first = tester.getTopLeft(find.text('Porto')).dy;
    final second = tester.getTopLeft(find.text('Lisbon')).dy;
    expect(first, lessThan(second));
    expect(find.text('1 phrase · Last used'), findsOneWidget);
    expect(find.text('1 phrase · Has this phrase'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);

    // Already there: nothing is added.
    await tester.tap(find.text('Lisbon'));
    await tester.pumpAndSettle();
    expect(find.text('Already in Lisbon'), findsOneWidget);
    expect(await repository.phrases(collectionId: lisbon.id), hasLength(1));

    // Into another one.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Porto'));
    await tester.pumpAndSettle();
    expect(find.text('Added to Porto'), findsOneWidget);
  });

  testWidgets('cancelling changes nothing', (tester) async {
    final repository = createPhrasebook();
    await tester.pumpPhrasebook(opener(_hello), repository: repository);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('phrasebook_choose_new')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    // Back in the sheet; dismiss it.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(await repository.collections(), hasLength(1));
  });

  testWidgets('says when it cannot save', (tester) async {
    final failing = _FailingRepository();
    when(failing.collections).thenThrow(StateError('storage'));
    await tester.pumpPhrasebook(opener(_hello), repository: failing);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't save your phrasebook"), findsOneWidget);

    final now = DateTime(2026);
    final lisbon = PhraseCollection(
      id: 'c:1',
      name: 'Lisbon',
      phraseIds: const [],
      createdAt: now,
      updatedAt: now,
    );
    when(failing.collections).thenAnswer((_) async => [lisbon]);
    when(failing.lastCollectionId).thenAnswer((_) async => null);
    when(() => failing.collectionsWith(any())).thenAnswer((_) async => {});
    when(() => failing.collection('c:1')).thenAnswer((_) async => lisbon);
    when(() => failing.addPhrase(any(), any())).thenThrow(StateError('full'));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lisbon'));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't save your phrasebook"), findsOneWidget);

    // A collection gone in the meantime.
    when(() => failing.collection('c:1')).thenAnswer((_) async => null);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lisbon'));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't save your phrasebook"), findsOneWidget);
  });

  testWidgets('does nothing without a phrasebook or for an empty phrase', (
    tester,
  ) async {
    await tester.pumpPhrasebook(opener(_hello));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Add to phrasebook'), findsNothing);

    await tester.pumpPhrasebook(
      opener(
        const PhraseDraft(
          text: '',
          translation: '',
          sourceCode: 'en',
          targetCode: 'pt',
        ),
      ),
      repository: createPhrasebook(),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Add to phrasebook'), findsNothing);
  });

  group('AddToPhrasebookButton', () {
    testWidgets('opens the sheet; disabled without a phrase; hidden without '
        'a phrasebook', (tester) async {
      await tester.pumpPhrasebook(
        const Scaffold(body: AddToPhrasebookButton(draft: _hello)),
        repository: createPhrasebook(),
      );
      await tester.tap(find.byTooltip('Add to phrasebook…'));
      await tester.pumpAndSettle();
      expect(find.text('Add to phrasebook'), findsOneWidget);

      await tester.pumpPhrasebook(
        const Scaffold(body: AddToPhrasebookButton(draft: null)),
        repository: createPhrasebook(),
      );
      await tester.tap(find.byTooltip('Add to phrasebook…'));
      await tester.pumpAndSettle();
      expect(find.text('Add to phrasebook'), findsNothing);

      await tester.pumpPhrasebook(
        const Scaffold(body: AddToPhrasebookButton(draft: _hello)),
      );
      expect(find.byTooltip('Add to phrasebook…'), findsNothing);
    });
  });

  group('showCollectionChooser', () {
    testWidgets('leaves out the excluded and says when there is no other', (
      tester,
    ) async {
      final now = DateTime(2026);
      final lisbon = PhraseCollection(
        id: 'c:1',
        name: 'Lisbon',
        phraseIds: const [],
        createdAt: now,
        updatedAt: now,
      );
      CollectionChoice? choice;
      await tester.pumpPhrasebook(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => choice = await showCollectionChooser(
                context,
                title: 'Move to collection…',
                collections: [lisbon],
                excluded: {lisbon.id},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Lisbon'), findsNothing);
      expect(find.text('No other collection yet.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('phrasebook_choose_new')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(CollectionNameDialog.fieldKey), 'Faro');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(choice?.newName, 'Faro');
      expect(choice?.id, isNull);
    });
  });

  test('translationPhraseDraft', () {
    const english = Language(code: 'en', name: 'English');
    const portuguese = Language(code: 'pt', name: 'Portuguese');
    expect(translationPhraseDraft(const TranslateState()), isNull);
    final draft = translationPhraseDraft(
      const TranslateState(
        input: 'Hello ',
        result: TranslationResult(
          engineId: 'offline',
          engineName: 'Offline',
          text: ' Olá',
        ),
        source: english,
        target: portuguese,
      ),
    );
    expect(draft, _hello.copyWithOrigin());
    // A detected source language.
    expect(
      translationPhraseDraft(
        const TranslateState(
          input: 'Bonjour',
          result: TranslationResult(
            engineId: 'offline',
            engineName: 'Offline',
            text: 'Hello',
            detectedSource: 'fr',
          ),
        ),
      )?.sourceCode,
      'fr',
    );
    expect(
      phrasebookLocation(collectionId: 'c:1'),
      '/phrasebook?collection=c%3A1',
    );
    expect(phrasebookLocation(), '/phrasebook');
  });
}

extension on PhraseDraft {
  PhraseDraft copyWithOrigin() => PhraseDraft(
    text: text,
    translation: translation,
    sourceCode: sourceCode,
    targetCode: targetCode,
    origin: PhraseOrigin.history,
  );
}
