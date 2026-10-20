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

/// Opens the language picker for [side] (the current engine's target
/// languages, recent languages first) and applies the choice, which also
/// becomes a recent language.
Future<void> pickConversationLanguage(
  BuildContext context,
  ConversationSide side,
) async {
  final cubit = context.read<ConversationCubit>();
  final settings = context.read<SettingsCubit>();
  final targets = context.read<TranslateCubit>().state.targetLanguages;
  final picked = await showConversationLanguagePicker(
    context,
    selected: cubit.state.languageOf(side),
    languages: targets.isEmpty ? LanguageCatalog.all : targets,
    recent: settings.state.recentLanguages,
  );
  if (picked == null) return;
  cubit.setLanguage(side, picked);
  settings.addRecentLanguage(picked);
}

/// Shows the language [side] speaks; opens the language picker
/// ([pickConversationLanguage]). Each half of the face-to-face layout has
/// one.
class ConversationLanguageButton extends StatelessWidget {
  const new({required this.side, super.key});

  final ConversationSide side;

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
          onPressed: () => unawaited(pickConversationLanguage(context, side)),
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

/// The language pair as one outlined pill: side A's language, the swap
/// button and side B's language (source ⇄ target). Each language opens
/// its picker ([pickConversationLanguage]).
class ConversationLanguagePill extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      key: const Key('conversation_language_pill'),
      decoration: ShapeDecoration(
        shape: StadiumBorder(
          side: BorderSide(color: Theme.of(context).colorScheme.outline),
        ),
      ),
      child: const Padding(
        padding: EdgeInsets.all(2),
        child: Row(
          children: [
            Expanded(child: _PillLanguage(side: ConversationSide.a)),
            ConversationSwapButton(),
            Expanded(child: _PillLanguage(side: ConversationSide.b)),
          ],
        ),
      ),
    );
  }
}

/// One language of the [ConversationLanguagePill]: its avatar and name.
class _PillLanguage extends StatelessWidget {
  const new({required this.side});

  final ConversationSide side;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final language = context.select<ConversationCubit, Language>(
      (cubit) => cubit.state.languageOf(side),
    );
    final label = l10n.conversationChangeLanguage(language.name);
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: InkWell(
          key: Key('conversation_language_${side.name}'),
          customBorder: const StadiumBorder(),
          onTap: () => unawaited(pickConversationLanguage(context, side)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  LanguageAvatar(
                    code: language.isCustom ? language.name : language.code,
                    size: 24,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      language.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
