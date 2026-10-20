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
/// translation. Empty, it greets ([TranslateHero]) above a composer card
/// docked at the bottom; once the input has focus or text it is the
/// thread of the input and its translation, with the language bar docked
/// at the bottom (see [_TranslateBody]). The language bar ([LanguageBar])
/// also holds the translation options button and the go button, which
/// translates right away (translation is otherwise automatic while
/// typing, see `AppSettings.instantTranslate` / `instantTranslateAi`).
/// Everything else (check meaning, insights, romanization, matching
/// phrases, compare, "Refine & learn", definitions, "Also translate
/// into…") is in the "More" area under the translation
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
        child: const _PinnedTargetActions(
          child: Focus(
            autofocus: true,
            child: SmartSwapListener(
              child: TranslateConsentListener(
                child: TranslateMoreHost(child: _TranslateScaffold()),
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
/// It knows whether the body shows the greeting ([TranslateHero]), which
/// then holds the quality chip ([QualityChip]): the app bar leaves its
/// [QualityToggle] out meanwhile, so the screen offers it once.
class _TranslateScaffold extends StatefulWidget {
  const new();

  @override
  State<_TranslateScaffold> createState() => _TranslateScaffoldState();
}

class _TranslateScaffoldState extends State<_TranslateScaffold> {
  /// Whether the body shows the greeting. Until the body reports it, a
  /// guess from the state (the greeting is how the screen starts), so the
  /// quality control does not show twice on the first frame.
  late final ValueNotifier<bool> _heroShown = ValueNotifier(
    translateComposerIsIdle(context.read<TranslateCubit>().state),
  );

  /// The latest report of the body ([_onHeroChanged]).
  late bool _reportedHero = _heroShown.value;
  bool _updateScheduled = false;

  @override
  void dispose() {
    _heroShown.dispose();
    super.dispose();
  }

  /// The body (built after the app bar in the same frame) shows the
  /// greeting or not: the app bar follows after this frame.
  void _onHeroChanged(bool shown) {
    _reportedHero = shown;
    if (_updateScheduled || shown == _heroShown.value) return;
    _updateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateScheduled = false;
      if (mounted) _heroShown.value = _reportedHero;
    });
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return Scaffold(
      appBar: _TranslateAppBar(
        showTitle: width >= TranslateLayout.compactBreakpoint,
        heroShown: _heroShown,
      ),
      body: BlocBuilder<TranslateCubit, TranslateState>(
        buildWhen: (previous, current) =>
            previous.enginesStatus != current.enginesStatus ||
            previous.engines.isEmpty != current.engines.isEmpty ||
            (previous.engine == null) != (current.engine == null),
        builder: (context, state) {
          if (state.engines.isEmpty) {
            _onHeroChanged(false);
            return switch (state.enginesStatus) {
              EnginesStatus.initial ||
              EnginesStatus.loading => const TranslateSkeleton(),
              EnginesStatus.ready ||
              EnginesStatus.failure => const NoEnginesView(),
            };
          }
          if (state.engine == null &&
              state.enginesStatus == EnginesStatus.ready) {
            _onHeroChanged(false);
            return const ChooseEngineView();
          }
          // Measure the pane itself: the shell's navigation rail takes part
          // of the window on large screens. A hinge or half-opened fold
          // makes two panes at any width.
          return LayoutBuilder(
            builder: (context, constraints) {
              final wide =
                  constraints.maxWidth >= TranslateLayout.wideBreakpoint;
              final fold = FoldAwareSplit.featureDirectionOf(context);
              return _TranslateBody(
                wide: wide,
                fold: fold,
                height: constraints.maxHeight,
                onHeroChanged: _onHeroChanged,
              );
            },
          );
        },
      ),
    );
  }
}

class _TranslateAppBar extends StatelessWidget implements PreferredSizeWidget {
  const new({required this.showTitle, required this.heroShown});

  final bool showTitle;

  /// Whether the body shows the greeting, which then holds the quality
  /// chip instead of the toggle here.
  final ValueListenable<bool> heroShown;

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
    // while the greeting shows the quality chip. Its layout (and whether
    // the screen title still fits) follows the available width and the
    // text size.
    return ValueListenableBuilder<bool>(
      valueListenable: heroShown,
      builder: (context, hero, _) {
        final toggle = hasQualityModes && !hero;
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

/// Whether the output shows a translation (or one in progress), so it is
/// drawn as the reply of the input's thread (not the empty state or an
/// error).
bool outputJoinsThread(TranslateState state) =>
    state.output.isNotEmpty || state.status == TranslateStatus.translating;

/// The input as the first post of the thread: the source language's avatar
/// beside it, joined to the translation's avatar by a connector while there
/// is one ([connector]). [compact]: the empty screen's composer (no avatar,
/// no tools row, see [InputCard.compact]).
class _InputThread extends StatelessWidget {
  const new({
    required this.focusNode,
    this.connector = true,
    this.compact = false,
    this.minLines = 4,
    this.footer,
  });

  final FocusNode focusNode;
  final bool connector;
  final bool compact;
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
      showAvatar: !compact,
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
        if (threaded)
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

/// The translate screen below the app bar.
///
/// Empty ([translateComposerIsIdle] and the field without focus), like
/// Kagi Translate: the greeting ([TranslateHero]) in the middle and the
/// composer docked at the bottom, a hairline-outlined card around the text
/// field (with the microphone at its top end) and the language bar. On
/// large screens the card sits under the greeting, at most
/// [TranslateLayout.maxColumnWidth] wide. A window too low for both
/// ([heroMinHeight]) skips this.
///
/// Active (the field has focus or text): the thread layout, the input
/// with its language avatar and the translation below it joined by the
/// connector (side by side from [TranslateLayout.wideBreakpoint]), with
/// the language bar docked at the bottom of the screen: above the
/// navigation bar, or above the keyboard while it is open.
///
/// It is one tree in both: the greeting's slot collapses, the composer's
/// slot fills the screen, the card's outline and fill fade and the avatar
/// fades in, so the text field keeps its focus, text and keyboard. A
/// sheet or dialog that takes the focus for a while (the language picker)
/// does not switch back. A hinge or half-opened fold always shows the
/// panes, split at it, with the language bar under the input pane.
class _TranslateBody extends StatefulWidget {
  const new({
    required this.wide,
    required this.fold,
    required this.height,
    required this.onHeroChanged,
  });

  final bool wide;
  final Axis? fold;

  /// Height of the screen's content (without the keyboard).
  final double height;

  /// Told on every build whether the greeting shows.
  final ValueChanged<bool> onHeroChanged;

  /// The lowest content height that shows the greeting and the docked
  /// composer at [textScale].
  static double heroMinHeight(double textScale) =>
      300 + 120 * textScale.clamp(1, 2);

  @override
  State<_TranslateBody> createState() => _TranslateBodyState();
}

class _TranslateBodyState extends State<_TranslateBody> {
  final _inputFocus = FocusNode(debugLabel: 'translate_input');

  /// Whether the field had focus last time the screen counted it.
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _inputFocus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _inputFocus
      ..removeListener(_onFocusChanged)
      ..dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    final focused = _inputFocus.hasFocus;
    if (focused == _focused) return;
    // A sheet or dialog over the screen holds the focus for a while: keep
    // the layout under it (the focus comes back when it closes).
    if (!focused && !(ModalRoute.of(context)?.isCurrent ?? true)) return;
    setState(() => _focused = focused);
  }

  @override
  Widget build(BuildContext context) {
    final fold = widget.fold;
    if (fold != null) {
      widget.onHeroChanged(false);
      return _FoldLayout(fold: fold, wide: widget.wide, focusNode: _inputFocus);
    }
    final idle = context.select<TranslateCubit, bool>(
      (cubit) => translateComposerIsIdle(cubit.state),
    );
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final hero =
        idle &&
        !_focused &&
        widget.height >= _TranslateBody.heroMinHeight(textScale);
    widget.onHeroChanged(hero);
    return _ComposerLayout(
      hero: hero,
      wide: widget.wide,
      focusNode: _inputFocus,
    );
  }
}

/// [_TranslateBody] without a hinge or fold: the greeting's slot, the
/// composer card ([ComposerCard]: the input region, the active options and
/// the language bar) and, on large screens, a spacer under the card that
/// centres it while the greeting shows ([hero]).
///
/// The slots are this screen's own rather than [ComposerLayout]'s: the
/// card's margin is part of it (taps there focus the field too), and its
/// width leaves room for the phone gutters once it is flat.
class _ComposerLayout extends StatelessWidget {
  const new({required this.hero, required this.wide, required this.focusNode});

  final bool hero;
  final bool wide;
  final FocusNode focusNode;

  /// Space around the card on phones.
  static const double cardMargin = ComposerLayout.margin;

  /// Side padding of the large-screen layout.
  static const double wideSide = ComposerLayout.wideSide;

  @override
  Widget build(BuildContext context) {
    final motion = TranslateLayout.motion(context);
    const gutter = TranslateLayout.gutter;
    final region = wide
        ? _WideRegion(hero: hero, focusNode: focusNode)
        : _NarrowRegion(hero: hero, focusNode: focusNode);
    // Taps on the card's empty space (and its margin) go to the text field.
    final card = ComposerCard(
      key: const Key('translate_composer'),
      outlined: hero,
      expand: !hero,
      onTap: hero ? focusNode.requestFocus : null,
      margin: wide
          ? const EdgeInsets.symmetric(horizontal: wideSide)
          : hero
          ? const EdgeInsets.fromLTRB(cardMargin, 8, cardMargin, cardMargin)
          : EdgeInsets.zero,
      flatBarPadding: wide
          ? const EdgeInsets.symmetric(vertical: 8)
          : const EdgeInsets.fromLTRB(gutter, 8, gutter, 8),
      bar: const LanguageBar(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            flex: hero ? 0 : 1,
            fit: hero ? FlexFit.loose : FlexFit.tight,
            child: region,
          ),
          AnimatedPadding(
            duration: motion,
            padding: EdgeInsets.symmetric(
              horizontal: hero || wide ? 0 : gutter,
            ),
            child: const ActiveOptionsBar(),
          ),
        ],
      ),
    );
    return Column(
      children: [
        // The greeting fills the space above the docked composer (on large
        // screens it sits right above the card).
        Flexible(
          flex: hero ? (wide ? 3 : 1) : 0,
          fit: FlexFit.tight,
          child: hero
              ? Align(
                  alignment: wide ? Alignment.bottomCenter : Alignment.center,
                  child: const SingleChildScrollView(child: TranslateHero()),
                )
              : const SizedBox(width: double.infinity),
        ),
        Flexible(
          flex: hero ? 0 : 1,
          fit: hero ? FlexFit.loose : FlexFit.tight,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: hero || !wide
                    ? TranslateLayout.maxColumnWidth +
                          2 * (wide ? wideSide : gutter)
                    : TranslateLayout.maxWideWidth,
              ),
              child: card,
            ),
          ),
        ),
        Flexible(
          flex: hero && wide ? 2 : 0,
          fit: FlexFit.tight,
          child: const SizedBox(width: double.infinity),
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _InputThread(
                focusNode: focusNode,
                compact: hero,
                minLines: hero ? 3 : 4,
                footer: hero ? null : const TranslationMemoryCard(),
              ),
              if (!hero) const _OutputSection(memory: false),
            ],
          ),
        ),
      ),
    );
  }
}

/// The input region on large screens: the input pane and, once active, a
/// hairline and the output pane beside it, like X's web columns.
class _WideRegion extends StatelessWidget {
  const new({required this.hero, required this.focusNode});

  final bool hero;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final output = hero ? 0.0 : (constraints.maxWidth - 1) / 2;
        return Row(
          key: const Key('translate_wide_layout'),
          crossAxisAlignment: hero
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                key: const Key('translate_input_pane'),
                physics: hero ? const NeverScrollableScrollPhysics() : null,
                padding: hero
                    ? const EdgeInsetsDirectional.only(
                        start: ComposerCard.padding,
                      )
                    : const EdgeInsetsDirectional.only(
                        top: 8,
                        end: TranslateLayout.paneGap / 2,
                        bottom: 32,
                      ),
                child: _InputThread(
                  focusNode: focusNode,
                  connector: false,
                  compact: hero,
                  minLines: hero ? 3 : 8,
                ),
              ),
            ),
            SizedBox(
              width: hero ? 0 : 1,
              child: hero ? null : const Hairline(vertical: true),
            ),
            SizedBox(
              width: output,
              child: hero
                  ? null
                  : const SingleChildScrollView(
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
        );
      },
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
    final input = SingleChildScrollView(
      key: const Key('translate_input_pane'),
      padding: stacked
          ? const EdgeInsetsDirectional.only(top: 8, bottom: 16)
          : const EdgeInsetsDirectional.only(
              top: 8,
              end: TranslateLayout.paneGap / 2,
              bottom: 32,
            ),
      child: _InputThread(
        focusNode: focusNode,
        connector: false,
        minLines: stacked ? 4 : 8,
      ),
    );
    const output = SingleChildScrollView(
      key: Key('translate_output_pane'),
      padding: EdgeInsetsDirectional.only(
        top: 8,
        start: TranslateLayout.paneGap / 2,
        bottom: 32,
      ),
      child: _OutputSection(separated: false),
    );
    const stackedOutput = SingleChildScrollView(
      key: Key('translate_output_pane'),
      padding: EdgeInsetsDirectional.only(top: 16, bottom: 32),
      child: _OutputSection(separated: false),
    );
    const bar = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ActiveOptionsBar(),
        Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: LanguageBar(),
        ),
      ],
    );
    final side = wide ? _ComposerLayout.wideSide : TranslateLayout.gutter;
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
                      const Padding(
                        padding: EdgeInsetsDirectional.only(
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
