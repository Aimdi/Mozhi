import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/shortcuts_help.dart';

/// Entries of the translate screen's "More tools" menu.
enum TranslateTool {
  image('/image', Icons.photo_camera_outlined),
  documents('/documents', Icons.description_outlined),
  webPage('/web', Icons.language),
  conversation('/conversation', Icons.forum_outlined),
  shortcuts(null, Icons.keyboard_outlined);

  new(this.route, this.icon);

  /// Route pushed on top of the translate screen (null: opens a dialog).
  final String? route;
  final IconData icon;

  String label(AppLocalizations l10n) => switch (this) {
    TranslateTool.image => l10n.translateToolImage,
    TranslateTool.documents => l10n.translateToolDocuments,
    TranslateTool.webPage => l10n.translateToolWebPage,
    TranslateTool.conversation => l10n.translateToolConversation,
    TranslateTool.shortcuts => l10n.translateKeyboardShortcuts,
  };
}

/// App bar overflow menu with the other translators (image, documents, web
/// page, conversation) and the keyboard shortcut cheat sheet.
class MoreToolsButton extends StatelessWidget {
  const new({super.key});

  void _open(BuildContext context, TranslateTool tool) {
    final route = tool.route;
    if (route == null) {
      unawaited(showTranslateShortcuts(context));
    } else {
      unawaited(context.push<void>(route));
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
      itemBuilder: (context) => [
        for (final tool in TranslateTool.values) ...[
          if (tool == TranslateTool.shortcuts) const PopupMenuDivider(),
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
      ],
    );
  }
}
