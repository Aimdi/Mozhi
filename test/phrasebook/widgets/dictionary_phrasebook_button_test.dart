import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/dictionary/cubit/dictionary_cubit.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/phrasebook/widgets/dictionary_phrasebook_button.dart';
import 'package:translation_repository/translation_repository.dart';

import '../pump.dart';

class _MockDictionaryCubit extends MockCubit<DictionaryState>
    implements DictionaryCubit;

const _spanish = Language(code: 'es', name: 'Spanish');

DictionaryEntry _entry({List<String> translations = const ['cat']}) =>
    DictionaryEntry(
      word: 'gato',
      senses: [
        DictionarySense(
          definition: 'A small domesticated feline.',
          partOfSpeech: 'noun',
          translations: translations,
        ),
      ],
    );

void main() {
  DictionaryState success(DictionaryEntry entry) => DictionaryState(
    status: DictionaryStatus.success,
    source: _spanish,
    lookedUp: 'gato',
    entry: entry,
  );

  group('dictionaryPhraseDraft', () {
    test('the word and its first translation, else its summary', () {
      final draft = dictionaryPhraseDraft(success(_entry()));
      expect(draft!.text, 'gato');
      expect(draft.translation, 'cat');
      expect(draft.sourceCode, 'es');
      expect(draft.targetCode, 'en');
      expect(draft.origin, PhraseOrigin.dictionary);
      expect(
        dictionaryPhraseDraft(success(_entry(translations: const [' '])))
            ?.translation,
        'noun · A small domesticated feline.',
      );
      expect(dictionaryPhraseDraft(const DictionaryState()), isNull);
      expect(
        dictionaryPhraseDraft(success(const DictionaryEntry(word: ''))),
        isNull,
      );
    });
  });

  group('DictionaryPhrasebookButton', () {
    Future<void> pump(
      WidgetTester tester,
      DictionaryState state, {
      PhrasebookRepository? repository,
    }) async {
      final cubit = _MockDictionaryCubit();
      when(() => cubit.state).thenReturn(state);
      await tester.pumpPhrasebook(
        BlocProvider<DictionaryCubit>.value(
          value: cubit,
          child: const Scaffold(
            body: Center(child: DictionaryPhrasebookButton()),
          ),
        ),
        repository: repository,
      );
    }

    testWidgets('adds the entry to a collection', (tester) async {
      final repository = createPhrasebook();
      final lisbon = await repository.createCollection('Words');
      await pump(tester, success(_entry()), repository: repository);
      await tester.tap(find.byTooltip('Add to phrasebook…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Words'));
      await tester.pumpAndSettle();
      expect(find.text('Added to Words'), findsOneWidget);
      final phrase = (await repository.phrases(collectionId: lisbon.id)).single;
      expect(phrase.text, 'gato');
      expect(phrase.translation, 'cat');
    });

    testWidgets('disabled while loading, hidden otherwise', (tester) async {
      await pump(
        tester,
        const DictionaryState(status: DictionaryStatus.loading),
        repository: createPhrasebook(),
      );
      final button = tester.widget<IconButton>(
        find.byKey(const Key('dictionary_phrasebook')),
      );
      expect(button.onPressed, isNull);

      await pump(
        tester,
        const DictionaryState(status: DictionaryStatus.failure),
        repository: createPhrasebook(),
      );
      expect(find.byKey(const Key('dictionary_phrasebook')), findsNothing);

      await pump(tester, success(_entry()));
      expect(find.byKey(const Key('dictionary_phrasebook')), findsNothing);
    });
  });
}
