import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/widgets.dart';

/// The translate tab. The [TranslateCubit] is provided app-wide by the
/// shell; this page only builds [TranslateView].
class TranslatePage extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) => const TranslateView();
}

/// Ctrl/Cmd+Enter: translate now (or compare in compare mode).
class TranslateIntent extends Intent {
  const new();
}

/// Ctrl/Cmd+Shift+S: swap languages.
class SwapLanguagesIntent extends Intent {
  const new();
}

/// Ctrl/Cmd+Shift+C: copy the translation.
class CopyOutputIntent extends Intent {
  const new();
}

/// Ctrl/Cmd+L (target) and Ctrl/Cmd+Shift+L (source): open the language
/// picker with its search field focused.
class PickLanguageIntent extends Intent {
  const new({required this.source});

  final bool source;
}

/// `?` (outside text fields) or Ctrl/Cmd+/: show the shortcut cheat sheet.
class ShowShortcutsIntent extends Intent {
  const new();
}

/// Alt+1 … Alt+9 (Ctrl/Cmd+Alt+1 … 9 in a browser): translate into pinned
/// language [index] + 1 of those the engine offers
/// (`TranslateState.pinnedTargets`, as the language picker lists them).
class SelectPinnedTargetIntent extends Intent {
  const new(this.index);

  /// Zero-based index into the pinned languages the engine offers.
  final int index;
}

/// Whether keyboard focus is in an editable text field (where `?` must be
/// typed, not handled as a shortcut).
bool _focusIsInTextField() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  return context.widget is EditableText ||
      context.findAncestorStateOfType<EditableTextState>() != null;
}

/// Runs `onInvoke`; [enabled] decides per key press whether the shortcut
/// applies (a disabled action lets the key through, e.g. into a text
/// field).
class _ShortcutAction<T extends Intent> extends Action<T> {
  new(this.onInvoke, {this.enabled});

  final void Function(T intent) onInvoke;
  final bool Function(T intent)? enabled;

  @override
  bool isEnabled(T intent) => enabled?.call(intent) ?? true;

  @override
  Object? invoke(T intent) {
    onInvoke(intent);
    return null;
  }
}

/// Adaptive translate screen: single column on phones, input and output
/// side by side from [TranslateLayout.wideBreakpoint].
///
/// Keyboard shortcuts are listed in [shortcuts] and in the cheat sheet
/// (`?` or Ctrl/Cmd+/); Esc in the input clears it (see [InputCard]).
/// Alt+1 … Alt+9 pick a pinned target language (the n-th one the language
/// picker lists under "Pinned"; keys without such a pin are not handled)
/// and announce it to screen readers; on Apple platforms Option+digit
/// keeps typing its character while a text field has focus. In a browser
/// they are Ctrl/Cmd+Alt+1 … 9 ([shortcutsFor]).
///
/// A smart swap of the target language is announced in a snack bar with
/// Undo ([SmartSwapListener]).
///
/// The screen shows one task: the languages, the input and the
/// translation. Everything else (check meaning, insights, romanization,
/// matching phrases, compare, "Refine & learn", definitions, "Also
/// translate into…") is in the "More" area under the translation
/// ([TranslateMoreToggle]); whether it is open is remembered for the
/// session ([TranslateMoreHost]). Compare mode is also in the "More tools"
/// menu, so it can be turned on before translating.
class TranslateView extends StatelessWidget {
  const new({super.key});

  static const shortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.enter, control: true): TranslateIntent(),
    SingleActivator(LogicalKeyboardKey.enter, meta: true): TranslateIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter, control: true):
        TranslateIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter, meta: true):
        TranslateIntent(),
    SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true):
        SwapLanguagesIntent(),
    SingleActivator(LogicalKeyboardKey.keyS, meta: true, shift: true):
        SwapLanguagesIntent(),
    SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true):
        CopyOutputIntent(),
    SingleActivator(LogicalKeyboardKey.keyC, meta: true, shift: true):
        CopyOutputIntent(),
    SingleActivator(LogicalKeyboardKey.keyL, control: true): PickLanguageIntent(
      source: false,
    ),
    SingleActivator(LogicalKeyboardKey.keyL, meta: true): PickLanguageIntent(
      source: false,
    ),
    SingleActivator(LogicalKeyboardKey.keyL, control: true, shift: true):
        PickLanguageIntent(source: true),
    SingleActivator(LogicalKeyboardKey.keyL, meta: true, shift: true):
        PickLanguageIntent(source: true),
    SingleActivator(LogicalKeyboardKey.slash, control: true):
        ShowShortcutsIntent(),
    SingleActivator(LogicalKeyboardKey.slash, meta: true):
        ShowShortcutsIntent(),
    CharacterActivator('?'): ShowShortcutsIntent(),
    SingleActivator(LogicalKeyboardKey.digit1, alt: true):
        SelectPinnedTargetIntent(0),
    SingleActivator(LogicalKeyboardKey.digit2, alt: true):
        SelectPinnedTargetIntent(1),
    SingleActivator(LogicalKeyboardKey.digit3, alt: true):
        SelectPinnedTargetIntent(2),
    SingleActivator(LogicalKeyboardKey.digit4, alt: true):
        SelectPinnedTargetIntent(3),
    SingleActivator(LogicalKeyboardKey.digit5, alt: true):
        SelectPinnedTargetIntent(4),
    SingleActivator(LogicalKeyboardKey.digit6, alt: true):
        SelectPinnedTargetIntent(5),
    SingleActivator(LogicalKeyboardKey.digit7, alt: true):
        SelectPinnedTargetIntent(6),
    SingleActivator(LogicalKeyboardKey.digit8, alt: true):
        SelectPinnedTargetIntent(7),
    SingleActivator(LogicalKeyboardKey.digit9, alt: true):
        SelectPinnedTargetIntent(8),
  };

  /// [shortcuts] for the app ([web] false) or a browser: there Alt+digit
  /// stays with the browser and the OS (tab switching, ChromeOS shelf
  /// apps), so the pinned languages are Ctrl+Alt+digit (Cmd+Option+digit
  /// on Apple platforms) instead.
  static Map<ShortcutActivator, Intent> shortcutsFor({required bool web}) {
    if (!web) return shortcuts;
    return {
      for (final entry in shortcuts.entries)
        if (entry.value is! SelectPinnedTargetIntent) entry.key: entry.value,
      for (final (index, digit) in _pinnedDigits.indexed) ...{
        SingleActivator(digit, control: true, alt: true):
            SelectPinnedTargetIntent(index),
        SingleActivator(digit, meta: true, alt: true): SelectPinnedTargetIntent(
          index,
        ),
      },
    };
  }

  static const List<LogicalKeyboardKey> _pinnedDigits = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];

  void _translateNow(BuildContext context) {
    final cubit = context.read<TranslateCubit>();
    final state = cubit.state;
    if (state.input.trim().isEmpty) return;
    if (state.compareMode) {
      if (!state.comparing) unawaited(cubit.runCompare());
    } else {
      unawaited(cubit.translate());
    }
  }

  void _swap(BuildContext context) {
    final cubit = context.read<TranslateCubit>();
    if (cubit.state.canSwap) cubit.swap();
  }

  void _copyOutput(BuildContext context) {
    final state = context.read<TranslateCubit>().state;
    final output = state.output;
    if (state.compareMode || output.trim().isEmpty) return;
    unawaited(copyToClipboard(context, output));
  }

  void _pickLanguage(BuildContext context, {required bool source}) {
    if (context.read<TranslateCubit>().state.engines.isEmpty) return;
    unawaited(
      pickTranslateLanguage(context, source: source, autofocusSearch: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return Shortcuts(
      shortcuts: shortcutsFor(web: kIsWeb),
      child: Actions(
        actions: {
          TranslateIntent: CallbackAction<TranslateIntent>(
            onInvoke: (_) {
              _translateNow(context);
              return null;
            },
          ),
          SwapLanguagesIntent: CallbackAction<SwapLanguagesIntent>(
            onInvoke: (_) {
              _swap(context);
              return null;
            },
          ),
          CopyOutputIntent: _ShortcutAction<CopyOutputIntent>(
            (_) => _copyOutput(context),
          ),
          PickLanguageIntent: _ShortcutAction<PickLanguageIntent>(
            (intent) => _pickLanguage(context, source: intent.source),
          ),
          ShowShortcutsIntent: _ShortcutAction<ShowShortcutsIntent>(
            (_) => unawaited(showTranslateShortcuts(context)),
            // `?` is typed into text fields; Ctrl/Cmd+/ works everywhere.
            enabled: (_) =>
                !_focusIsInTextField() ||
                HardwareKeyboard.instance.isControlPressed ||
                HardwareKeyboard.instance.isMetaPressed,
          ),
        },
        child: _PinnedTargetActions(
          child: Focus(
            autofocus: true,
            child: SmartSwapListener(
              child: TranslateConsentListener(
                child: TranslateMoreHost(
                  child: Scaffold(
                    appBar: _TranslateAppBar(
                      showTitle: width >= TranslateLayout.compactBreakpoint,
                    ),
                    body: BlocBuilder<TranslateCubit, TranslateState>(
                      buildWhen: (previous, current) =>
                          previous.enginesStatus != current.enginesStatus ||
                          previous.engines.isEmpty != current.engines.isEmpty ||
                          (previous.engine == null) != (current.engine == null),
                      builder: (context, state) {
                        if (state.engines.isEmpty) {
                          return switch (state.enginesStatus) {
                            EnginesStatus.initial ||
                            EnginesStatus.loading => const TranslateSkeleton(),
                            EnginesStatus.ready ||
                            EnginesStatus.failure => const NoEnginesView(),
                          };
                        }
                        if (state.engine == null &&
                            state.enginesStatus == EnginesStatus.ready) {
                          return const ChooseEngineView();
                        }
                        // Measure the pane itself: the shell's navigation rail
                        // takes part of the window on large screens.
                        return LayoutBuilder(
                          builder: (context, constraints) =>
                              constraints.maxWidth >=
                                  TranslateLayout.wideBreakpoint
                              ? const _WideLayout()
                              : const _NarrowLayout(),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Handles [SelectPinnedTargetIntent] (Alt+1 … Alt+9) and tells screen
/// reader users which language it picked ("Translating into German").
class _PinnedTargetActions extends StatefulWidget {
  const new({required this.child});

  final Widget child;

  @override
  State<_PinnedTargetActions> createState() => _PinnedTargetActionsState();
}

class _PinnedTargetActionsState extends State<_PinnedTargetActions> {
  String? _announcement;
  int _announcements = 0;

  /// Whether the shortcut for a pin applies: engines are loaded, the
  /// engine offers that many pins (otherwise the key is left to others),
  /// and (in the Apple apps, where Option+digit types a character) focus
  /// is not in a text field.
  bool _enabled(SelectPinnedTargetIntent intent) {
    final state = context.read<TranslateCubit>().state;
    if (state.engines.isEmpty) return false;
    final pinned = context.read<SettingsCubit>().state.pinnedLanguages;
    if (intent.index >= state.pinnedTargets(pinned).length) return false;
    return kIsWeb ||
        !shortcutUsesCommandKey(Theme.of(context).platform) ||
        !_focusIsInTextField();
  }

  void _select(SelectPinnedTargetIntent intent) {
    final cubit = context.read<TranslateCubit>()
      ..selectPinnedTarget(intent.index);
    // Also when it already was the target: the key press is confirmed.
    final target = cubit.state.target;
    setState(() {
      _announcement = context.l10n.translatePinnedTargetSelected(target.name);
      _announcements++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: {
        SelectPinnedTargetIntent: _ShortcutAction<SelectPinnedTargetIntent>(
          _select,
          enabled: _enabled,
        ),
      },
      child: StatusAnnouncer(
        message: _announcement,
        announcementId: _announcements,
        child: widget.child,
      ),
    );
  }
}

class _TranslateAppBar extends StatelessWidget implements PreferredSizeWidget {
  const new({required this.showTitle});

  final bool showTitle;

  /// Largest part of the title area the screen title takes.
  static const _maxTitleShare = 0.4;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final noEngines = context.select<TranslateCubit, bool>(
      (cubit) => cubit.state.engines.isEmpty,
    );
    if (noEngines) {
      return AppBar(
        title: Text(l10n.translateTitle),
        actions: const [MoreToolsButton(), SizedBox(width: 4)],
      );
    }
    final hasQualityModes = context.select<TranslateCubit, bool>(
      (cubit) => cubit.state.hasQualityModes,
    );
    // The quality toggle (Fast / Best) sits next to the engine selector;
    // it is empty while no quality engine is configured. Its layout (and
    // whether the screen title still fits) follows the available width
    // and the text size.
    return AppBar(
      titleSpacing: showTitle ? null : 8,
      title: LayoutBuilder(
        builder: (context, constraints) {
          final layout = QualityToggle.layoutFor(
            constraints.maxWidth,
            textScaler: MediaQuery.textScalerOf(context),
            withTitle: showTitle,
          );
          final title =
              showTitle &&
              (!hasQualityModes || layout == QualityToggleLayout.labels);
          return Row(
            mainAxisSize: title ? MainAxisSize.max : MainAxisSize.min,
            children: [
              if (title) ...[
                // Never more than part of the bar (long titles, large
                // text): the rest is the selector's and the toggle's.
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth * _maxTitleShare,
                  ),
                  child: Text(
                    l10n.translateTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 16),
              ],
              const Flexible(child: EngineSelectorButton()),
              QualityToggle(layout: layout),
            ],
          );
        },
      ),
      actions: const [OptionsButton(), MoreToolsButton(), SizedBox(width: 4)],
    );
  }
}

/// Language code shown in the source avatar: the chosen language, the
/// detected one, or `auto` (a sparkle) while detecting.
String sourceAvatarCode(TranslateState state) {
  final source = state.source;
  if (source.isCustom) return source.name;
  if (!source.isAuto) return source.code;
  return state.result?.detectedSource ?? source.code;
}

/// Language code shown in the target avatar (a custom target's text).
String targetAvatarCode(TranslateState state) =>
    state.target.isCustom ? state.target.name : state.target.code;

/// Whether the output shows a translation (or one in progress), so it is
/// drawn as the reply of the input's thread (not the empty state or an
/// error).
bool outputJoinsThread(TranslateState state) =>
    state.output.isNotEmpty || state.status == TranslateStatus.translating;

/// The input as the first post of the thread: the source language's avatar
/// beside it, joined to the translation's avatar by a connector while there
/// is one ([connector]).
class _InputThread extends StatelessWidget {
  const new({this.connector = true, this.minLines = 4, this.footer});

  final bool connector;
  final int minLines;

  /// Shown under the input, inside the thread (the memory match).
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final code = context.select<TranslateCubit, String>(
      (cubit) => sourceAvatarCode(cubit.state),
    );
    final joined =
        connector &&
        context.select<TranslateCubit, bool>(
          (cubit) => !cubit.state.compareMode && outputJoinsThread(cubit.state),
        );
    final footer = this.footer;
    return TranslateThreadRow(
      key: const Key('translate_input_thread'),
      code: code,
      connector: joined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InputCard(minLines: minLines),
          ?footer,
          if (joined) const SizedBox(height: TranslateLayout.gap),
        ],
      ),
    );
  }
}

/// Output card or compare cards; then the meaning check (once asked for)
/// and, while the "More" area is open and there is a translation, "Refine
/// & learn" (AI extras), definitions and "Also translate into…"; the
/// translations into the extra target languages the user chose are shown
/// either way. A translation is the reply of the thread: the target
/// language's avatar beside it; before there is one, the empty state sits
/// under a hairline.
///
/// Hiding the meaning check from its panel hands the focus back to the
/// output card's "Check meaning" button (the "More" toggle while the area
/// is closed).
class _OutputSection extends StatefulWidget {
  const new({this.memory = true, this.separated = true});

  /// Whether the memory match is shown here (the narrow layout shows it
  /// under the input instead).
  final bool memory;

  /// Whether a hairline separates the empty state from the input above.
  final bool separated;

  @override
  State<_OutputSection> createState() => _OutputSectionState();
}

class _OutputSectionState extends State<_OutputSection> {
  final _meaningButton = FocusNode(debugLabel: 'translate_meaning_button');

  @override
  void dispose() {
    _meaningButton.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compareMode = context.select<TranslateCubit, bool>(
      (cubit) => cubit.state.compareMode,
    );
    if (compareMode) return const ComparePanel();
    final threaded = context.select<TranslateCubit, bool>(
      (cubit) => outputJoinsThread(cubit.state),
    );
    final targetCode = context.select<TranslateCubit, String>(
      (cubit) => targetAvatarCode(cubit.state),
    );
    final hasOutput = context.select<TranslateCubit, bool>(
      (cubit) => cubit.state.output.trim().isNotEmpty,
    );
    final more = TranslateMoreScope.maybeOf(context);
    final expanded = hasOutput && (more?.expanded ?? false);
    final output = OutputCard(meaningButtonFocusNode: _meaningButton);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.memory) const TranslationMemoryCard(),
        if (threaded)
          TranslateThreadRow(
            key: const Key('translate_output_thread'),
            code: targetCode,
            avatarTop: 10,
            child: output,
          )
        else ...[
          if (widget.separated) const Hairline(),
          output,
        ],
        MeaningCheckPanel(
          returnFocusNode: expanded || more == null
              ? _meaningButton
              : more.toggleFocus,
        ),
        ExtrasSection(expanded: expanded),
        AnimatedSize(
          duration: TranslateLayout.motion(context),
          curve: Curves.easeOutCubic,
          alignment: AlignmentDirectional.topStart,
          child: expanded
              ? const WordChoicesPanel()
              : const SizedBox(width: double.infinity),
        ),
        ExtraTargetsSection(showPicker: expanded),
      ],
    );
  }
}

class _NarrowLayout extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      key: const Key('translate_narrow_layout'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(
        TranslateLayout.gutter,
        4,
        TranslateLayout.gutter,
        32,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: TranslateLayout.maxColumnWidth,
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LanguageBar(),
              ActiveOptionsBar(),
              SizedBox(height: TranslateLayout.gap),
              _InputThread(footer: TranslationMemoryCard()),
              _OutputSection(memory: false),
            ],
          ),
        ),
      ),
    );
  }
}

/// Input and output side by side, like X's web columns: flat panes
/// separated by a vertical hairline.
class _WideLayout extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const Key('translate_wide_layout'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: TranslateLayout.maxWideWidth,
        ),
        child: const Padding(
          padding: EdgeInsets.fromLTRB(24, 4, 24, 0),
          child: Column(
            children: [
              LanguageBar(),
              ActiveOptionsBar(),
              SizedBox(height: TranslateLayout.gap),
              Hairline(),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        key: Key('translate_input_pane'),
                        padding: EdgeInsetsDirectional.only(
                          top: 8,
                          end: TranslateLayout.paneGap / 2,
                          bottom: 32,
                        ),
                        child: _InputThread(connector: false, minLines: 8),
                      ),
                    ),
                    Hairline(vertical: true),
                    Expanded(
                      child: SingleChildScrollView(
                        key: Key('translate_output_pane'),
                        padding: EdgeInsetsDirectional.only(
                          top: 8,
                          start: TranslateLayout.paneGap / 2,
                          bottom: 32,
                        ),
                        child: _OutputSection(separated: false),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
