import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/widgets/proofread_labels.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  group('ProofreadLabels', () {
    test('labels every writing style', () {
      expect(WritingStyle.values.map(l10n.proofreadWritingStyle), [
        'General',
        'Academic',
        'Business',
        'Casual',
        'Creative',
        'Email',
      ]);
    });

    test('labels and describes every correction level', () {
      expect(CorrectionLevel.values.map(l10n.proofreadCorrectionLevel), [
        'Light',
        'Standard',
        'Comprehensive',
      ]);
      expect(
        CorrectionLevel.values.map(l10n.proofreadLevelDescription).toSet(),
        hasLength(3),
      );
    });

    test('labels every formality', () {
      expect(Formality.values.map(l10n.proofreadFormality), [
        'Automatic',
        'More formal',
        'Less formal',
        'Prefer formal',
        'Prefer informal',
      ]);
    });

    test('labels known categories and humanizes unknown ones', () {
      expect(
        [
          'grammar',
          'Spelling',
          'punctuation',
          'style',
          'clarity',
          'word choice',
          'word-choice',
          'wordchoice',
          'tone',
          'repetition',
          'fact_check',
          '  ',
        ].map(l10n.proofreadCategory),
        [
          'Grammar',
          'Spelling',
          'Punctuation',
          'Style',
          'Clarity',
          'Word choice',
          'Word choice',
          'Word choice',
          'Tone',
          'Repetition',
          'Fact check',
          '',
        ],
      );
    });

    test('maps errors to messages', () {
      expect(
        l10n.proofreadError(const LlmRefusalException('nope')),
        l10n.proofreadErrorRefused,
      );
      expect(
        l10n.proofreadError(const LlmApiException('x', statusCode: 403)),
        l10n.proofreadErrorAuth,
      );
      expect(
        l10n.proofreadError(const LlmApiException('x', statusCode: 429)),
        l10n.proofreadErrorRateLimited,
      );
      expect(
        l10n.proofreadError(const LlmApiException(' timeout ')),
        'The AI provider returned an error: timeout',
      );
      expect(l10n.proofreadError(null), l10n.proofreadErrorGeneric);
      expect(l10n.proofreadError(StateError('x')), l10n.proofreadErrorGeneric);
    });
  });

  test('proofreadCategoryIcon picks an icon per category', () {
    expect(proofreadCategoryIcon('spelling'), Icons.spellcheck);
    expect(proofreadCategoryIcon('punctuation'), Icons.format_quote_outlined);
    expect(proofreadCategoryIcon('Style'), Icons.brush_outlined);
    expect(proofreadCategoryIcon('tone'), Icons.brush_outlined);
    expect(proofreadCategoryIcon('clarity'), Icons.lightbulb_outline);
    expect(proofreadCategoryIcon('word_choice'), Icons.swap_horiz);
    expect(proofreadCategoryIcon('repetition'), Icons.repeat);
    expect(proofreadCategoryIcon('grammar'), Icons.edit_note);
  });
}
