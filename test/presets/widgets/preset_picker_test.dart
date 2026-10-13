@Timeout(Duration(seconds: 60))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/presets/models/preset.dart';
import 'package:mozhi/presets/widgets/preset_picker.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

const _email = 'Email to colleague (formal)';
const _simple = 'Simple (A2 reading level)';

void main() {
  group('PresetPicker', () {
    late PresetsHarness harness;
    late List<TranslationOptions> changes;
    late int manage;
    setUp(() {
      changes = [];
      manage = 0;
    });

    Future<void> pump(
      WidgetTester tester,
      TranslationOptions value, {
      PresetPickerVariant variant = PresetPickerVariant.chips,
      bool withManage = true,
    }) async {
      await harness.presets.load();
      await harness.presets.setDefault('builtin-simpleA2');
      await harness.pump(
        tester,
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: PresetPicker(
              value: value,
              variant: variant,
              onChanged: changes.add,
              onManagePresets: withManage ? () => manage++ : null,
            ),
          ),
        ),
      );
      await settle(tester);
    }

    ChoiceChip chip(WidgetTester tester, Key key) =>
        tester.widget<ChoiceChip>(find.byKey(key));

    group('chips', () {
      testWidgets('selects Default for standard options', (tester) async {
        harness = PresetsHarness();
        addTearDown(harness.close);
        await pump(
          tester,
          const TranslationOptions(glossary: {'a': 'b'}, instructions: 'x'),
        );
        expect(
          chip(tester, const Key('preset_picker_default')).selected,
          isTrue,
        );
        expect(find.text(_email), findsOneWidget);
        // The default preset is starred while not selected.
        expect(find.byIcon(Icons.star_rounded), findsOneWidget);
      });

      testWidgets('selects the matching preset', (tester) async {
        harness = PresetsHarness();
        addTearDown(harness.close);
        await pump(tester, BuiltInPreset.simpleA2.options);
        expect(
          chip(tester, const Key('preset_picker_builtin-simpleA2')).selected,
          isTrue,
        );
        expect(
          chip(tester, const Key('preset_picker_default')).selected,
          isFalse,
        );
        expect(find.byIcon(Icons.star_rounded), findsNothing);
      });

      testWidgets('choosing a preset keeps glossary and instructions', (
        tester,
      ) async {
        harness = PresetsHarness();
        addTearDown(harness.close);
        await pump(
          tester,
          const TranslationOptions(
            style: TranslationStyle.literal,
            glossary: {'cloud': 'Wolke'},
            instructions: 'Shorter',
          ),
        );
        await tester.tap(find.text(_email));
        await settle(tester);
        expect(changes.single.formality, Formality.more);
        expect(changes.single.style, TranslationStyle.natural);
        expect(changes.single.glossary, {'cloud': 'Wolke'});
        expect(changes.single.instructions, 'Shorter');
      });

      testWidgets('Default resets the settings', (tester) async {
        harness = PresetsHarness();
        addTearDown(harness.close);
        await pump(
          tester,
          const TranslationOptions(
            readingLevel: ReadingLevel.c1,
            glossary: {'a': 'b'},
          ),
        );
        await tester.tap(find.byKey(const Key('preset_picker_default')));
        await settle(tester);
        expect(changes.single, const TranslationOptions(glossary: {'a': 'b'}));
      });

      testWidgets('manage presets calls back', (tester) async {
        harness = PresetsHarness();
        addTearDown(harness.close);
        await pump(tester, const TranslationOptions());
        await tester.ensureVisible(
          find.byKey(const Key('preset_picker_manage')),
        );
        await tester.tap(find.byKey(const Key('preset_picker_manage')));
        expect(manage, 1);
      });

      testWidgets('hides manage presets without a callback', (tester) async {
        harness = PresetsHarness();
        addTearDown(harness.close);
        await pump(tester, const TranslationOptions(), withManage: false);
        expect(find.byKey(const Key('preset_picker_manage')), findsNothing);
      });

      testWidgets('updates when presets change', (tester) async {
        harness = PresetsHarness();
        addTearDown(harness.close);
        await pump(tester, const TranslationOptions());
        await harness.presets.add(
          name: 'Brand new',
          options: const TranslationOptions(),
        );
        await settle(tester);
        expect(find.text('Brand new'), findsOneWidget);
      });
    });

    group('dropdown', () {
      testWidgets('shows Custom when no preset matches', (tester) async {
        harness = PresetsHarness();
        addTearDown(harness.close);
        await pump(
          tester,
          const TranslationOptions(context: 'Unique'),
          variant: PresetPickerVariant.dropdown,
        );
        expect(find.text('Preset'), findsOneWidget);
        expect(find.text('Custom'), findsOneWidget);
      });

      testWidgets('selects presets, Default and manage', (tester) async {
        harness = PresetsHarness();
        addTearDown(harness.close);
        await pump(
          tester,
          BuiltInPreset.emailFormal.options,
          variant: PresetPickerVariant.dropdown,
        );
        expect(find.text(_email), findsOneWidget);

        await tester.tap(find.byKey(const Key('preset_picker_dropdown')));
        await settle(tester);
        await tester.tap(find.text(_simple).last);
        await settle(tester);
        expect(changes.last.readingLevel, ReadingLevel.a2);
        expect(changes.last.formality, Formality.automatic);

        await tester.tap(find.byKey(const Key('preset_picker_dropdown')));
        await settle(tester);
        await tester.tap(find.text('Default').last);
        await settle(tester);
        expect(changes.last, const TranslationOptions());

        await tester.tap(find.byKey(const Key('preset_picker_dropdown')));
        await settle(tester);
        await tester.tap(find.text('Manage presets').last);
        await settle(tester);
        expect(manage, 1);
        expect(changes, hasLength(2));
      });

      testWidgets('selecting the current entry does nothing', (tester) async {
        harness = PresetsHarness();
        addTearDown(harness.close);
        await pump(
          tester,
          const TranslationOptions(),
          variant: PresetPickerVariant.dropdown,
        );
        await tester.tap(find.byKey(const Key('preset_picker_dropdown')));
        await settle(tester);
        await tester.tap(find.text('Default').last);
        await settle(tester);
        expect(changes, isEmpty);
      });
    });
  });
}
