import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/view/top_level_actions.dart';
import 'package:mozhi/core/widgets/composer_card.dart';
import 'package:mozhi/core/widgets/fold_aware_split.dart';
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
/// picker with its search field focused. In a browser Alt+L and
/// Alt+Shift+L ([TranslateView.shortcutsFor]): Ctrl/Cmd+L focuses the
/// address bar there.
class PickLanguageIntent extends Intent {
  const new({required this.source});

  final bool source;
}

/// `/` (outside text fields): move the keyboard focus to the input.
class FocusInputIntent extends Intent {
  const new();
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
/// (`?` or Ctrl/Cmd+/); Esc in the input clears it (see [InputCard]) and
/// `/` (outside text fields) moves the focus there. Alt+1 … Alt+9 pick a
/// pinned target language (the n-th one the language picker lists under
/// "Pinned"; keys without such a pin are not handled) and announce it to
/// screen readers; on Apple platforms Option+digit keeps typing its
/// character while a text field has focus. In a browser they are
/// Ctrl/Cmd+Alt+1 … 9, and the language pickers Alt+L and Alt+Shift+L
/// ([shortcutsFor]).
///
/// A smart swap of the target language is announced in a snack bar with
/// Undo ([SmartSwapListener]).
///
/// The screen shows one task: the languages, the input and the
/// translation (see [_TranslateBody] for the layouts). On phones, empty,
/// it greets ([TranslateHero]) above a composer card docked at the bottom;
/// once the input has focus or text it is the thread of the input and its
/// translation, with the language bar docked at the bottom. The language
/// bar ([LanguageBar]) also holds the translation options button and the
/// go button, which translates right away (translation is otherwise
/// automatic while typing, see `AppSettings.instantTranslate` /
/// `instantTranslateAi`). Large screens always show two panes with the
/// languages above them ([LanguagePaneHeader]). Everything else (check
/// meaning, insights, romanization, matching phrases, compare, "Refine &
/// learn", definitions, "Also translate into…") is in the "More" area
/// under the translation ([TranslateMoreToggle]); whether it is open is
/// remembered for the session ([TranslateMoreHost]). Compare mode is also
/// in the "More tools" menu, so it can be turned on before translating.
class TranslateView extends StatefulWidget {
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
    CharacterActivator('/'): FocusInputIntent(),
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

  /// [shortcuts] for the app ([web] false) or a browser. There Alt+digit
  /// stays with the browser and the OS (tab switching, ChromeOS shelf
  /// apps), so the pinned languages are Ctrl+Alt+digit (Cmd+Option+digit
  /// on Apple platforms) instead; and Ctrl/Cmd+L focuses the address bar,
  /// so the language pickers are Alt+L (target) and Alt+Shift+L (source).
  static Map<ShortcutActivator, Intent> shortcutsFor({required bool web}) {
    if (!web) return shortcuts;
    return {
      for (final entry in shortcuts.entries)
        if (entry.value is! SelectPinnedTargetIntent &&
            entry.value is! PickLanguageIntent)
          entry.key: entry.value,
      const SingleActivator(LogicalKeyboardKey.keyL, alt: true):
          const PickLanguageIntent(source: false),
      const SingleActivator(LogicalKeyboardKey.keyL, alt: true, shift: true):
          const PickLanguageIntent(source: true),
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

  @override
  State<TranslateView> createState() => _TranslateViewState();
}

class _TranslateViewState extends State<TranslateView> {
  /// The input's focus node (`/` moves the focus there).
  final _inputFocus = FocusNode(debugLabel: 'translate_input');

  /// The language buttons above the panes ([TranslateLanguageAnchors]).
  final GlobalKey _sourceAnchor = GlobalKey(
    debugLabel: 'translate_source_anchor',
  );
  final GlobalKey _targetAnchor = GlobalKey(
    debugLabel: 'translate_target_anchor',
  );

  @override
  void dispose() {
    _inputFocus.dispose();
    super.dispose();
  }

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
    return TranslateLanguageAnchors(
      source: _sourceAnchor,
      target: _targetAnchor,
      // Below the anchors: a picker opened by its shortcut drops down
      // under the language button.
      child: Builder(
        builder: (context) => Shortcuts(
          shortcuts: TranslateView.shortcutsFor(web: kIsWeb),
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
                // `?` is typed into text fields; Ctrl/Cmd+/ works
                // everywhere.
                enabled: (_) =>
                    !_focusIsInTextField() ||
                    HardwareKeyboard.instance.isControlPressed ||
                    HardwareKeyboard.instance.isMetaPressed,
              ),
              FocusInputIntent: _ShortcutAction<FocusInputIntent>(
                (_) => _inputFocus.requestFocus(),
                // `/` is typed into text fields; without an input (no
                // engines) the key is left alone.
                enabled: (_) =>
                    _inputFocus.context != null && !_focusIsInTextField(),
              ),
            },
            child: _PinnedTargetActions(
              child: Focus(
                autofocus: true,
                child: SmartSwapListener(
                  child: TranslateConsentListener(
                    child: TranslateMoreHost(
                      child: _TranslateScaffold(inputFocus: _inputFocus),
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

/// The translate screen's [Scaffold]: the app bar and the body (the
/// skeleton, the no-engines view, the engine choice or [_TranslateBody]).
///
/// It knows whether the body's greeting ([TranslateHero]) holds the
/// quality chip ([QualityChip]): the app bar leaves its [QualityToggle]
/// out meanwhile, so the screen offers the quality modes once.
class _TranslateScaffold extends StatefulWidget {
  const new({required this.inputFocus});

  /// The input's focus node.
  final FocusNode inputFocus;

  @override
  State<_TranslateScaffold> createState() => _TranslateScaffoldState();
}

class _TranslateScaffoldState extends State<_TranslateScaffold> {
  /// Whether the greeting holds the quality chip. Until the body reports
  /// it, a guess from the state and the width (phones start with the
  /// greeting; the large-screen panes never hold the chip), so the first
  /// frame does not show the quality modes twice or move the app bar.
  ValueNotifier<bool>? _chipInHero;

  /// The latest report of the body ([_onChipInHeroChanged]).
  bool _reported = false;
  bool _updateScheduled = false;

  @override
  void dispose() {
    _chipInHero?.dispose();
    super.dispose();
  }

  /// The body (built after the app bar in the same frame) reports whether
  /// its greeting holds the quality chip; the app bar follows after this
  /// frame.
  void _onChipInHeroChanged(bool inHero) {
    _reported = inHero;
    final chipInHero = _chipInHero;
    if (_updateScheduled || chipInHero == null || inHero == chipInHero.value) {
      return;
    }
    _updateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateScheduled = false;
      if (mounted) _chipInHero?.value = _reported;
    });
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return LayoutBuilder(
      builder: (context, constraints) {
        final chipInHero = _chipInHero ??= ValueNotifier(
          translateComposerIsIdle(context.read<TranslateCubit>().state) &&
              constraints.maxWidth < TranslateLayout.wideBreakpoint &&
              FoldAwareSplit.featureDirectionOf(context) == null,
        );
        return Scaffold(
          appBar: _TranslateAppBar(
            showTitle: width >= TranslateLayout.compactBreakpoint,
            chipInHero: chipInHero,
          ),
          body: BlocBuilder<TranslateCubit, TranslateState>(
            buildWhen: (previous, current) =>
                previous.enginesStatus != current.enginesStatus ||
                previous.engines.isEmpty != current.engines.isEmpty ||
                (previous.engine == null) != (current.engine == null),
            builder: (context, state) {
              if (state.engines.isEmpty) {
                _onChipInHeroChanged(false);
                return switch (state.enginesStatus) {
                  EnginesStatus.initial ||
                  EnginesStatus.loading => const TranslateSkeleton(),
                  EnginesStatus.ready ||
                  EnginesStatus.failure => const NoEnginesView(),
                };
              }
              if (state.engine == null &&
                  state.enginesStatus == EnginesStatus.ready) {
                _onChipInHeroChanged(false);
                return const ChooseEngineView();
              }
              // Measure the pane itself: the shell's navigation rail takes
              // part of the window on large screens. A hinge or
              // half-opened fold makes two panes at any width.
              return LayoutBuilder(
                builder: (context, constraints) {
                  final wide =
                      constraints.maxWidth >= TranslateLayout.wideBreakpoint;
                  final fold = FoldAwareSplit.featureDirectionOf(context);
                  return _TranslateBody(
                    wide: wide,
                    fold: fold,
                    height: constraints.maxHeight,
                    focusNode: widget.inputFocus,
                    onChipInHeroChanged: _onChipInHeroChanged,
                  );
                },
              );
            },
          ),
        );
      },
    );
  }
}

class _TranslateAppBar extends StatelessWidget implements PreferredSizeWidget {
  const new({required this.showTitle, required this.chipInHero});

  final bool showTitle;

  /// Whether the body's greeting holds the quality chip (the toggle here
  /// is left out then).
  final ValueListenable<bool> chipInHero;

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
        actions: const [
          TopLevelActions(),
          MoreToolsButton(),
          SizedBox(width: 4),
        ],
      );
    }
    final hasQualityModes = context.select<TranslateCubit, bool>(
      (cubit) => cubit.state.hasQualityModes,
    );
    // The quality toggle (Fast / Best) sits next to the engine selector;
    // it is empty while no quality engine is configured, and left out
    // while the greeting holds the quality chip. Its layout (and whether
    // the screen title still fits) follows the available width and the
    // text size.
    return ValueListenableBuilder<bool>(
      valueListenable: chipInHero,
      builder: (context, chipInHero, _) {
        final toggle = hasQualityModes && !chipInHero;
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
                  (!toggle || layout == QualityToggleLayout.labels);
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
                  if (toggle) QualityToggle(layout: layout),
                ],
              );
            },
          ),
          actions: const [
            TopLevelActions(),
            MoreToolsButton(),
            SizedBox(width: 4),
          ],
        );
      },
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

/// Whether the output shows a translation (or one queued or in progress,
/// `TranslateState.isPending`: its header and placeholder lines), so it is
/// drawn as the reply of the input's thread (not the empty state or an
/// error).
bool outputJoinsThread(TranslateState state) =>
    state.output.isNotEmpty || state.isPending;

/// The input as the first post of the thread: the source language's avatar
/// beside it, joined to the translation's avatar by a connector while there
/// is one ([connector]). [compact]: the empty screen's composer (no avatar,
/// no tools row, see [InputCard.compact]). Without [avatar] (the panes of
/// large screens, whose languages are named above them) never an avatar.
class _InputThread extends StatelessWidget {
  const new({
    required this.focusNode,
    this.connector = true,
    this.compact = false,
    this.avatar = true,
    this.minLines = 4,
    this.footer,
  });

  final FocusNode focusNode;
  final bool connector;
  final bool compact;
  final bool avatar;
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
        !compact &&
        context.select<TranslateCubit, bool>(
          (cubit) => !cubit.state.compareMode && outputJoinsThread(cubit.state),
        );
    final footer = this.footer;
    return TranslateThreadRow(
      key: const Key('translate_input_thread'),
      code: code,
      connector: joined,
      showAvatar: avatar && !compact,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InputCard(minLines: minLines, focusNode: focusNode, compact: compact),
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
/// under a hairline. Without [avatar] (the panes of large screens) the
/// translation has no avatar either.
///
/// Hiding the meaning check from its panel hands the focus back to the
/// output card's "Check meaning" button (the "More" toggle while the area
/// is closed).
class _OutputSection extends StatefulWidget {
  const new({this.memory = true, this.separated = true, this.avatar = true});

  /// Whether the memory match is shown here (the narrow layout shows it
  /// under the input instead).
  final bool memory;

  /// Whether a hairline separates the empty state from the input above.
  final bool separated;

  /// Whether the translation has its language's avatar beside it.
  final bool avatar;

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
    final outputEmpty = context.select<TranslateCubit, bool>(
      (cubit) => translateOutputIsEmpty(cubit.state),
    );
    final more = TranslateMoreScope.maybeOf(context);
    final expanded = hasOutput && (more?.expanded ?? false);
    final output = OutputCard(meaningButtonFocusNode: _meaningButton);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.memory) const TranslationMemoryCard(),
        if (threaded && widget.avatar)
          TranslateThreadRow(
            key: const Key('translate_output_thread'),
            code: targetCode,
            avatarTop: 10,
            child: output,
          )
        else ...[
          if (widget.separated && !outputEmpty) const Hairline(),
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

/// Whether the screen shows nothing but the greeting and the composer
/// for [state] (as long as the input has no focus): no input, not
/// comparing, and nothing in the output (no translation, prompt or
/// error).
bool translateComposerIsIdle(TranslateState state) =>
    state.input.isEmpty && !state.compareMode && translateOutputIsEmpty(state);

/// The fill of the empty screen's composer card on [scheme]'s page: a
/// shade off the page (`surfaceContainerLow`) while quiet text keeps its
/// contrast on it (else the page itself). The same as [composerFill]
/// (the card is a [ComposerCard]).
Color translateComposerFill(ColorScheme scheme, Color secondaryText) =>
    composerFill(scheme, secondaryText);

/// Places in the keyboard traversal of the translate screen (see
/// [_TranslateBody]): the input, then the language controls, then the
/// translation, whatever their places on the screen.
abstract final class _FocusOrder {
  static const double input = 1;

  /// The greeting's chips (Camera, Document, recent pairs).
  static const double hero = 1.5;

  /// The chips of the active translation options (phones).
  static const double activeOptions = 1.8;
  static const double languages = 2;

  /// The options and go buttons under the input pane (large screens).
  static const double paneFooter = 2.5;
  static const double output = 3;
}

/// [child] as one stop of the screen's keyboard traversal, at [order]
/// ([_FocusOrder]).
Widget _ordered(double order, Widget child) => FocusTraversalOrder(
  order: NumericFocusOrder(order),
  child: FocusTraversalGroup(child: child),
);

/// The translate screen below the app bar.
///
/// Phones and narrow windows, empty ([translateComposerIsIdle] and the
/// field without focus), like Kagi Translate: the greeting
/// ([TranslateHero]) in the middle and the composer docked at the bottom,
/// a hairline-outlined card around the text field (with the microphone at
/// its top end, and "Type or paste text" as its placeholder) and the
/// language bar. A window too low for both ([heroMinHeight]) skips this.
/// The greeting holds the quality chip when there is room for it too
/// ([heroChipMinHeight]); otherwise the toggle stays in the app bar.
/// Active (the field has focus or text): the thread layout, the input
/// with its language avatar and the translation below it joined by the
/// connector, with the language bar docked at the bottom of the screen:
/// above the navigation bar, or above the keyboard while it is open. It is
/// one tree in both: the greeting's slot collapses, the composer's slot
/// fills the screen, the card's outline and fill fade and the avatar fades
/// in, so the text field keeps its focus, text and keyboard. A sheet or
/// dialog that takes the focus for a while (the language picker) does not
/// switch back. Back (the system gesture) while the empty field has the
/// focus takes it away, bringing the greeting back, before it leaves the
/// screen.
///
/// From [TranslateLayout.wideBreakpoint]: two panes from the first frame
/// on, which focusing the input never rearranges ([_PanesLayout]).
///
/// A hinge or half-opened fold always shows the panes, split at it, with
/// the language bar under the input pane ([_FoldLayout]).
///
/// The keyboard visits the input first, then the language controls, then
/// the translation ([_FocusOrder]), in every layout.
class _TranslateBody extends StatefulWidget {
  const new({
    required this.wide,
    required this.fold,
    required this.height,
    required this.focusNode,
    required this.onChipInHeroChanged,
  });

  final bool wide;
  final Axis? fold;

  /// Height of the screen's content (without the keyboard).
  final double height;

  /// The input's focus node (the screen's, the same for its lifetime).
  final FocusNode focusNode;

  /// Told on every build whether the greeting holds the quality chip.
  final ValueChanged<bool> onChipInHeroChanged;

  /// The lowest content height that shows the greeting and the docked
  /// composer at [textScale].
  static double heroMinHeight(double textScale) =>
      300 + 120 * textScale.clamp(1, 2);

  /// The lowest content height whose greeting also holds the quality chip
  /// at [textScale] (lower ones keep the toggle in the app bar, so the
  /// greeting still fits).
  static double heroChipMinHeight(double textScale) =>
      heroMinHeight(textScale) +
      (translateHeroChipGap + kMinInteractiveDimension) * textScale.clamp(1, 2);

  @override
  State<_TranslateBody> createState() => _TranslateBodyState();
}

class _TranslateBodyState extends State<_TranslateBody> {
  /// Whether the field had focus last time the screen counted it.
  late bool _focused = widget.focusNode.hasFocus;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    final focused = widget.focusNode.hasFocus;
    if (focused == _focused) return;
    // A sheet or dialog over the screen holds the focus for a while: keep
    // the layout under it (the focus comes back when it closes).
    if (!focused && !(ModalRoute.of(context)?.isCurrent ?? true)) return;
    setState(() => _focused = focused);
  }

  @override
  Widget build(BuildContext context) {
    final fold = widget.fold;
    final Widget body;
    if (fold != null) {
      widget.onChipInHeroChanged(false);
      body = _FoldLayout(
        fold: fold,
        wide: widget.wide,
        focusNode: widget.focusNode,
      );
    } else if (widget.wide) {
      widget.onChipInHeroChanged(false);
      body = _PanesLayout(focusNode: widget.focusNode);
    } else {
      final idle = context.select<TranslateCubit, bool>(
        (cubit) => translateComposerIsIdle(cubit.state),
      );
      final textScale = MediaQuery.textScalerOf(context).scale(1);
      final roomy = widget.height >= _TranslateBody.heroMinHeight(textScale);
      final hero = idle && !_focused && roomy;
      final chip =
          hero && widget.height >= _TranslateBody.heroChipMinHeight(textScale);
      widget.onChipInHeroChanged(chip);
      // Back first takes the focus from the empty field: the greeting
      // comes back (on Android a touch outside the field keeps its focus).
      final backToHero = idle && _focused && roomy;
      body = PopScope<Object?>(
        canPop: !backToHero,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) widget.focusNode.unfocus();
        },
        child: _ComposerLayout(
          hero: hero,
          qualityChip: chip,
          focusNode: widget.focusNode,
        ),
      );
    }
    return FocusTraversalGroup(policy: OrderedTraversalPolicy(), child: body);
  }
}

/// [_TranslateBody] on phones and narrow windows without a hinge or fold:
/// the greeting's slot, the composer card ([ComposerCard]: the input
/// region, the active options and the language bar).
///
/// The slots are this screen's own rather than [ComposerLayout]'s: the
/// card's margin is part of it (taps there focus the field too), and its
/// width leaves room for the phone gutters once it is flat.
class _ComposerLayout extends StatelessWidget {
  const new({
    required this.hero,
    required this.focusNode,
    this.qualityChip = true,
  });

  final bool hero;

  /// Whether the greeting holds the quality chip
  /// ([TranslateHero.showQualityChip]).
  final bool qualityChip;
  final FocusNode focusNode;

  /// Space around the card on phones.
  static const double cardMargin = ComposerLayout.margin;

  @override
  Widget build(BuildContext context) {
    final motion = TranslateLayout.motion(context);
    const gutter = TranslateLayout.gutter;
    // Taps on the card's empty space (and its margin) go to the text field.
    final card = ComposerCard(
      key: const Key('translate_composer'),
      outlined: hero,
      expand: !hero,
      onTap: hero ? focusNode.requestFocus : null,
      margin: hero
          ? const EdgeInsets.fromLTRB(cardMargin, 8, cardMargin, cardMargin)
          : EdgeInsets.zero,
      bar: _ordered(_FocusOrder.languages, const LanguageBar()),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            flex: hero ? 0 : 1,
            fit: hero ? FlexFit.loose : FlexFit.tight,
            child: _NarrowRegion(hero: hero, focusNode: focusNode),
          ),
          AnimatedPadding(
            duration: motion,
            padding: EdgeInsets.symmetric(horizontal: hero ? 0 : gutter),
            child: _ordered(
              _FocusOrder.activeOptions,
              const ActiveOptionsBar(),
            ),
          ),
        ],
      ),
    );
    return Column(
      children: [
        // The greeting fills the space above the docked composer.
        Flexible(
          flex: hero ? 1 : 0,
          fit: FlexFit.tight,
          child: hero
              ? Align(
                  child: SingleChildScrollView(
                    child: _ordered(
                      _FocusOrder.hero,
                      TranslateHero(showQualityChip: qualityChip),
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
        Flexible(
          flex: hero ? 0 : 1,
          fit: hero ? FlexFit.loose : FlexFit.tight,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: TranslateLayout.maxColumnWidth + 2 * gutter,
              ),
              child: card,
            ),
          ),
        ),
      ],
    );
  }
}

/// The input region on phones: the input thread and, once active, the
/// translation below it, in one scroll view.
class _NarrowRegion extends StatelessWidget {
  const new({required this.hero, required this.focusNode});

  final bool hero;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      key: const Key('translate_narrow_layout'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: hero ? const NeverScrollableScrollPhysics() : null,
      padding: hero
          ? const EdgeInsetsDirectional.only(start: ComposerCard.padding)
          : const EdgeInsets.fromLTRB(
              TranslateLayout.gutter,
              4,
              TranslateLayout.gutter,
              16,
            ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: TranslateLayout.maxColumnWidth,
          ),
          child: _SwapFade(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ordered(
                  _FocusOrder.input,
                  _InputThread(
                    focusNode: focusNode,
                    compact: hero,
                    minLines: hero ? 3 : 4,
                    footer: hero ? null : const TranslationMemoryCard(),
                  ),
                ),
                if (!hero)
                  _ordered(
                    _FocusOrder.output,
                    const _OutputSection(memory: false),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// [_TranslateBody] from [TranslateLayout.wideBreakpoint], like Google's
/// and DeepL's translators: always two panes, the input's and the
/// translation's, side by side around a hairline, with the source language
/// above the input pane, the target language above the output pane and
/// the swap button between them ([LanguagePaneHeader]); the options and
/// go buttons (and the active options) under the input pane.
///
/// Nothing moves when the field takes the focus. While the input is empty
/// its pane holds the greeting ([TranslateHero]: Camera, Document, recent
/// pairs) under the field's placeholder, and the output pane a quiet
/// "Translation" placeholder; neither has an avatar (the languages are
/// named above them), and the quality toggle stays in the app bar.
class _PanesLayout extends StatelessWidget {
  const new({required this.focusNode});

  final FocusNode focusNode;

  /// Lines of the input field while empty and with text.
  static const int emptyLines = 3;
  static const int lines = 8;

  @override
  Widget build(BuildContext context) {
    final inputEmpty = context.select<TranslateCubit, bool>(
      (cubit) => cubit.state.input.isEmpty,
    );
    final idle = context.select<TranslateCubit, bool>(
      (cubit) => translateComposerIsIdle(cubit.state),
    );
    final outputEmpty = context.select<TranslateCubit, bool>(
      (cubit) =>
          !cubit.state.compareMode && translateOutputIsEmpty(cubit.state),
    );
    const half = TranslateLayout.paneGap / 2;
    final input = CustomScrollView(
      key: const Key('translate_input_pane'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsetsDirectional.only(top: 8, end: half),
          sliver: SliverToBoxAdapter(
            child: _SwapFade(
              child: _InputThread(
                focusNode: focusNode,
                connector: false,
                compact: inputEmpty,
                avatar: false,
                minLines: inputEmpty ? emptyLines : lines,
              ),
            ),
          ),
        ),
        if (idle)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: EdgeInsetsDirectional.only(end: half),
              child: Center(child: TranslateHero(showQualityChip: false)),
            ),
          )
        else
          const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
      ],
    );
    final output = SingleChildScrollView(
      key: const Key('translate_output_pane'),
      padding: const EdgeInsetsDirectional.only(
        top: 8,
        start: half,
        bottom: 32,
      ),
      child: _SwapFade(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (outputEmpty) const _OutputPlaceholder(),
            const _OutputSection(separated: false, avatar: false),
          ],
        ),
      ),
    );
    return Center(
      key: const Key('translate_wide_layout'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: TranslateLayout.maxWideWidth,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: ComposerLayout.wideSide,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ordered(_FocusOrder.languages, const LanguagePaneHeader()),
              const Hairline(),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: _ordered(_FocusOrder.input, input)),
                          _ordered(_FocusOrder.paneFooter, const _PaneFooter()),
                        ],
                      ),
                    ),
                    const SizedBox(width: 1, child: Hairline(vertical: true)),
                    Expanded(child: _ordered(_FocusOrder.output, output)),
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

/// Under the input pane of [_PanesLayout]: the chips of the active
/// translation options, then the options button and the go button.
class _PaneFooter extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      key: Key('translate_pane_footer'),
      padding: EdgeInsetsDirectional.only(
        end: TranslateLayout.paneGap / 2,
        bottom: 8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ActiveOptionsBar(),
          SizedBox(height: 4),
          Row(children: [OptionsButton(), Spacer(), TranslateGoButton()]),
        ],
      ),
    );
  }
}

/// The empty output pane's quiet "Translation", where the translation
/// will be (a placeholder like the input's; screen readers skip it).
class _OutputPlaceholder extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Padding(
        // Lined up with the input's placeholder.
        padding: const EdgeInsetsDirectional.only(
          start: TranslateLayout.cardPadding,
          top: 14,
          bottom: 8,
        ),
        child: Text(
          context.l10n.translateOutputLabel,
          key: const Key('translate_output_placeholder'),
          style: TranslateLayout.outputTextStyle(
            context,
            0,
          )?.copyWith(color: AppPalette.of(context).secondaryText),
        ),
      ),
    );
  }
}

/// Fades [child] (the input or the translation) in again when the
/// languages are swapped ([translateLanguagesSwapped]), while the language
/// names trade places: the texts cross over too. No motion with reduced
/// motion.
class _SwapFade extends StatefulWidget {
  const new({required this.child});

  final Widget child;

  @override
  State<_SwapFade> createState() => _SwapFadeState();
}

class _SwapFadeState extends State<_SwapFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: 1,
  );
  late final Animation<double> _opacity = Tween<double>(
    begin: 0.15,
    end: 1,
  ).chain(CurveTween(curve: Curves.easeOut)).animate(_controller);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<TranslateCubit, TranslateState>(
      listenWhen: translateLanguagesSwapped,
      listener: (context, _) {
        if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
        _controller.forward(from: 0);
      },
      child: FadeTransition(opacity: _opacity, child: widget.child),
    );
  }
}

/// [_TranslateBody] at a hinge or half-opened fold: the panes split
/// exactly at it ([FoldAwareSplit]), also below
/// [TranslateLayout.wideBreakpoint]: side by side at a vertical one (book
/// posture; the language bar docks under the input pane, so nothing sits
/// under the hinge), the input above the output at a horizontal one
/// (tabletop posture; the bar docks at the bottom).
class _FoldLayout extends StatelessWidget {
  const new({required this.fold, required this.wide, required this.focusNode});

  /// How the hinge or fold splits the screen
  /// ([FoldAwareSplit.featureDirectionOf]).
  final Axis fold;

  /// Whether the pane is at least [TranslateLayout.wideBreakpoint] wide
  /// (narrower ones get phone gutters).
  final bool wide;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final stacked = fold == Axis.vertical;
    final input = _ordered(
      _FocusOrder.input,
      SingleChildScrollView(
        key: const Key('translate_input_pane'),
        padding: stacked
            ? const EdgeInsetsDirectional.only(top: 8, bottom: 16)
            : const EdgeInsetsDirectional.only(
                top: 8,
                end: TranslateLayout.paneGap / 2,
                bottom: 32,
              ),
        child: _SwapFade(
          child: _InputThread(
            focusNode: focusNode,
            connector: false,
            minLines: stacked ? 4 : 8,
          ),
        ),
      ),
    );
    final output = _ordered(
      _FocusOrder.output,
      const SingleChildScrollView(
        key: Key('translate_output_pane'),
        padding: EdgeInsetsDirectional.only(
          top: 8,
          start: TranslateLayout.paneGap / 2,
          bottom: 32,
        ),
        child: _SwapFade(child: _OutputSection(separated: false)),
      ),
    );
    final stackedOutput = _ordered(
      _FocusOrder.output,
      const SingleChildScrollView(
        key: Key('translate_output_pane'),
        padding: EdgeInsetsDirectional.only(top: 16, bottom: 32),
        child: _SwapFade(child: _OutputSection(separated: false)),
      ),
    );
    final bar = _ordered(
      _FocusOrder.languages,
      const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ActiveOptionsBar(),
          Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LanguageBar(),
          ),
        ],
      ),
    );
    final side = wide ? ComposerLayout.wideSide : TranslateLayout.gutter;
    return Center(
      key: const Key('translate_wide_layout'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: TranslateLayout.maxWideWidth,
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(side, 4, side, 0),
          child: stacked
              ? Column(
                  children: [
                    Expanded(
                      child: FoldAwareSplit(
                        key: const Key('translate_pane_split'),
                        direction: Axis.vertical,
                        gap: 1,
                        divider: const Hairline(),
                        first: input,
                        second: stackedOutput,
                      ),
                    ),
                    bar,
                  ],
                )
              : FoldAwareSplit(
                  key: const Key('translate_pane_split'),
                  gap: 1,
                  divider: const Hairline(vertical: true),
                  first: Column(
                    children: [
                      Expanded(child: input),
                      Padding(
                        padding: const EdgeInsetsDirectional.only(
                          end: TranslateLayout.paneGap / 2,
                        ),
                        child: bar,
                      ),
                    ],
                  ),
                  second: output,
                ),
        ),
      ),
    );
  }
}
