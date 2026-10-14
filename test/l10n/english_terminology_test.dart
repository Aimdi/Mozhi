import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';

/// The English template, with its metadata (`@key` entries).
Map<String, dynamic> _englishArb() =>
    jsonDecode(File('lib/l10n/arb/app_en.arb').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  group('English terminology', () {
    test('kept history entries are favorites, as on the History screen', () {
      final texts = [
        en.settingsHistoryRetentionDialogBody,
        en.historyRetentionNote(1),
        en.historyRetentionNote(7),
        en.settingsHistoryRetentionConfirmBody(1, 1),
        en.settingsHistoryRetentionConfirmBody(3, 30),
      ];
      for (final text in texts) {
        expect(text, contains(en.historyFilterFavorites), reason: text);
        expect(text, isNot(contains('Starred')), reason: text);
      }
    });

    test('the romanization setting has the name of the output button', () {
      expect(en.settingsShowTransliteration, en.translateRomanizationShow);
      expect(
        en.settingsShowTransliterationSubtitle,
        isNot(contains('transliteration')),
      );
    });

    test('the dictionary engines error does not blame AI providers', () {
      expect(en.dictionaryEnginesErrorTitle, isNot(contains('AI')));
      expect(en.dictionaryEnginesErrorBody, contains('AI provider'));
    });

    test('the machine translation header is not the settings section', () {
      expect(en.translateMtServicesHeader, en.settingsProvidersPresetsMt);
      expect(en.translateMtServicesHeader, isNot(en.settingsSectionServices));
    });

    test('the alignment button says what it shows', () {
      for (final text in [
        en.translateAlignmentShow,
        en.translateAlignmentHide,
        en.translateAlignmentLoading,
      ]) {
        expect(text, contains('matching phrases'), reason: text);
        expect(text.toLowerCase(), isNot(contains('align')), reason: text);
      }
    });

    test('screen readers do not read "Detect language" as a language', () {
      expect(
        en.translateLanguagePairAutoSemantics('German'),
        isNot(contains(en.translateDetectLanguage)),
      );
      expect(
        en.translateLanguagePairAutoSemantics('German'),
        contains('German'),
      );
      expect(
        en.dictionarySourceLanguageAuto,
        isNot(contains(en.dictionaryDetectLanguage)),
      );
    });

    test('quality modes are named Fast and Best', () {
      for (final text in [
        en.settingsQualitySubtitle,
        en.settingsQualityIntro,
        en.translateQualityModesSetUp,
      ]) {
        expect(text, contains(en.translateQualityFast), reason: text);
        expect(text, contains(en.translateQualityBest), reason: text);
      }
      expect(en.settingsQualityIntro, isNot(contains('quick engine')));
      expect(en.translateQualityModesSetUp, isNot(endsWith('here')));
      expect(en.settingsQualityFastDescription, isNot(contains('such as')));
    });

    test('the Fast and Best names match in every locale', () {
      for (final locale in AppLocalizations.supportedLocales) {
        final l10n = lookupAppLocalizations(locale);
        expect(
          l10n.settingsQualityFast,
          l10n.translateQualityFast,
          reason: '$locale',
        );
        expect(
          l10n.settingsQualityBest,
          l10n.translateQualityBest,
          reason: '$locale',
        );
      }
    });

    test('the dictionary asks to add an AI provider like the others', () {
      expect(en.dictionaryNoEngineAction, en.proofreadEmptyAction);
      expect(en.dictionaryNoEngineAction, en.translateAddAiProvider);
      expect(en.dictionaryNoEngineBody, contains('Dedicated translation'));
      expect(en.dictionaryEngine('Claude'), 'Dictionary entries by Claude');
    });

    test('the formality notes chip names its option', () {
      expect(
        en.translateActiveOptionFormalityNotes('my boss'),
        startsWith(en.translateOptionsFormalityNotes),
      );
    });

    test('plain wording', () {
      expect(en.translateRecentPairsNeedsCustom, isNot(contains('takes')));
      expect(en.proofreadVarietyLabel, 'Region');
      expect(
        en.settingsImportSkippedExpired(2),
        isNot(contains('auto-delete setting')),
      );
    });

    test('new strings use straight apostrophes', () {
      for (final text in [
        en.settingsQualityLoadFailed,
        en.translateRefinementFailed('Too many requests.'),
        en.translateOptionsFormalityNotesHint,
        en.dictionaryEnginesErrorTitle,
      ]) {
        expect(text, isNot(contains('’')), reason: text);
        expect(text, contains("'"), reason: text);
      }
    });
  });

  group('English ARB metadata', () {
    final arb = _englishArb();

    String? description(String key) =>
        (arb['@$key'] as Map<String, dynamic>?)?['description'] as String?;

    test('context-dependent labels explain themselves to translators', () {
      const keys = [
        'settingsQualityFast',
        'settingsQualityBest',
        'settingsQualityNone',
        'settingsHistoryRetentionNever',
        'translateRefineMoreFormal',
        'translateRefineMoreCasual',
        'translateRefineShorter',
        'translateRefineSimpler',
        'translateRefineMoreFluent',
        'translateRefineMoreLiteral',
        'translateDictionaryConcise',
        'translateDictionaryStandard',
        'translateDictionaryDetailed',
        'translateAlignmentFocused',
        'translateRefinementFailed',
        'translateRefinementUndo',
        'translateRefinementReplaces',
        'translateRefinementCancel',
        'dictionaryEngine',
        'translateLanguagePairAutoSemantics',
        'dictionarySourceLanguageAuto',
      ];
      for (final key in keys) {
        final text = description(key);
        expect(text, isNotNull, reason: key);
        expect(text, isNot(key), reason: key);
        expect(text!.length, greaterThan(20), reason: key);
      }
      expect(description('settingsQualityFast'), contains('translateQuality'));
      expect(description('translateAlignmentFocused'), contains('{source}'));
      expect(description('translateRefinementFailed'), contains('{reason}'));
    });

    test('descriptions use "an" before a vowel sound', () {
      final wrong = RegExp(
        r'\ba (elementary|intermediate|upper|advanced)\b',
        caseSensitive: false,
      );
      for (final MapEntry(:key, :value) in arb.entries) {
        // Metadata entries (not "@@locale").
        if (!key.startsWith('@') || value is! Map<String, dynamic>) continue;
        final text = value['description'] as String? ?? '';
        expect(wrong.hasMatch(text), isFalse, reason: key);
      }
    });

    test('has no unused alignment span label', () {
      expect(arb.containsKey('translateAlignmentSpanSemantics'), isFalse);
    });
  });
}
