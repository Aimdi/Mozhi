import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/dictionary/view/dictionary_page.dart'
    show DictionaryLaunch;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/recent_pairs_sheet.dart';
import 'package:mozhi/translate/widgets/shortcuts_help.dart';

/// Entries of the translate screen's "More tools" menu.
enum TranslateTool {
  image('/image', Icons.photo_camera_outlined),
  documents('/documents', Icons.description_outlined),
  webPage('/web', Icons.language),
  conversation('/conversation', Icons.forum_outlined),
  dictionary(AppRoutes.dictionary, Icons.menu_book_outlined),
  recentPairs(null, Icons.history),
  shortcuts(null, Icons.keyboard_outlined);

  new(this.route, this.icon);

  /// Route pushed on top of the translate screen (null: opens a sheet or a
  /// dialog). The dictionary is opened with the input's word, see
  /// [translateDictionaryLocation].
  final String? route;
  final IconData icon;

  String label(AppLocalizations l10n) => switch (this) {
    TranslateTool.image => l10n.translateToolImage,
    TranslateTool.documents => l10n.translateToolDocuments,
    TranslateTool.webPage => l10n.translateToolWebPage,
    TranslateTool.conversation => l10n.translateToolConversation,
    TranslateTool.dictionary => l10n.translateToolDictionary,
    TranslateTool.recentPairs => l10n.translateRecentPairsTitle,
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

/// App bar overflow menu with the other translators (image, documents, web
/// page, conversation), the dictionary, the recent language pairs (also
/// on a long press of the swap button) and the keyboard shortcut cheat
/// sheet.
///
/// The dictionary opens with the input's word and looks it up right away
/// ([DictionaryLaunch.lookUp]) when the input is a word or short phrase.
/// Recent pairs are only offered while engines are available.
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
      case TranslateTool.recentPairs:
        unawaited(showRecentPairsSheet(context));
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
        final hasEngines = context
            .read<TranslateCubit>()
            .state
            .engines
            .isNotEmpty;
        return [
          for (final tool in TranslateTool.values)
            if (tool != TranslateTool.recentPairs || hasEngines) ...[
              if (tool == TranslateTool.recentPairs ||
                  (tool == TranslateTool.shortcuts && !hasEngines))
                const PopupMenuDivider(),
              PopupMenuItem(
                key: ValueKey('translate_tool_${tool.name}'),
                value: tool,
                child: Row(
                  children: [
                    Icon(tool.icon),
                    const SizedBox(width: 12),
                    Flexible(child: Text(tool.label(l10n))),
                  ],
                ),
              ),
            ],
        ];
      },
    );
  }
}
