import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/phrasebook/widgets/phrasebook_labels.dart'
    show maybePhrasebookRepository;
import 'package:mozhi/practice/widgets/practice_entry_points.dart'
    show PracticeMenuLabel, maybePracticeRepository;
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/recent_pairs_sheet.dart';
import 'package:mozhi/translate/widgets/shortcuts_help.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';

/// Entries of the translate screen's "More tools" menu.
///
/// The dictionary and conversation mode are tabs of their own (see
/// `AppDestination.all`), not entries here. Tools with an entry point on
/// the screen are not repeated: image translation (the Camera chip of the
/// empty screen, the camera button of the input), comparing engines (the
/// tools under a translation), reading the translation slowly (a long
/// press on its Listen button).
enum TranslateTool {
  image(AppRoutes.image, Icons.photo_camera_outlined),
  documents(AppRoutes.documents, Icons.description_outlined),
  webPage(AppRoutes.web, Icons.language),
  transcribe(AppRoutes.transcribe, Icons.subtitles_outlined),
  phrasebook(AppRoutes.phrasebook, Icons.collections_bookmark_outlined),
  practice(AppRoutes.practice, Icons.school_outlined),
  recentPairs(null, Icons.history),
  shortcuts(null, Icons.keyboard_outlined);

  new(this.route, this.icon);

  /// Route pushed on top of the translate screen (null: opens a sheet or a
  /// dialog).
  final String? route;
  final IconData icon;

  String label(AppLocalizations l10n) => switch (this) {
    TranslateTool.image => l10n.translateToolImage,
    TranslateTool.documents => l10n.translateToolDocuments,
    TranslateTool.webPage => l10n.translateToolWebPage,
    TranslateTool.transcribe => l10n.translateToolTranscribe,
    TranslateTool.phrasebook => l10n.translateToolPhrasebook,
    TranslateTool.practice => l10n.practiceTitle,
    TranslateTool.recentPairs => l10n.translateRecentPairsTitle,
    TranslateTool.shortcuts => l10n.translateKeyboardShortcuts,
  };
}

/// Whether the output card's Listen button can read the translation: there
/// is one, in a language that is not a custom one.
bool canListenToTranslation(TranslateState state) =>
    state.output.trim().isNotEmpty && !state.target.isCustom;

/// Whether a hardware keyboard has shown itself this session: a key no
/// on-screen keyboard sends (a modifier, Tab, Escape, an arrow or a
/// function key) was pressed. See [MoreToolsButton].
abstract final class HardwareKeyboardSeen {
  static bool _seen = false;
  static bool _listening = false;

  /// Keys only a hardware keyboard sends.
  static final Set<LogicalKeyboardKey> _keys = {
    LogicalKeyboardKey.tab,
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.f1,
  };

  /// Whether such a key was pressed since [listen].
  static bool get value => _seen;

  /// Starts watching the keys (once).
  static void listen() {
    if (_listening) return;
    _listening = true;
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  static bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent && _keys.contains(event.logicalKey)) {
      _seen = true;
    }
    return false;
  }

  /// Forgets what was seen and stops watching (tests).
  @visibleForTesting
  static void reset() {
    if (_listening) HardwareKeyboard.instance.removeHandler(_onKey);
    _listening = false;
    _seen = false;
  }
}

/// App bar overflow menu with the tools that have no other entry point on
/// the screen: document and web page translation, the recent language
/// pairs (also on a long press of the swap button and on the empty
/// screen) and, where shortcuts are of use, the keyboard shortcut cheat
/// sheet. Image translation is offered here only while there are no
/// engines (the screen shows neither its Camera chip nor the input then).
///
/// The shortcuts show on wide layouts ([TranslateLayout.wideBreakpoint]),
/// in a desktop browser, or once a hardware keyboard has shown itself
/// ([HardwareKeyboardSeen]). Recent pairs are only offered while engines
/// are available.
class MoreToolsButton extends StatefulWidget {
  const new({super.key});

  @override
  State<MoreToolsButton> createState() => _MoreToolsButtonState();
}

class _MoreToolsButtonState extends State<MoreToolsButton> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboardSeen.listen();
  }

  void _open(TranslateTool tool) {
    switch (tool) {
      case TranslateTool.recentPairs:
        unawaited(showRecentPairsSheet(context));
      case TranslateTool.shortcuts:
        unawaited(showTranslateShortcuts(context));
      case TranslateTool.image ||
          TranslateTool.documents ||
          TranslateTool.webPage ||
          TranslateTool.transcribe ||
          TranslateTool.phrasebook ||
          TranslateTool.practice:
        unawaited(context.push<void>(tool.route!));
    }
  }

  /// Whether the keyboard shortcuts are worth offering.
  bool _offersShortcuts() {
    final wide =
        MediaQuery.sizeOf(context).width >= TranslateLayout.wideBreakpoint;
    final desktopWeb =
        kIsWeb &&
        switch (defaultTargetPlatform) {
          TargetPlatform.linux ||
          TargetPlatform.macOS ||
          TargetPlatform.windows => true,
          _ => false,
        };
    return wide || desktopWeb || HardwareKeyboardSeen.value;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return PopupMenuButton<TranslateTool>(
      key: const Key('translate_more_tools'),
      tooltip: l10n.translateMoreTools,
      icon: const Icon(Icons.more_vert),
      onSelected: _open,
      itemBuilder: (context) {
        final state = context.read<TranslateCubit>().state;
        final hasEngines = state.engines.isNotEmpty;
        final shortcuts = _offersShortcuts();
        final hasPhrasebook = maybePhrasebookRepository(context) != null;
        final hasPractice = maybePracticeRepository(context) != null;
        bool offered(TranslateTool tool) => switch (tool) {
          TranslateTool.image => !hasEngines,
          TranslateTool.recentPairs => hasEngines,
          TranslateTool.shortcuts => shortcuts,
          // Where the app provides one.
          TranslateTool.phrasebook => hasPhrasebook,
          TranslateTool.practice => hasPractice,
          TranslateTool.documents ||
          TranslateTool.webPage ||
          TranslateTool.transcribe => true,
        };
        final tools = TranslateTool.values.where(offered).toList();
        // The divider goes above the first tool of the translate screen.
        final firstScreenTool = tools
            .where(
              (tool) =>
                  tool == TranslateTool.recentPairs ||
                  tool == TranslateTool.shortcuts,
            )
            .firstOrNull;
        return [
          for (final tool in tools) ...[
            if (tool == firstScreenTool) const PopupMenuDivider(),
            PopupMenuItem(
              key: ValueKey('translate_tool_${tool.name}'),
              value: tool,
              child: Row(
                children: [
                  Icon(tool.icon),
                  const SizedBox(width: 12),
                  Flexible(
                    // Practice counts the cards due in a badge.
                    child: tool == TranslateTool.practice
                        ? const PracticeMenuLabel()
                        : Text(tool.label(l10n)),
                  ),
                ],
              ),
            ),
          ],
        ];
      },
    );
  }
}
