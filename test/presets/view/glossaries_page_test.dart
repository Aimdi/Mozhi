@Timeout(Duration(seconds: 60))
library;

import 'dart:convert';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/presets/cubit/glossary_cubit.dart';
import 'package:mozhi/presets/data/glossary_repository.dart';
import 'package:mozhi/presets/models/glossary.dart';
import 'package:mozhi/presets/view/glossaries_page.dart';
import 'package:mozhi/presets/view/glossary_editor_page.dart';

import '../helpers.dart';

class _MockStore extends Mock implements KeyValueStore {}

const _pets = Glossary(
  id: 'pets',
  name: 'Pets',
  sourceCode: 'en',
  targetCode: 'de',
  terms: [
    GlossaryTerm(source: 'cat', target: 'Katze'),
    GlossaryTerm(source: 'dog', target: 'Hund'),
  ],
);
const _brand = Glossary(
  id: 'brand',
  name: 'Brand',
  enabled: false,
  terms: [GlossaryTerm(source: 'Mozhi', target: 'Mozhi')],
);

void main() {
  group('GlossariesPage', () {
    late PresetsHarness harness;

    List<Glossary> glossaries() => harness.glossaries.state.glossaries;

    Future<void> pumpLoaded(
      WidgetTester tester, {
      List<Glossary> initial = const [_pets, _brand],
      OpenGlossary? onOpenGlossary,
    }) async {
      harness.store.values[GlossaryRepository.storageKey] = jsonEncode(
        GlossaryRepository.encode(initial),
      );
      await harness.glossaries.load();
      await harness.pump(
        tester,
        GlossariesPage(onOpenGlossary: onOpenGlossary),
      );
      await settle(tester);
    }

    testWidgets('shows a spinner while loading', (tester) async {
      harness = PresetsHarness();
      addTearDown(harness.close);
      await harness.pump(tester, const GlossariesPage());
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('shows the empty state', (tester) async {
      harness = PresetsHarness();
      addTearDown(harness.close);
      await pumpLoaded(tester, initial: const []);
      expect(find.text('No glossaries yet'), findsOneWidget);
    });

    testWidgets('lists glossaries with scope and term count', (tester) async {
      harness = PresetsHarness();
      addTearDown(harness.close);
      await pumpLoaded(tester);
      expect(find.text('Glossaries'), findsOneWidget);
      expect(find.text('Pets'), findsOneWidget);
      expect(find.text('English → German · 2 terms'), findsOneWidget);
      expect(find.text('Any language → Any language · 1 term'), findsOneWidget);
    });

    testWidgets('toggles a glossary', (tester) async {
      harness = PresetsHarness();
      addTearDown(harness.close);
      await pumpLoaded(tester);
      await tester.tap(find.byKey(const Key('glossary_enabled_brand')));
      await settle(tester);
      expect(glossaries().last.enabled, isTrue);
    });

    testWidgets('opens the editor on tap by default', (tester) async {
      harness = PresetsHarness();
      addTearDown(harness.close);
      await pumpLoaded(tester);
      await tester.tap(find.text('Pets'));
      await settle(tester);
      expect(find.byType(GlossaryEditorPage), findsOneWidget);
      expect(find.text('cat'), findsOneWidget);
    });

    testWidgets('uses a custom open callback', (tester) async {
      harness = PresetsHarness();
      addTearDown(harness.close);
      final opened = <String>[];
      await pumpLoaded(tester, onOpenGlossary: (_, id) => opened.add(id));
      await tester.tap(find.text('Brand'));
      expect(opened, ['brand']);
    });

    testWidgets('creates a glossary and opens it', (tester) async {
      harness = PresetsHarness();
      addTearDown(harness.close);
      final opened = <String>[];
      await pumpLoaded(
        tester,
        initial: const [],
        onOpenGlossary: (_, id) => opened.add(id),
      );
      await tester.tap(find.byKey(const Key('glossaries_add')));
      await settle(tester);
      expect(find.text('New glossary'), findsWidgets);

      await tester.tap(find.byKey(const Key('glossary_details_submit')));
      await settle(tester);
      expect(find.text('Enter a name'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('glossary_details_name')),
        'Legal',
      );
      await tester.tap(find.byKey(const Key('glossary_details_source')));
      await settle(tester);
      expect(find.text('Translate from'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('language_scope_search')),
        'germ',
      );
      await settle(tester);
      expect(find.byKey(const Key('language_scope_any')), findsNothing);
      await tester.tap(find.byKey(const Key('language_scope_de')));
      await settle(tester);

      await tester.tap(find.byKey(const Key('glossary_details_target')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('language_scope_search')),
        'japan',
      );
      await settle(tester);
      await tester.tap(find.byKey(const Key('language_scope_ja')));
      await settle(tester);
      expect(find.text('German'), findsOneWidget);
      expect(find.text('Japanese'), findsOneWidget);

      await tester.tap(find.byKey(const Key('glossary_details_submit')));
      await settle(tester);
      expect(glossaries().single.name, 'Legal');
      expect(glossaries().single.sourceCode, 'de');
      expect(glossaries().single.targetCode, 'ja');
      expect(opened, [glossaries().single.id]);
    });

    testWidgets('cancelling the dialog creates nothing', (tester) async {
      harness = PresetsHarness();
      addTearDown(harness.close);
      await pumpLoaded(tester, initial: const []);
      await tester.tap(find.byKey(const Key('glossaries_add')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('glossary_details_source')));
      await settle(tester);
      // Dismiss the language sheet without choosing.
      await tester.tapAt(const Offset(10, 10));
      await settle(tester);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(glossaries(), isEmpty);
    });

    testWidgets('swipe deletes with undo', (tester) async {
      harness = PresetsHarness();
      addTearDown(harness.close);
      await pumpLoaded(tester);
      await tester.drag(find.text('Pets'), const Offset(-600, 0));
      await settle(tester);
      expect(find.text('Pets'), findsNothing);
      expect(glossaries(), const [_brand]);
      expect(find.text('Deleted “Pets”'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await settle(tester);
      expect(glossaries(), const [_pets, _brand]);
      expect(find.text('Pets'), findsOneWidget);
    });

    testWidgets('imports glossaries from JSON', (tester) async {
      harness = PresetsHarness();
      addTearDown(harness.close);
      await pumpLoaded(tester, initial: const [_brand]);
      await tester.tap(find.byKey(const Key('glossaries_menu')));
      await settle(tester);
      await tester.tap(find.text('Import glossaries'));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('presets_import_field')),
        '[1]',
      );
      await tester.tap(find.byKey(const Key('presets_import_submit')));
      await settle(tester);
      expect(
        find.text("This doesn't look like exported glossaries."),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('presets_import_field')),
        GlossaryRepository.exportJson(const [_pets]),
      );
      await tester.tap(find.byKey(const Key('presets_import_submit')));
      await settle(tester);
      expect(find.text('Imported 1 glossary'), findsOneWidget);
      expect(find.text('Pets'), findsOneWidget);
    });

    testWidgets('exports all glossaries as a file', (tester) async {
      harness = PresetsHarness();
      addTearDown(harness.close);
      await pumpLoaded(tester);
      await tester.tap(find.byKey(const Key('glossaries_menu')));
      await settle(tester);
      await tester.tap(find.text('Export all glossaries'));
      await settle(tester);
      await tester.tap(find.byKey(const Key('presets_export_share')));
      await settle(tester);
      final json = harness.shared['mozhi-glossaries.json']!;
      expect(GlossaryRepository.parseGlossaries(jsonDecode(json)), const [
        _pets,
        _brand,
      ]);
    });

    testWidgets('shows a retry button when loading fails', (tester) async {
      harness = PresetsHarness();
      addTearDown(harness.close);
      final failing = _MockStore();
      var calls = 0;
      when(() => failing.read(any())).thenAnswer((_) async {
        if (calls++ == 0) throw StateError('io');
        return null;
      });
      final cubit = GlossaryCubit(
        repository: GlossaryRepository(store: failing),
      );
      addTearDown(cubit.close);
      await cubit.load();
      await harness.pump(
        tester,
        BlocProvider<GlossaryCubit>.value(
          value: cubit,
          child: const GlossariesPage(),
        ),
      );
      await settle(tester);
      expect(find.text("Couldn't load your glossaries."), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await settle(tester);
      expect(find.text('No glossaries yet'), findsOneWidget);
    });
  });
}
