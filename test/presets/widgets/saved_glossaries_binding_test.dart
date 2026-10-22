import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/presets/cubit/glossary_cubit.dart';
import 'package:mozhi/presets/data/glossary_repository.dart';
import 'package:mozhi/presets/models/glossary.dart';
import 'package:mozhi/presets/widgets/saved_glossaries_binding.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  testWidgets('hands the enabled glossaries to the repository', (tester) async {
    final repository = TranslationRepository();
    addTearDown(repository.dispose);
    final glossaries = GlossaryRepository(store: MemoryStore());
    await glossaries.save(const [
      Glossary(
        id: 'g',
        sourceCode: 'en',
        targetCode: 'de',
        terms: [
          GlossaryTerm(source: 'IT', target: 'TI', caseSensitive: true),
          GlossaryTerm(source: 'cat', target: 'Katze'),
        ],
      ),
    ]);
    final cubit = GlossaryCubit(repository: glossaries);
    addTearDown(cubit.close);
    await cubit.load();

    await tester.pumpWidget(
      RepositoryProvider<TranslationRepository>.value(
        value: repository,
        child: BlocProvider.value(
          value: cubit,
          child: const SavedGlossariesBinding(child: SizedBox()),
        ),
      ),
    );

    final lookup = repository.savedGlossaries!;
    final saved = lookup('en', 'de');
    expect(saved.terms, {'IT': 'TI', 'cat': 'Katze'});
    expect(saved.caseSensitive, {'IT'});
    expect(lookup('en', 'fr').terms, isEmpty);

    await tester.pumpWidget(const SizedBox());
    expect(repository.savedGlossaries, isNull);
  });

  testWidgets('leaves a lookup set by someone else in place', (tester) async {
    final repository = TranslationRepository();
    addTearDown(repository.dispose);
    final cubit = GlossaryCubit(
      repository: GlossaryRepository(store: MemoryStore()),
    );
    addTearDown(cubit.close);
    await tester.pumpWidget(
      RepositoryProvider<TranslationRepository>.value(
        value: repository,
        child: BlocProvider.value(
          value: cubit,
          child: const SavedGlossariesBinding(child: SizedBox()),
        ),
      ),
    );
    SavedGlossary other(String _, String _) =>
        (terms: const <String, String>{}, caseSensitive: const <String>{});
    repository.savedGlossaries = other;
    await tester.pumpWidget(const SizedBox());
    expect(repository.savedGlossaries, same(other));
  });
}
