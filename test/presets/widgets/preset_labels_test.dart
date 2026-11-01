import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/gen/app_localizations_en.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/presets/cubit/presets_state.dart';
import 'package:mozhi/presets/models/glossary.dart';
import 'package:mozhi/presets/models/preset.dart';
import 'package:mozhi/presets/widgets/preset_labels.dart';
import 'package:translation_repository/translation_repository.dart';

/// English with other context sentences for the examples.
class _OtherLanguage extends AppLocalizationsEn {
  @override
  String get presetsContextEmailFormal => 'Eine E-Mail an Kollegen.';

  @override
  String get presetsContextChatCasual => 'Ein Chat mit Freunden.';
}

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

    group('localizedPreset', () {
      // Another UI language (whatever the translations say today).
      final german = _OtherLanguage();

      test('gives an untouched example its context in the UI language', () {
        final email = Preset.example(BuiltInPreset.emailFormal);
        final shown = german.localizedPreset(email);
        expect(shown.options.context, german.presetsContextEmailFormal);
        expect(shown.options.context, isNot(email.options.context));
        expect(shown.options.formality, Formality.more);
        expect(shown.id, email.id);
        expect(shown.builtIn, BuiltInPreset.emailFormal);
        expect(
          german
              .localizedPreset(Preset.example(BuiltInPreset.chatCasual))
              .options
              .context,
          german.presetsContextChatCasual,
        );
        // English: the stored sentence itself.
        expect(l10n.localizedPreset(email), email);
      });

      test('keeps user presets and changed contexts as they are', () {
        const mine = Preset(
          id: 'a',
          options: TranslationOptions(
            context: 'An email to a colleague at work.',
          ),
        );
        expect(german.localizedPreset(mine), mine);
        final edited = Preset.example(
          BuiltInPreset.emailFormal,
        ).copyWith(options: const TranslationOptions(context: 'Mein Kontext'));
        expect(german.localizedPreset(edited), edited);
        final simple = Preset.example(BuiltInPreset.simpleA2);
        expect(german.localizedPreset(simple), simple);
      });

      test('stores the localised context as the original one', () {
        final email = Preset.example(BuiltInPreset.emailFormal);
        final shown = german.localizedPreset(email).options;
        expect(german.presetStoredOptions(email, shown), email.options);
        final changed = shown.copyWith(context: 'Anders');
        expect(german.presetStoredOptions(email, changed), changed);
        const mine = Preset(id: 'a');
        expect(german.presetStoredOptions(mine, shown), shown);
        final simple = Preset.example(BuiltInPreset.simpleA2);
        expect(
          german.presetStoredOptions(simple, simple.options),
          simple.options,
        );
      });

      test('localizes the presets of a state', () {
        final state = PresetsState(
          presets: [
            Preset.example(BuiltInPreset.chatCasual),
            const Preset(id: 'a', name: 'Mine'),
          ],
          defaultId: 'a',
        );
        final shown = german.localizedPresets(state);
        expect(
          shown.presets.first.options.context,
          german.presetsContextChatCasual,
        );
        expect(shown.presets.last, state.presets.last);
        expect(shown.defaultId, 'a');
        // An applied example is found again.
        expect(
          shown.presetFor(shown.presets.first.options),
          shown.presets.first,
        );
      });
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
