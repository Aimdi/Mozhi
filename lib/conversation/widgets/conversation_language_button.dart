import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/cubit/conversation_cubit.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:mozhi/conversation/widgets/conversation_language_picker.dart';
import 'package:mozhi/conversation/widgets/side_colors.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// Shows the language [side] speaks; opens the language picker (the
/// current engine's target languages, recent languages first).
class ConversationLanguageButton extends StatelessWidget {
  const new({required this.side, super.key});

  final ConversationSide side;

  Future<void> _pick(BuildContext context, Language selected) async {
    final cubit = context.read<ConversationCubit>();
    final settings = context.read<SettingsCubit>();
    final targets = context.read<TranslateCubit>().state.targetLanguages;
    final picked = await showConversationLanguagePicker(
      context,
      selected: selected,
      languages: targets.isEmpty ? LanguageCatalog.all : targets,
      recent: settings.state.recentLanguages,
    );
    if (picked == null) return;
    cubit.setLanguage(side, picked);
    settings.addRecentLanguage(picked);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = ConversationSideColors.of(context, side);
    final language = context.select<ConversationCubit, Language>(
      (cubit) => cubit.state.languageOf(side),
    );
    return Tooltip(
      message: l10n.conversationChangeLanguage(language.name),
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: l10n.conversationChangeLanguage(language.name),
        excludeSemantics: true,
        // An outlined pill led by the language's avatar; the side's colour
        // draws the outline.
        child: OutlinedButton(
          key: Key('conversation_language_${side.name}'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.onSurface,
            side: BorderSide(color: colors.accent),
            shape: const StadiumBorder(),
            minimumSize: const Size(48, 48),
            padding: const EdgeInsetsDirectional.only(start: 8, end: 12),
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
          ),
          onPressed: () => unawaited(_pick(context, language)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              LanguageAvatar(
                code: language.isCustom ? language.name : language.code,
                size: 28,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  language.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.arrow_drop_down),
            ],
          ),
        ),
      ),
    );
  }
}

/// Swaps the two languages.
class ConversationSwapButton extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('conversation_swap'),
    tooltip: context.l10n.conversationSwapLanguages,
    icon: const Icon(Icons.swap_horiz),
    onPressed: context.read<ConversationCubit>().swapLanguages,
  );
}
