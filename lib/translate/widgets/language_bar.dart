import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/language_picker_sheet.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';

/// Source button, swap button and target button.
class LanguageBar extends StatelessWidget {
  const new({super.key});

  Future<void> _pick(BuildContext context, {required bool source}) async {
    final cubit = context.read<TranslateCubit>();
    final picked = await showLanguagePicker(context, source: source);
    if (picked == null) return;
    if (source) {
      cubit.setSource(picked);
    } else {
      cubit.setTarget(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return BlocBuilder<TranslateCubit, TranslateState>(
      buildWhen: (previous, current) =>
          previous.source != current.source ||
          previous.target != current.target ||
          previous.result?.detectedSource != current.result?.detectedSource ||
          previous.sourceLanguages != current.sourceLanguages ||
          previous.canSwap != current.canSwap,
      builder: (context, state) {
        final detected = state.result?.detectedSource;
        final String sourceLabel;
        if (!state.source.isAuto) {
          sourceLabel = state.source.name;
        } else if (detected != null) {
          sourceLabel = l10n.translateDetectedLanguage(
            languageNameFor(detected, state.sourceLanguages),
          );
        } else {
          sourceLabel = l10n.translateDetectLanguage;
        }
        return Row(
          children: [
            Expanded(
              child: _LanguageButton(
                key: const Key('translate_source_button'),
                label: sourceLabel,
                semanticLabel: l10n.translateSourceLanguage(sourceLabel),
                icon: state.source.isAuto ? Icons.auto_awesome_outlined : null,
                onPressed: () => _pick(context, source: true),
              ),
            ),
            SizedBox(
              width: TranslateLayout.paneGap,
              child: IconButton(
                key: const Key('translate_swap_button'),
                tooltip: l10n.translateSwapLanguages,
                icon: const Icon(Icons.swap_horiz),
                onPressed: state.canSwap
                    ? context.read<TranslateCubit>().swap
                    : null,
              ),
            ),
            Expanded(
              child: _LanguageButton(
                key: const Key('translate_target_button'),
                label: state.target.name,
                semanticLabel: l10n.translateTargetLanguage(state.target.name),
                icon: state.target.isCustom ? Icons.auto_awesome : null,
                onPressed: () => _pick(context, source: false),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _LanguageButton extends StatelessWidget {
  const new({
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
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: semanticLabel,
      excludeSemantics: true,
      child: FilledButton.tonal(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          backgroundColor: theme.colorScheme.surfaceContainerHigh,
          foregroundColor: theme.colorScheme.onSurface,
        ),
        onPressed: onPressed,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
            ),
            const Icon(Icons.expand_more, size: 20),
          ],
        ),
      ),
    );
  }
}
