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

/// The translate screen's shortcuts, as shown in the cheat sheet.
List<TranslateShortcutHelp> translateShortcutHelp(
  AppLocalizations l10n, {
  required bool command,
}) {
  final mod = command ? '⌘' : 'Ctrl';
  final modSpoken = command ? 'Command' : 'Control';
  TranslateShortcutHelp row(List<String> keys, String description) => (
    keys: keys.join(' + ').replaceAll('{mod}', mod),
    keysSemantics: keys.join(' ').replaceAll('{mod}', modSpoken),
    description: description,
  );
  final help = row(['{mod}', '/'], l10n.translateShortcutHelp);
  return [
    row(['{mod}', 'Enter'], l10n.translateShortcutTranslateNow),
    row(['{mod}', 'Shift', 'S'], l10n.translateSwapLanguages),
    row(['{mod}', 'Shift', 'C'], l10n.translateShortcutCopyOutput),
    row(['{mod}', 'L'], l10n.translateShortcutTargetPicker),
    row(['{mod}', 'Shift', 'L'], l10n.translateShortcutSourcePicker),
    row(['Esc'], l10n.translateShortcutClear),
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
