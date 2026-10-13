import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/image_translate/cubit/image_translate_cubit.dart';
import 'package:mozhi/image_translate/widgets/image_language_picker.dart';
import 'package:mozhi/image_translate/widgets/image_translate_labels.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// Source and target of the image translation. Starts from the translator's
/// languages; changes only apply to image translation.
class ImageLanguageBar extends StatelessWidget {
  const ImageLanguageBar({super.key});

  Future<void> _pick(BuildContext context, {required bool source}) async {
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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<ImageTranslateCubit>().state;
    final languages = context.select<TranslateCubit, List<Language>>(
      (cubit) => cubit.state.sourceLanguages,
    );
    final detected = state.result?.detectedSource;
    final sourceLabel = state.source.isAuto && detected != null
        ? l10n.translateDetectedLanguage(
            imageLanguageNameFor(detected, languages),
          )
        : imageLanguageLabel(l10n, state.source);
    final targetLabel = imageLanguageLabel(l10n, state.target);
    return Row(
      children: [
        Expanded(
          child: _LanguageButton(
            key: const Key('image_translate_source_button'),
            label: sourceLabel,
            semanticLabel: l10n.translateSourceLanguage(sourceLabel),
            icon: state.source.isAuto ? Icons.auto_awesome_outlined : null,
            onPressed: () => unawaited(_pick(context, source: true)),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: ExcludeSemantics(child: Icon(Icons.arrow_forward)),
        ),
        Expanded(
          child: _LanguageButton(
            key: const Key('image_translate_target_button'),
            label: targetLabel,
            semanticLabel: l10n.translateTargetLanguage(targetLabel),
            onPressed: () => unawaited(_pick(context, source: false)),
          ),
        ),
      ],
    );
  }
}

class _LanguageButton extends StatelessWidget {
  const _LanguageButton({
    required this.label,
    required this.semanticLabel,
    required this.onPressed,
    this.icon,
    super.key,
  });

  final String label;
  final String semanticLabel;
  final IconData? icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      excludeSemantics: true,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}
