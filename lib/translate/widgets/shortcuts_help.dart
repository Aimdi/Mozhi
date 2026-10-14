import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';

/// One row of the keyboard shortcut cheat sheet.
typedef TranslateShortcutHelp = ({
  String keys,
  String keysSemantics,
  String description,
});

/// Whether shortcuts use ⌘ (macOS / iOS) rather than Ctrl.
bool shortcutUsesCommandKey(TargetPlatform platform) =>
    platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;

/// Number of pinned target languages with a shortcut (Alt+1 to Alt+9).
const translatePinnedShortcutCount = 9;

/// Whether the keyboard has a key for shortcut hints next to list entries:
/// desktop platforms (also in a browser).
bool showsShortcutHints(TargetPlatform platform) =>
    platform == TargetPlatform.macOS ||
    platform == TargetPlatform.windows ||
    platform == TargetPlatform.linux;

/// The modifier keys of the pinned-language shortcuts, shown and spoken:
/// Alt (⌥ Option with [command]) in the apps; in a browser ([web])
/// Ctrl+Alt (⌘⌥), because browsers and ChromeOS use Alt+digit for
/// switching tabs and launching apps.
({List<String> keys, List<String> spoken}) _pinnedModifiers({
  required bool command,
  required bool web,
}) => (
  keys: [
    if (web && command) '⌘' else if (web) 'Ctrl',
    if (command) '⌥' else 'Alt',
  ],
  spoken: [
    if (web && command) 'Command' else if (web) 'Control',
    if (command) 'Option' else 'Alt',
  ],
);

/// The shortcut of pinned target language [index] (zero-based, as in
/// `TranslateState.pinnedTargets`), e.g. "Alt + 1" spoken "Alt 1"; null
/// beyond [translatePinnedShortcutCount]. See [_pinnedModifiers] for
/// [command] and [web].
({String keys, String keysSemantics})? translatePinnedShortcut(
  int index, {
  required bool command,
  bool web = kIsWeb,
}) {
  if (index < 0 || index >= translatePinnedShortcutCount) return null;
  final modifiers = _pinnedModifiers(command: command, web: web);
  final digit = '${index + 1}';
  return (
    keys: [...modifiers.keys, digit].join(' + '),
    keysSemantics: [...modifiers.spoken, digit].join(' '),
  );
}

/// The translate screen's shortcuts, as shown in the cheat sheet. With
/// [command] (Apple platforms) the modifier is ⌘ and Alt is ⌥ (Option).
/// In a browser ([web]) the pinned languages take Ctrl/⌘ as well (see
/// [translatePinnedShortcut]).
List<TranslateShortcutHelp> translateShortcutHelp(
  AppLocalizations l10n, {
  required bool command,
  bool web = kIsWeb,
}) {
  final mod = command ? '⌘' : 'Ctrl';
  final modSpoken = command ? 'Command' : 'Control';
  final pinModifiers = _pinnedModifiers(command: command, web: web);
  TranslateShortcutHelp row(List<String> keys, String description) => (
    keys: keys.join(' + ').replaceAll('{mod}', mod),
    keysSemantics: keys.join(' ').replaceAll('{mod}', modSpoken),
    description: description,
  );
  final help = row(['{mod}', '/'], l10n.translateShortcutHelp);
  const lastPin = '$translatePinnedShortcutCount';
  return [
    row(['{mod}', 'Enter'], l10n.translateShortcutTranslateNow),
    row(['{mod}', 'Shift', 'S'], l10n.translateSwapLanguages),
    row(['{mod}', 'Shift', 'C'], l10n.translateShortcutCopyOutput),
    row(['{mod}', 'L'], l10n.translateShortcutTargetPicker),
    row(['{mod}', 'Shift', 'L'], l10n.translateShortcutSourcePicker),
    row(['Esc'], l10n.translateShortcutClear),
    (
      keys: [...pinModifiers.keys, '1…$lastPin'].join(' + '),
      keysSemantics: [
        ...pinModifiers.spoken,
        l10n.translateShortcutKeyRange('1', lastPin),
      ].join(' '),
      description: l10n.translateShortcutPinnedTarget,
    ),
    // Handled by the focused `ListenButton`.
    row(['Shift', 'Enter'], l10n.translateShortcutListenSlowly),
    (
      keys: l10n.translateShortcutOr('?', help.keys),
      keysSemantics: l10n.translateShortcutOr('?', help.keysSemantics),
      description: help.description,
    ),
  ];
}

/// Opens the keyboard shortcut cheat sheet.
Future<void> showTranslateShortcuts(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const TranslateShortcutsDialog(),
);

/// Dialog listing [translateShortcutHelp].
class TranslateShortcutsDialog extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final rows = translateShortcutHelp(
      l10n,
      command: shortcutUsesCommandKey(theme.platform),
    );
    return AlertDialog(
      key: const Key('translate_shortcuts_dialog'),
      title: Semantics(
        header: true,
        child: Text(l10n.translateKeyboardShortcuts),
      ),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: MergeSemantics(
                child: Wrap(
                  spacing: 16,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: theme.colorScheme.outline),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        child: Text(
                          row.keys,
                          semanticsLabel: row.keysSemantics,
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                    Text(row.description, style: theme.textTheme.bodyMedium),
                  ],
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonClose),
        ),
      ],
    );
  }
}
