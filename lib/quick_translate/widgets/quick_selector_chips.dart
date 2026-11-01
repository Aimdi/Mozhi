import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/engine_selector.dart' show EngineIcon;
import 'package:translation_repository/translation_repository.dart';

/// Chip showing the target language; tapping opens the compact picker.
class QuickTargetChip extends StatelessWidget {
  const new({required this.target, this.onPressed, super.key});

  final Language target;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ActionChip(
      key: const Key('quick_translate_target_chip'),
      tooltip: l10n.translateTargetLanguage(context.languageName(target)),
      avatar: target.isCustom
          ? const Icon(Icons.auto_awesome_outlined)
          : LanguageAvatar(code: target.code, size: 22),
      label: _ChipLabel(text: context.languageName(target)),
      onPressed: onPressed,
    );
  }
}

/// Chip showing the engine; tapping opens a menu of all [engines].
class QuickEngineChip extends StatelessWidget {
  const new({
    required this.engine,
    required this.engines,
    required this.onSelected,
    super.key,
  });

  final TranslationEngine? engine;
  final List<TranslationEngine> engines;
  final ValueChanged<TranslationEngine> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final current = engine;
    if (current == null) return const SizedBox.shrink();
    return MenuAnchor(
      menuChildren: [
        for (final candidate in engines)
          MenuItemButton(
            key: Key('quick_translate_engine_${candidate.id}'),
            leadingIcon: EngineIcon(engine: candidate, size: 20),
            trailingIcon: candidate.id == current.id
                ? Icon(Icons.check, color: theme.colorScheme.primary)
                : null,
            onPressed: () => onSelected(candidate),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    candidate.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (candidate.subtitle case final String subtitle
                      when subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppPalette.of(context).secondaryText,
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
      builder: (context, controller, _) => ActionChip(
        key: const Key('quick_translate_engine_chip'),
        tooltip: l10n.translateEngineSelectorTooltip,
        avatar: EngineIcon(engine: current),
        label: _ChipLabel(text: current.name),
        onPressed: engines.isEmpty ? null : () => _toggle(controller),
      ),
    );
  }

  static void _toggle(MenuController controller) {
    if (controller.isOpen) {
      controller.close();
    } else {
      controller.open();
    }
  }
}

class _ChipLabel extends StatelessWidget {
  const new({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 2),
        const Icon(Icons.arrow_drop_down, size: 18),
      ],
    );
  }
}
