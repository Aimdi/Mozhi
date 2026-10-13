@Timeout(Duration(seconds: 60))
library;

import 'dart:convert';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/presets/data/glossary_repository.dart';
import 'package:mozhi/presets/models/glossary.dart';
import 'package:mozhi/presets/view/glossary_editor_page.dart';
import 'package:mozhi/presets/widgets/presets_share.dart';

import '../helpers.dart';

const _cat = GlossaryTerm(source: 'cat', target: 'Katze', note: 'pet');
const _dog = GlossaryTerm(source: 'dog', target: 'Hund');
const _api = GlossaryTerm(source: 'API', target: 'API', caseSensitive: true);

const _pets = Glossary(
  id: 'pets',
  name: 'Pets & more',
  sourceCode: 'en',
  targetCode: 'de',
  terms: [_cat, _dog, _api],
);

void main() {
  group('GlossaryEditorPage', () {
    late PresetsHarness harness;

    setUp(() => harness = PresetsHarness());
    tearDown(() => harness.close());

    Glossary? glossary() => harness.glossaries.state.byId('pets');

    Future<void> pumpEditor(
      WidgetTester tester, {
      Glossary initial = _pets,
      Size? size,
      bool asRoute = false,
    }) async {
      harness.store.values[GlossaryRepository.storageKey] = jsonEncode(
        GlossaryRepository.encode([initial]),
      );
      await harness.glossaries.load();
      const editor = GlossaryEditorPage(glossaryId: 'pets');
      await harness.pump(
        tester,
        asRoute
            ? Builder(
                builder: (context) => Scaffold(
                  body: Center(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => BlocProvider.value(
                            value: harness.glossaries,
                            child: editor,
                          ),
                        ),
                      ),
                      child: const Text('open'),
                    ),
                  ),
                ),
              )
            : editor,
        size: size,
      );
      await settle(tester);
      if (asRoute) {
        await tester.tap(find.text('open'));
        await settle(tester);
      }
    }

    testWidgets('shows a spinner while loading and a message when missing', (
      tester,
    ) async {
      await harness.pump(tester, const GlossaryEditorPage(glossaryId: 'pets'));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await harness.glossaries.load();
      await settle(tester);
      expect(find.text('This glossary no longer exists.'), findsOneWidget);
    });

    testWidgets('lists terms as a table on wide screens', (tester) async {
      await pumpEditor(tester, size: const Size(1200, 900));
      expect(find.text('Pets & more'), findsOneWidget);
      expect(find.text('English → German'), findsOneWidget);
      expect(find.text('3 terms'), findsOneWidget);
      expect(find.text('Source term'), findsOneWidget);
      expect(find.text('Note'), findsOneWidget);
      expect(find.text('Katze'), findsOneWidget);
      expect(find.text('pet'), findsOneWidget);
      expect(find.byIcon(Icons.text_fields), findsOneWidget);
    });

    testWidgets('lists terms as tiles on phones', (tester) async {
      await pumpEditor(tester, size: const Size(400, 800));
      expect(find.text('Source term'), findsNothing);
      expect(find.text('cat'), findsOneWidget);
      expect(find.text('Katze'), findsOneWidget);
      expect(find.text('pet'), findsOneWidget);
      expect(find.byIcon(Icons.text_fields), findsOneWidget);
    });

    testWidgets('searches terms', (tester) async {
      await pumpEditor(tester);
      await tester.enterText(
        find.byKey(const Key('glossary_editor_search')),
        'HUND',
      );
      await settle(tester);
      expect(find.text('dog'), findsOneWidget);
      expect(find.text('cat'), findsNothing);

      await tester.enterText(
        find.byKey(const Key('glossary_editor_search')),
        'zzz',
      );
      await settle(tester);
      expect(find.text('No terms match your search'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear search'));
      await settle(tester);
      expect(find.text('cat'), findsOneWidget);
      expect(find.text('dog'), findsOneWidget);
    });

    testWidgets('adds a term', (tester) async {
      await pumpEditor(tester);
      await tester.tap(find.byKey(const Key('glossary_editor_add')));
      await settle(tester);
      expect(find.text('New term'), findsOneWidget);
      await tester.tap(find.byKey(const Key('glossary_term_submit')));
      await settle(tester);
      expect(find.text('Required'), findsNWidgets(2));

      await tester.enterText(
        find.byKey(const Key('glossary_term_source')),
        ' bird ',
      );
      await tester.enterText(
        find.byKey(const Key('glossary_term_target')),
        'Vogel',
      );
      await tester.enterText(
        find.byKey(const Key('glossary_term_note')),
        'animal',
      );
      await tester.tap(find.byKey(const Key('glossary_term_case')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('glossary_term_submit')));
      await settle(tester);
      expect(
        glossary()!.terms.last,
        const GlossaryTerm(
          source: 'bird',
          target: 'Vogel',
          note: 'animal',
          caseSensitive: true,
        ),
      );
      expect(find.text('Vogel'), findsOneWidget);
    });

    testWidgets('cancelling the term dialog changes nothing', (tester) async {
      await pumpEditor(tester);
      await tester.tap(find.byKey(const Key('glossary_editor_add')));
      await settle(tester);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(glossary()!.terms, _pets.terms);
    });

    testWidgets('edits a term by tapping it', (tester) async {
      await pumpEditor(tester);
      await tester.tap(find.text('Hund'));
      await settle(tester);
      expect(find.text('Edit term'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('glossary_term_target')),
        'Hündchen',
      );
      await tester.tap(find.byKey(const Key('glossary_term_submit')));
      await settle(tester);
      expect(glossary()!.terms[1].target, 'Hündchen');
    });

    testWidgets('deletes a term with undo', (tester) async {
      await pumpEditor(tester);
      await tester.tap(find.byTooltip('Delete cat'));
      await settle(tester);
      expect(glossary()!.terms, const [_dog, _api]);
      expect(find.text('Deleted “cat”'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await settle(tester);
      expect(glossary()!.terms, _pets.terms);
    });

    testWidgets('swipe deletes a term', (tester) async {
      await pumpEditor(tester, size: const Size(400, 800));
      await tester.drag(find.text('Hund'), const Offset(-500, 0));
      await settle(tester);
      expect(glossary()!.terms, const [_cat, _api]);
    });

    testWidgets('imports pasted CSV', (tester) async {
      await pumpEditor(tester);
      await tester.tap(find.byKey(const Key('glossary_editor_import')));
      await settle(tester);
      expect(find.text('Import terms'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('presets_import_field')),
        'just one column',
      );
      await tester.tap(find.byKey(const Key('presets_import_submit')));
      await settle(tester);
      expect(
        find.text(
          'No terms found. Use one term per line: source, translation.',
        ),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('presets_import_field')),
        'source,target\ncat,Kater\nbird,Vogel\nbroken\n',
      );
      await tester.tap(find.byKey(const Key('presets_import_submit')));
      await settle(tester);
      expect(find.text('1 added, 1 updated, 1 skipped'), findsOneWidget);
      expect(glossary()!.terms.first.target, 'Kater');
      expect(glossary()!.terms.last.source, 'bird');
    });

    testWidgets('empty glossary offers add and import', (tester) async {
      await pumpEditor(tester, initial: _pets.copyWith(terms: const []));
      expect(find.text('No terms yet'), findsOneWidget);
      expect(find.byKey(const Key('glossary_editor_search')), findsNothing);
      await tester.tap(find.byKey(const Key('glossary_editor_empty_import')));
      await settle(tester);
      harness.clipboard = 'a\tb';
      await tester.tap(find.text('Paste from clipboard'));
      await settle(tester);
      await tester.tap(find.byKey(const Key('presets_import_submit')));
      await settle(tester);
      expect(glossary()!.terms, const [GlossaryTerm(source: 'a', target: 'b')]);
    });

    testWidgets('exports as CSV, TSV and JSON', (tester) async {
      await pumpEditor(tester);
      Future<void> export(String label) async {
        await tester.tap(find.byKey(const Key('glossary_editor_export')));
        await settle(tester);
        await tester.tap(find.text(label));
        await settle(tester);
      }

      await export('Copy as CSV');
      expect(harness.clipboard, startsWith('source,target,note'));
      expect(find.text('Copied to clipboard'), findsOneWidget);

      await export('Share as CSV');
      expect(harness.shared['mozhi-glossary-pets-more.csv'], contains('cat'));
      await export('Share as TSV');
      expect(harness.shared['mozhi-glossary-pets-more.tsv'], contains('\t'));
      await export('Share as JSON');
      final json = harness.shared['mozhi-glossary-pets-more.json']!;
      expect(
        GlossaryRepository.parseGlossaries(jsonDecode(json))!.single.terms,
        _pets.terms,
      );
    });

    testWidgets('reports export failures', (tester) async {
      await pumpEditor(tester, initial: _pets.copyWith(name: '!!!'));
      PresetsShare.share = (
        text, {
        required fileName,
        required mimeType,
      }) async => throw StateError('unsupported');
      await tester.tap(find.byKey(const Key('glossary_editor_export')));
      await settle(tester);
      await tester.tap(find.text('Share as CSV'));
      await settle(tester);
      expect(find.text("Couldn't export"), findsOneWidget);
    });

    testWidgets('toggles the glossary', (tester) async {
      await pumpEditor(tester);
      await tester.tap(find.byKey(const Key('glossary_editor_enabled')));
      await settle(tester);
      expect(glossary()!.enabled, isFalse);
    });

    testWidgets('renames and changes the languages', (tester) async {
      await pumpEditor(tester);
      await tester.tap(find.byTooltip('Rename or change languages'));
      await settle(tester);
      expect(find.text('Edit glossary'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('glossary_details_name')),
        'Animals',
      );
      await tester.tap(find.byKey(const Key('glossary_details_target')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('language_scope_any')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('glossary_details_submit')));
      await settle(tester);
      expect(glossary()!.name, 'Animals');
      expect(glossary()!.targetCode, LanguageScope.any);
      expect(find.text('English → Any language'), findsOneWidget);
    });

    testWidgets('edit details from the overflow menu', (tester) async {
      await pumpEditor(tester);
      await tester.tap(find.byKey(const Key('glossary_editor_more')));
      await settle(tester);
      await tester.tap(find.text('Rename or change languages').last);
      await settle(tester);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(glossary(), _pets);
    });

    testWidgets('deletes the glossary after confirming', (tester) async {
      await pumpEditor(tester, asRoute: true);
      Future<void> openDelete() async {
        await tester.tap(find.byKey(const Key('glossary_editor_more')));
        await settle(tester);
        await tester.tap(find.text('Delete glossary'));
        await settle(tester);
      }

      await openDelete();
      expect(find.text('Delete glossary?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(glossary(), isNotNull);

      await openDelete();
      await tester.tap(find.byKey(const Key('glossary_editor_delete_confirm')));
      await settle(tester);
      expect(glossary(), isNull);
      expect(find.text('open'), findsOneWidget);
    });
  });
}
