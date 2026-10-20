import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/language_pair_bar.dart';
import 'package:mozhi/image_translate/cubit/image_translate_cubit.dart';
import 'package:mozhi/image_translate/widgets/image_language_picker.dart';
import 'package:mozhi/image_translate/widgets/image_translate_labels.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// Lets the user pick the [source] (else the target) language of the image
/// translation (the translator's languages, else the catalogue) and applies
/// it to the [ImageTranslateCubit] above [context], which translates again.
/// Used by the [ImageLanguageBar], and to choose the language of the text
/// when it could not be detected or was read poorly.
Future<void> pickImageLanguage(
  BuildContext context, {
  required bool source,
}) async {
  final l10n = context.l10n;
  final cubit = context.read<ImageTranslateCubit>();
  final translate = context.read<TranslateCubit>().state;
  final state = cubit.state;
  final languages = source
      ? (translate.sourceLanguages.length > 1
            ? translate.sourceLanguages
            : [Language.auto, ...LanguageCatalog.all])
      : (translate.targetLanguages.isNotEmpty
            ? translate.targetLanguages
            : LanguageCatalog.all);
  final current = source ? state.source : state.target;
  final picked = await showImageLanguagePicker(
    context,
    languages: languages,
    selected: current,
    title: source
        ? l10n.translateSourceLanguage(imageLanguageLabel(l10n, current))
        : l10n.translateTargetLanguage(imageLanguageLabel(l10n, current)),
  );
  if (picked == null || cubit.isClosed) return;
  unawaited(source ? cubit.setSource(picked) : cubit.setTarget(picked));
}

/// Source and target of the image translation, in the look of the
/// translate screen's language bar ([LanguagePairBar]); a detected source
/// shows a sparkle, like there. Starts from the translator's languages;
/// changes only apply to image translation. The languages cannot be
/// swapped here: an arrow points from the photo's language to the target.
class ImageLanguageBar extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<ImageTranslateCubit>().state;
    final languages = context.select<TranslateCubit, List<Language>>(
      (cubit) => cubit.state.sourceLanguages,
    );
    final detected = state.source.isAuto
        ? state.result?.detectedSource
        : null;
    final detectedName = detected == null
        ? null
        : imageLanguageNameFor(detected, languages);
    // Read out (and shown on hover) in full: "Detected: Japanese".
    final sourceDescription = detectedName == null
        ? imageLanguageLabel(l10n, state.source)
        : l10n.translateDetectedLanguage(detectedName);
    final targetLabel = imageLanguageLabel(l10n, state.target);
    return LanguagePairBar(
      key: const Key('image_translate_language_bar'),
      source: LanguagePairSide(
        key: const Key('image_translate_source_button'),
        label: detectedName ?? sourceDescription,
        semanticLabel: l10n.translateSourceLanguage(sourceDescription),
        tooltip: sourceDescription,
        icon: detectedName != null
            ? Icons.auto_awesome_outlined
            : state.source.isCustom
            ? Icons.auto_awesome
            : null,
        onPressed: () => unawaited(pickImageLanguage(context, source: true)),
      ),
      target: LanguagePairSide(
        key: const Key('image_translate_target_button'),
        label: targetLabel,
        semanticLabel: l10n.translateTargetLanguage(targetLabel),
        icon: state.target.isCustom ? Icons.auto_awesome : null,
        onPressed: () => unawaited(pickImageLanguage(context, source: false)),
      ),
    );
  }
}
