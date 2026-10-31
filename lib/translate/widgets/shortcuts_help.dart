import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart' show AppLook;
import 'package:mozhi/app/view/app_shell.dart' show AppShell;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';

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

/// A row of the cheat sheet from [keys] (joined with " + "; `{mod}` is
/// Ctrl or ⌘ with [command], `{alt}` Alt or ⌥ Option) and [description].
TranslateShortcutHelp _row(
  List<String> keys,
  String description, {
  required bool command,
}) {
  String spell(String separator, {required bool spoken}) => keys
      .join(separator)
      .replaceAll(
        '{mod}',
        spoken ? (command ? 'Command' : 'Control') : (command ? '⌘' : 'Ctrl'),
      )
      .replaceAll(
        '{alt}',
        spoken ? (command ? 'Option' : 'Alt') : (command ? '⌥' : 'Alt'),
      );
  return (
    keys: spell(' + ', spoken: false),
    keysSemantics: spell(' ', spoken: true),
    description: description,
  );
}

/// The translate screen's shortcuts, as shown in the cheat sheet. With
/// [command] (Apple platforms) the modifier is ⌘ and Alt is ⌥ (Option).
/// In a browser ([web]) the pinned languages take Ctrl/⌘ as well (see
/// [translatePinnedShortcut]) and the language pickers are Alt+L and
/// Alt+Shift+L (Ctrl/⌘+L focuses the browser's address bar).
///
/// With [multilineInput] off ([AppSettings.multilineInput]) Enter in the
/// input translates and Shift+Enter adds a new line, so both are listed
/// after Ctrl/⌘+Enter; with it on (the default) Enter just types a new
/// line and is not listed.
List<TranslateShortcutHelp> translateShortcutHelp(
  AppLocalizations l10n, {
  required bool command,
  bool web = kIsWeb,
  bool multilineInput = true,
}) {
  final pinModifiers = _pinnedModifiers(command: command, web: web);
  TranslateShortcutHelp row(List<String> keys, String description) =>
      _row(keys, description, command: command);
  final help = row(['{mod}', '/'], l10n.translateShortcutHelp);
  final picker = web ? '{alt}' : '{mod}';
  const lastPin = '$translatePinnedShortcutCount';
  return [
    row(['{mod}', 'Enter'], l10n.translateShortcutTranslateNow),
    if (!multilineInput) ...[
      row(['Enter'], l10n.translateShortcutEnterTranslates),
      row(['Shift', 'Enter'], l10n.translateShortcutNewLine),
    ],
    row(['{mod}', 'Shift', 'S'], l10n.translateSwapLanguages),
    row(['{mod}', 'Shift', 'C'], l10n.translateShortcutCopyOutput),
    row([picker, 'L'], l10n.translateShortcutTargetPicker),
    row([picker, 'Shift', 'L'], l10n.translateShortcutSourcePicker),
    row(['/'], l10n.translateShortcutFocusInput),
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

/// The keys of [activator] for the cheat sheet, shown and spoken (Ctrl
/// is Control everywhere, as the shortcut asks for it; Alt is ⌥ Option
/// with [command]).
({List<String> keys, List<String> spoken}) _activatorKeys(
  SingleActivator activator, {
  required bool command,
  String? trigger,
}) {
  final key = trigger ?? activator.trigger.keyLabel;
  return (
    keys: [
      if (activator.control) 'Ctrl',
      if (activator.meta) '⌘',
      if (activator.alt && command) '⌥' else if (activator.alt) 'Alt',
      if (activator.shift) 'Shift',
      key,
    ],
    spoken: [
      if (activator.control) 'Control',
      if (activator.meta) 'Command',
      if (activator.alt && command) 'Option' else if (activator.alt) 'Alt',
      if (activator.shift) 'Shift',
      key,
    ],
  );
}

/// The shortcuts that work on every tab, as the app shell binds them
/// ([AppShell.tabShortcuts]: Ctrl+Shift+1 … 4 switch to a tab;
/// [AppShell.historyShortcut]: Ctrl+Shift+H opens History), for the cheat
/// sheet. With [command] (Apple platforms) Alt reads ⌥.
List<TranslateShortcutHelp> appShortcutHelp(
  AppLocalizations l10n, {
  required bool command,
}) {
  const tabs = AppShell.tabShortcuts;
  final last = '${tabs.length}';
  final range = _activatorKeys(
    tabs.first,
    command: command,
    trigger: '1…$last',
  );
  final spokenRange = _activatorKeys(
    tabs.first,
    command: command,
    trigger: l10n.translateShortcutKeyRange('1', last),
  );
  final history = _activatorKeys(AppShell.historyShortcut, command: command);
  return [
    (
      keys: range.keys.join(' + '),
      keysSemantics: spokenRange.spoken.join(' '),
      description: l10n.translateShortcutTabs,
    ),
    (
      keys: history.keys.join(' + '),
      keysSemantics: history.spoken.join(' '),
      description: l10n.translateShortcutHistory,
    ),
  ];
}

/// Opens the keyboard shortcut cheat sheet.
Future<void> showTranslateShortcuts(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const TranslateShortcutsDialog(),
);

/// Dialog listing [translateShortcutHelp] (for the user's Enter key
/// setting, [AppSettings.multilineInput], read from the [SettingsCubit];
/// the default without one) and then [appShortcutHelp], each under a
/// heading.
///
/// Each list is a two-column table: the keys, then what they do (a long
/// description wraps in its own column, never under the keys). Where the
/// two columns do not fit side by side (a narrow window, large text) each
/// description goes under its keys instead.
class TranslateShortcutsDialog extends StatelessWidget {
  const new({super.key});

  /// The narrowest description column of the table layout, at 100 % text.
  static const double minDescriptionWidth = 140;

  /// Space between the two columns.
  static const double columnGap = 16;

  static bool _multilineInput(BuildContext context) {
    try {
      return context.read<SettingsCubit>().state.multilineInput;
    } on ProviderNotFoundException {
      return const AppSettings().multilineInput;
    }
  }

  static TextStyle? _keysStyle(ThemeData theme) =>
      theme.textTheme.labelLarge?.copyWith(fontFamily: 'monospace');

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final command = shortcutUsesCommandKey(theme.platform);
    final translate = translateShortcutHelp(
      l10n,
      command: command,
      multilineInput: _multilineInput(context),
    );
    final app = appShortcutHelp(l10n, command: command);
    // The keys column: as wide as the widest keys (with their outline).
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    var keysWidth = 0.0;
    for (final row in [...translate, ...app]) {
      final painter = TextPainter(
        text: TextSpan(text: row.keys, style: _keysStyle(theme)),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      keysWidth = math.max(keysWidth, painter.width + _KeysChip.chrome);
      painter.dispose();
    }
    // The dialog's content width: the window less the dialog's insets
    // (40 dp each side) and padding (24 dp each side), at most 560 dp.
    final content = math.min(MediaQuery.sizeOf(context).width - 80, 560) - 48.0;
    final table =
        content - keysWidth - columnGap >= scaler.scale(minDescriptionWidth);
    Widget section(String title, List<TranslateShortcutHelp> rows) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Semantics(
            header: true,
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ),
        for (final row in rows)
          _ShortcutRow(
            row: row,
            keysWidth: table ? keysWidth : null,
            keysStyle: _keysStyle(theme),
          ),
      ],
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
          section(l10n.translateTitle, translate),
          const SizedBox(height: 12),
          section(l10n.translateShortcutSectionApp, app),
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

/// A row of the [TranslateShortcutsDialog]: the keys in a [keysWidth]
/// column and the description beside them, or (without a [keysWidth]) the
/// description under the keys. Read as one ("Control Enter, Translate
/// now").
class _ShortcutRow extends StatelessWidget {
  const new({required this.row, required this.keysStyle, this.keysWidth});

  final TranslateShortcutHelp row;
  final TextStyle? keysStyle;
  final double? keysWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keysWidth = this.keysWidth;
    // Stacked (a narrow window), long keys may wrap.
    final keys = _KeysChip(row: row, style: keysStyle, wrap: keysWidth == null);
    final description = Text(
      row.description,
      style: theme.textTheme.bodyMedium,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: MergeSemantics(
        child: keysWidth == null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [keys, description],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: keysWidth,
                    child: Align(
                      alignment: AlignmentDirectional.topStart,
                      child: keys,
                    ),
                  ),
                  const SizedBox(width: TranslateShortcutsDialog.columnGap),
                  Expanded(
                    child: Padding(
                      // Lines the first line up with the keys' text.
                      padding: const EdgeInsets.only(top: 3),
                      child: description,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// The keys of a shortcut, outlined like keyboard keys; on one line
/// unless they may [wrap].
class _KeysChip extends StatelessWidget {
  const new({required this.row, required this.style, this.wrap = false});

  /// Width around the text: the padding and the outline.
  static const double chrome = 2 * 8 + 2;

  final TranslateShortcutHelp row;
  final TextStyle? style;
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        borderRadius: BorderRadius.circular(
          AppLook.of(context).controlRadius(6),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          row.keys,
          semanticsLabel: row.keysSemantics,
          maxLines: wrap ? null : 1,
          softWrap: wrap,
          style: style,
        ),
      ),
    );
  }
}
