import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/presets/models/glossary.dart';
import 'package:mozhi/presets/models/preset.dart';
import 'package:mozhi/presets/widgets/preset_labels.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  group('PresetLabels', () {
    test('presetName', () {
      expect(l10n.presetName(const Preset(id: 'a', name: ' Mine ')), 'Mine');
      expect(
        l10n.presetName(Preset.example(BuiltInPreset.emailFormal)),
        'Email to colleague (formal)',
      );
      expect(
        l10n.presetName(Preset.example(BuiltInPreset.chatCasual)),
        'Chat with friends (casual)',
      );
      expect(
        l10n.presetName(Preset.example(BuiltInPreset.simpleA2)),
        'Simple (A2 reading level)',
      );
      expect(l10n.presetName(const Preset(id: 'a')), 'Untitled preset');
    });

    test('presetSummary lists every non-default setting', () {
      expect(
        l10n.presetSummary(const TranslationOptions()),
        'Standard settings',
      );
      expect(
        l10n.presetSummary(
          const TranslationOptions(
            style: TranslationStyle.literal,
            formality: Formality.preferLess,
            readingLevel: ReadingLevel.b2,
            speakerGender: Gender.masculine,
            addresseeGender: Gender.feminine,
            preserveFormatting: false,
            context: ' Note ',
          ),
        ),
        'Literal · Prefer informal · Level B2 · Speaker: Masculine · '
        'Addressee: Feminine · Plain text · Context: Note',
      );
    });

    test('enum labels', () {
      expect(
        Formality.values.map(l10n.formalityLabel).toSet(),
        hasLength(Formality.values.length),
      );
      expect(
        Gender.values.map(l10n.genderLabel).toSet(),
        hasLength(Gender.values.length),
      );
      expect(
        ReadingLevel.values.map(l10n.readingLevelLabel).toSet(),
        hasLength(ReadingLevel.values.length),
      );
      expect(l10n.readingLevelLabel(ReadingLevel.c2), startsWith('C2'));
    });

    test('glossary labels', () {
      expect(l10n.languageScopeName('any'), 'Any language');
      expect(l10n.languageScopeName('de'), 'German');
      expect(l10n.languageScopeName('xx-unknown'), 'xx-unknown');
      expect(
        l10n.glossaryScope(const Glossary(id: 'g', sourceCode: 'en')),
        'English → Any language',
      );
      expect(l10n.glossaryName(const Glossary(id: 'g')), 'Untitled glossary');
      expect(l10n.glossaryName(const Glossary(id: 'g', name: ' X ')), 'X');
    });
  });
}
