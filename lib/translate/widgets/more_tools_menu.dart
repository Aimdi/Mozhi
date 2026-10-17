import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/dictionary/view/dictionary_page.dart'
    show DictionaryLaunch;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/listen_button.dart';
import 'package:mozhi/translate/widgets/output_card.dart'
    show translateOutputSpeechId;
import 'package:mozhi/translate/widgets/recent_pairs_sheet.dart';
import 'package:mozhi/translate/widgets/shortcuts_help.dart';

/// Entries of the translate screen's "More tools" menu.
enum TranslateTool {
  image('/image', Icons.photo_camera_outlined),
  documents('/documents', Icons.description_outlined),
  webPage('/web', Icons.language),
  conversation('/conversation', Icons.forum_outlined),
  dictionary(AppRoutes.dictionary, Icons.menu_book_outlined),
  compare(null, Icons.difference_outlined),
  recentPairs(null, Icons.history),
  listenSlowly(null, Icons.slow_motion_video),
  shortcuts(null, Icons.keyboard_outlined);

  new(this.route, this.icon);

  /// Route pushed on top of the translate screen (null: opens a sheet or a
  /// dialog, turns compare mode on or off, or reads the translation
  /// slowly). The dictionary is opened with the input's word, see
  /// [translateDictionaryLocation].
  final String? route;
  final IconData icon;

  String label(AppLocalizations l10n) => switch (this) {
    TranslateTool.image => l10n.translateToolImage,
    TranslateTool.documents => l10n.translateToolDocuments,
    TranslateTool.webPage => l10n.translateToolWebPage,
    TranslateTool.conversation => l10n.translateToolConversation,
    TranslateTool.dictionary => l10n.translateToolDictionary,
    TranslateTool.compare => l10n.translateCompareModeEnter,
    TranslateTool.recentPairs => l10n.translateRecentPairsTitle,
    TranslateTool.listenSlowly => l10n.translateToolListenSlowly,
    TranslateTool.shortcuts => l10n.translateKeyboardShortcuts,
  };
}

/// The word the dictionary opens with: the trimmed input when it is one to
/// three words (`TranslateState.isShortInput`) and at most
/// [TranslateCubit.maxDictionaryWordLength] characters, else null.
String? translateDictionaryWord(TranslateState state) {
  final word = state.input.trim();
  if (!state.isShortInput ||
      word.length > TranslateCubit.maxDictionaryWordLength) {
    return null;
  }
  return word;
}

/// The dictionary location for [state]: its word
/// ([translateDictionaryWord]) in the current languages. The source is the
/// detected language while detecting (when the result is current), and
/// custom languages are left out (the dictionary does not take them).
String translateDictionaryLocation(TranslateState state) {
  final source = state.source;
  final detected = state.isResultStale ? null : state.result?.detectedSource;
  final String? from;
  if (source.isCustom) {
    from = null;
  } else if (source.isAuto && detected != null && detected.isNotEmpty) {
    from = detected;
  } else {
    from = source.code;
  }
  return AppRoutes.dictionaryWord(
    word: translateDictionaryWord(state),
    from: from,
    to: state.target.isCustom ? null : state.target.code,
  );
}

/// Whether the output card's Listen button can read the translation: there
/// is one, in a language that is not a custom one.
bool canListenToTranslation(TranslateState state) =>
    state.output.trim().isNotEmpty && !state.target.isCustom;

/// App bar overflow menu with the other translators (image, documents, web
/// page, conversation), the dictionary, compare mode (also in the "More"
/// tools under a translation; "Exit compare mode" while it is on), the
/// recent language pairs (also on a long press of the swap button),
/// reading the translation slowly (also on a long press of its Listen
/// button) and the keyboard shortcut cheat sheet.
///
/// The dictionary opens with the input's word and looks it up right away
/// ([DictionaryLaunch.lookUp]) when the input is a word or short phrase.
/// Recent pairs and slow reading are only offered while engines are
/// available; slow reading is disabled while there is no translation the
/// output card's Listen button could read ([canListenToTranslation]).
class MoreToolsButton extends StatelessWidget {
  const new({super.key});

  void _open(BuildContext context, TranslateTool tool) {
    switch (tool) {
      case TranslateTool.dictionary:
        final state = context.read<TranslateCubit>().state;
        final lookUp = translateDictionaryWord(state) != null;
        unawaited(
          context.push<void>(
            translateDictionaryLocation(state),
            extra: lookUp ? DictionaryLaunch.lookUp : null,
          ),
        );
      case TranslateTool.compare:
        final cubit = context.read<TranslateCubit>();
        cubit.setCompareMode(enabled: !cubit.state.compareMode);
      case TranslateTool.recentPairs:
        unawaited(showRecentPairsSheet(context));
      case TranslateTool.listenSlowly:
        final state = context.read<TranslateCubit>().state;
        if (!canListenToTranslation(state)) return;
        unawaited(
          readAloud(
            context,
            id: translateOutputSpeechId,
            text: state.output,
            languageCode: state.target.code,
            slow: true,
          ),
        );
      case TranslateTool.shortcuts:
        unawaited(showTranslateShortcuts(context));
      case TranslateTool.image ||
          TranslateTool.documents ||
          TranslateTool.webPage ||
          TranslateTool.conversation:
        unawaited(context.push<void>(tool.route!));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return PopupMenuButton<TranslateTool>(
      key: const Key('translate_more_tools'),
      tooltip: l10n.translateMoreTools,
      icon: const Icon(Icons.more_vert),
      onSelected: (tool) => _open(context, tool),
      itemBuilder: (context) {
        final state = context.read<TranslateCubit>().state;
        final hasEngines = state.engines.isNotEmpty;
        final compares = state.compareMode || state.engines.length > 1;
        bool offered(TranslateTool tool) => switch (tool) {
          TranslateTool.recentPairs || TranslateTool.listenSlowly => hasEngines,
          TranslateTool.compare => compares,
          _ => true,
        };
        // The divider goes above the first tool of the translate screen.
        final firstScreenTool = compares
            ? TranslateTool.compare
            : TranslateTool.recentPairs;
        String label(TranslateTool tool) =>
            tool == TranslateTool.compare && state.compareMode
            ? l10n.translateCompareModeExit
            : tool.label(l10n);
        return [
          for (final tool in TranslateTool.values)
            if (offered(tool)) ...[
              if ((tool == firstScreenTool && hasEngines) ||
                  (tool == TranslateTool.shortcuts && !hasEngines))
                const PopupMenuDivider(),
              PopupMenuItem(
                key: ValueKey('translate_tool_${tool.name}'),
                value: tool,
                enabled:
                    tool != TranslateTool.listenSlowly ||
                    canListenToTranslation(state),
                child: Row(
                  children: [
                    Icon(tool.icon),
                    const SizedBox(width: 12),
                    Flexible(child: Text(label(tool))),
                  ],
                ),
              ),
            ],
        ];
      },
    );
  }
}
