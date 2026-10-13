@Timeout(Duration(seconds: 40))
library;

import 'dart:convert';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/presets/cubit/presets_cubit.dart';
import 'package:mozhi/presets/data/presets_repository.dart';
import 'package:mozhi/presets/models/preset.dart';
import 'package:mozhi/presets/view/presets_page.dart';
import 'package:mozhi/presets/widgets/presets_share.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

class _MockStore extends Mock implements KeyValueStore {}

const _email = 'Email to colleague (formal)';
const _chat = 'Chat with friends (casual)';
const _simple = 'Simple (A2 reading level)';

void main() {
  group('PresetsPage', () {
    late PresetsHarness harness;

    setUp(() => harness = PresetsHarness());
    tearDown(() => harness.close());

    Future<void> pumpLoaded(
      WidgetTester tester, {
      VoidCallback? onOpenGlossaries,
    }) async {
      await harness.presets.load();
      await harness.pump(
        tester,
        PresetsPage(onOpenGlossaries: onOpenGlossaries),
      );
      await settle(tester);
    }

    PresetsState state() => harness.presets.state;

    Future<void> openMenuFor(WidgetTester tester, String name) async {
      await tester.tap(find.byTooltip('Actions for $name'));
      await settle(tester);
    }

    testWidgets('shows a spinner while loading', (tester) async {
      await harness.pump(tester, const PresetsPage());
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('lists the examples with summaries', (tester) async {
      await pumpLoaded(tester);
      expect(find.text('Presets'), findsOneWidget);
      expect(find.text(_email), findsOneWidget);
      expect(find.text(_chat), findsOneWidget);
      expect(find.text(_simple), findsOneWidget);
      expect(
        find.textContaining('More formal · Context: An email'),
        findsOneWidget,
      );
      expect(find.text('Level A2'), findsOneWidget);
      expect(find.byKey(const Key('presets_default_badge')), findsNothing);
      expect(find.byKey(const Key('presets_open_glossaries')), findsNothing);
    });

    testWidgets('marks the default preset and toggles it', (tester) async {
      await pumpLoaded(tester);
      await openMenuFor(tester, _chat);
      await tester.tap(find.text('Use as default'));
      await settle(tester);
      expect(state().defaultId, 'builtin-chatCasual');
      expect(find.byKey(const Key('presets_default_badge')), findsOneWidget);

      await openMenuFor(tester, _chat);
      await tester.tap(find.text('Stop using as default'));
      await settle(tester);
      expect(state().defaultId, isNull);
      expect(find.byKey(const Key('presets_default_badge')), findsNothing);
    });

    testWidgets('duplicates and moves presets', (tester) async {
      await pumpLoaded(tester);
      await openMenuFor(tester, _email);
      expect(find.text('Move up'), findsNothing);
      await tester.tap(find.text('Duplicate'));
      await settle(tester);
      expect(find.text('$_email (copy)'), findsOneWidget);
      expect(state().presets[1].name, '$_email (copy)');

      await openMenuFor(tester, _email);
      await tester.tap(find.text('Move down'));
      await settle(tester);
      expect(state().presets.first.name, '$_email (copy)');

      await openMenuFor(tester, _simple);
      expect(find.text('Move down'), findsNothing);
      await tester.tap(find.text('Move up'));
      await settle(tester);
      expect(state().presets[2].builtIn, BuiltInPreset.simpleA2);
    });

    testWidgets('deletes from the menu and by swiping, with undo', (
      tester,
    ) async {
      await pumpLoaded(tester);
      await harness.presets.setDefault('builtin-chatCasual');
      await settle(tester);

      await openMenuFor(tester, _chat);
      await tester.tap(find.text('Delete'));
      await settle(tester);
      expect(find.text(_chat), findsNothing);
      expect(state().presets, hasLength(2));
      expect(state().defaultId, isNull);
      expect(find.text('Deleted “$_chat”'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await settle(tester);
      expect(find.text(_chat), findsOneWidget);
      expect(state().presets[1].builtIn, BuiltInPreset.chatCasual);
      expect(state().defaultId, 'builtin-chatCasual');

      await tester.drag(find.text(_simple), const Offset(-600, 0));
      await settle(tester);
      expect(find.text(_simple), findsNothing);
      expect(state().presets, hasLength(2));
    });

    testWidgets('shares a single preset', (tester) async {
      await pumpLoaded(tester);
      await openMenuFor(tester, _simple);
      await tester.tap(find.text('Share'));
      await settle(tester);
      await tester.tap(find.byKey(const Key('presets_export_share')));
      await settle(tester);
      final json = jsonDecode(
        harness.shared['mozhi-preset.json']!,
      ) as Map<String, dynamic>;
      expect(json['presets'], hasLength(1));
    });

    testWidgets('edits a preset in the sheet', (tester) async {
      await pumpLoaded(tester);
      await tester.tap(find.text(_simple));
      await settle(tester);
      expect(find.text('Edit preset'), findsOneWidget);
      // The localised example name is prefilled.
      expect(
        find.descendant(
          of: find.byKey(const Key('preset_editor_name')),
          matching: find.text(_simple),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('preset_form_formality_more')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('preset_editor_save')));
      await settle(tester);

      final preset = state().byId('builtin-simpleA2')!;
      expect(preset.name, isEmpty, reason: 'unchanged example name');
      expect(preset.options.formality, Formality.more);
      expect(preset.options.readingLevel, ReadingLevel.a2);
      expect(find.text('Edit preset'), findsNothing);
    });

    testWidgets('renames a preset and makes it the default', (tester) async {
      await pumpLoaded(tester);
      await tester.tap(find.text(_chat));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('preset_editor_name')),
        'Friends',
      );
      await tester.ensureVisible(
        find.byKey(const Key('preset_editor_default')),
      );
      await tester.tap(find.byKey(const Key('preset_editor_default')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('preset_editor_save')));
      await settle(tester);
      expect(state().presets[1].name, 'Friends');
      expect(state().defaultId, 'builtin-chatCasual');
      expect(find.text('Friends'), findsOneWidget);
    });

    testWidgets('creates a preset with the FAB', (tester) async {
      await pumpLoaded(tester);
      await tester.tap(find.byKey(const Key('presets_add')));
      await settle(tester);
      expect(find.text('New preset'), findsWidgets);

      await tester.tap(find.byKey(const Key('preset_editor_save')));
      await settle(tester);
      expect(find.text('Enter a name'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('preset_editor_name')),
        'Landlord',
      );
      await tester.enterText(
        find.byKey(const Key('preset_form_context')),
        'Text to my landlord',
      );
      await tester.tap(find.byKey(const Key('preset_editor_save')));
      await settle(tester);

      final created = state().presets.last;
      expect(created.name, 'Landlord');
      expect(created.options.context, 'Text to my landlord');
      expect(find.text('Landlord'), findsOneWidget);
    });

    testWidgets('cancel closes the editor without saving', (tester) async {
      await pumpLoaded(tester);
      await tester.tap(find.byKey(const Key('presets_add')));
      await settle(tester);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(state().presets, hasLength(3));
    });

    testWidgets('empty state restores the examples', (tester) async {
      harness.store.values[PresetsRepository.storageKey] = jsonEncode(
        const PresetCollection().toJson(),
      );
      await pumpLoaded(tester);
      expect(find.text('No presets yet'), findsOneWidget);
      await tester.tap(find.byKey(const Key('presets_restore_examples')));
      await settle(tester);
      expect(find.text(_email), findsOneWidget);
      expect(find.text('Added 3 examples'), findsOneWidget);
    });

    testWidgets('restore examples from the menu', (tester) async {
      await pumpLoaded(tester);
      await tester.tap(find.byKey(const Key('presets_menu')));
      await settle(tester);
      await tester.tap(find.text('Restore examples'));
      await settle(tester);
      expect(find.text('All examples are already there'), findsOneWidget);
    });

    testWidgets('imports presets from pasted JSON', (tester) async {
      await pumpLoaded(tester);
      await tester.tap(find.byKey(const Key('presets_menu')));
      await settle(tester);
      await tester.tap(find.text('Import presets'));
      await settle(tester);

      await tester.tap(find.byKey(const Key('presets_import_submit')));
      await settle(tester);
      expect(
        find.text("This doesn't look like exported presets."),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('presets_import_field')),
        'not json',
      );
      await tester.tap(find.byKey(const Key('presets_import_submit')));
      await settle(tester);
      expect(
        find.text("This doesn't look like exported presets."),
        findsOneWidget,
      );

      harness.clipboard = jsonEncode([
        const Preset(id: 'x', name: 'Imported').toJson(),
      ]);
      await tester.tap(find.text('Paste from clipboard'));
      await settle(tester);
      await tester.tap(find.byKey(const Key('presets_import_submit')));
      await settle(tester);
      expect(find.text('Imported 1 preset'), findsOneWidget);
      expect(find.text('Imported'), findsOneWidget);
    });

    testWidgets('cancelling the import changes nothing', (tester) async {
      await pumpLoaded(tester);
      await tester.tap(find.byKey(const Key('presets_menu')));
      await settle(tester);
      await tester.tap(find.text('Import presets'));
      await settle(tester);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(state().presets, hasLength(3));
    });

    testWidgets('exports all presets to the clipboard', (tester) async {
      await pumpLoaded(tester);
      await tester.tap(find.byKey(const Key('presets_menu')));
      await settle(tester);
      await tester.tap(find.text('Export presets'));
      await settle(tester);
      await tester.tap(find.byKey(const Key('presets_export_copy')));
      await settle(tester);
      expect(find.text('Copied to clipboard'), findsOneWidget);
      final json = jsonDecode(harness.clipboard!) as Map<String, dynamic>;
      expect(json['presets'], hasLength(3));
    });

    testWidgets('dismissing the export sheet does nothing', (tester) async {
      await pumpLoaded(tester);
      await tester.tap(find.byKey(const Key('presets_menu')));
      await settle(tester);
      await tester.tap(find.text('Export presets'));
      await settle(tester);
      await tester.tapAt(const Offset(10, 10));
      await settle(tester);
      expect(harness.clipboard, isNull);
      expect(harness.shared, isEmpty);
    });

    testWidgets('reports export failures', (tester) async {
      await pumpLoaded(tester);
      harness.shared.clear();
      await tester.tap(find.byKey(const Key('presets_menu')));
      await settle(tester);
      await tester.tap(find.text('Export presets'));
      await settle(tester);
      // Replace the stub installed by the harness with a failing one.
      PresetsShare.share = (
        text, {
        required fileName,
        required mimeType,
      }) async => throw StateError('unsupported');
      await tester.tap(find.byKey(const Key('presets_export_share')));
      await settle(tester);
      expect(find.text("Couldn't export"), findsOneWidget);
    });

    testWidgets('glossaries action calls back', (tester) async {
      var opened = 0;
      await pumpLoaded(tester, onOpenGlossaries: () => opened++);
      await tester.tap(find.byKey(const Key('presets_open_glossaries')));
      expect(opened, 1);
    });

    testWidgets('reorders by dragging the handle', (tester) async {
      await pumpLoaded(tester);
      final handle = find.byIcon(Icons.drag_indicator).first;
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, 200));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 100));
      await tester.pump();
      await gesture.up();
      await settle(tester);
      expect(state().presets.first.builtIn, isNot(BuiltInPreset.emailFormal));
    });

    testWidgets('shows a retry button when loading fails', (tester) async {
      final failing = _MockStore();
      var calls = 0;
      when(() => failing.read(any())).thenAnswer((_) async {
        if (calls++ == 0) throw StateError('io');
        return null;
      });
      final cubit = PresetsCubit(repository: PresetsRepository(store: failing));
      addTearDown(cubit.close);
      await cubit.load();
      await harness.pump(
        tester,
        BlocProvider<PresetsCubit>.value(
          value: cubit,
          child: const PresetsPage(),
        ),
      );
      await settle(tester);
      expect(find.text("Couldn't load your presets."), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await settle(tester);
      expect(find.text(_email), findsOneWidget);
    });
  });
}
