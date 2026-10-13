import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
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
  final bool Function()? enabled;

  @override
  bool isEnabled(T intent) => enabled?.call() ?? true;

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
  };

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
      shortcuts: shortcuts,
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
            enabled: () =>
                !_focusIsInTextField() ||
                HardwareKeyboard.instance.isControlPressed ||
                HardwareKeyboard.instance.isMetaPressed,
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: _TranslateAppBar(
              showTitle: width >= TranslateLayout.compactBreakpoint,
            ),
            body: BlocBuilder<TranslateCubit, TranslateState>(
              buildWhen: (previous, current) =>
                  previous.enginesStatus != current.enginesStatus ||
                  previous.engines.isEmpty != current.engines.isEmpty,
              builder: (context, state) {
                if (state.engines.isEmpty) {
                  return switch (state.enginesStatus) {
                    EnginesStatus.initial ||
                    EnginesStatus.loading => const TranslateSkeleton(),
                    EnginesStatus.ready ||
                    EnginesStatus.failure => const NoEnginesView(),
                  };
                }
                // Measure the pane itself: the shell's navigation rail
                // takes part of the window on large screens.
                return LayoutBuilder(
                  builder: (context, constraints) =>
                      constraints.maxWidth >= TranslateLayout.wideBreakpoint
                      ? const _WideLayout()
                      : const _NarrowLayout(),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _TranslateAppBar extends StatelessWidget implements PreferredSizeWidget {
  const new({required this.showTitle});

  final bool showTitle;

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
    return AppBar(
      titleSpacing: showTitle ? null : 8,
      title: showTitle
          ? Row(
              children: [
                Text(l10n.translateTitle),
                const SizedBox(width: 16),
                const Flexible(child: EngineSelectorButton()),
              ],
            )
          : const EngineSelectorButton(),
      actions: const [
        OptionsButton(),
        _CompareToggle(),
        MoreToolsButton(),
        SizedBox(width: 4),
      ],
    );
  }
}

class _CompareToggle extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return BlocBuilder<TranslateCubit, TranslateState>(
      buildWhen: (previous, current) =>
          previous.compareMode != current.compareMode ||
          previous.engines.length != current.engines.length,
      builder: (context, state) {
        final enabled = state.compareMode || state.engines.length > 1;
        return IconButton(
          key: const Key('translate_compare_toggle'),
          tooltip: state.compareMode
              ? l10n.translateCompareModeExit
              : l10n.translateCompareModeEnter,
          isSelected: state.compareMode,
          icon: const Icon(Icons.difference_outlined),
          selectedIcon: const Icon(Icons.difference),
          onPressed: enabled
              ? () => context.read<TranslateCubit>().setCompareMode(
                  enabled: !state.compareMode,
                )
              : null,
        );
      },
    );
  }
}

/// Output card or compare cards, followed by definitions and AI extras.
class _OutputSection extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final compareMode = context.select<TranslateCubit, bool>(
      (cubit) => cubit.state.compareMode,
    );
    if (compareMode) return const ComparePanel();
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [OutputCard(), WordChoicesPanel(), ExtrasSection()],
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
              InputCard(),
              SizedBox(height: TranslateLayout.gap),
              _OutputSection(),
            ],
          ),
        ),
      ),
    );
  }
}

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
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        key: Key('translate_input_pane'),
                        padding: EdgeInsets.only(bottom: 32),
                        child: InputCard(minLines: 8),
                      ),
                    ),
                    SizedBox(width: TranslateLayout.paneGap),
                    Expanded(
                      child: SingleChildScrollView(
                        key: Key('translate_output_pane'),
                        padding: EdgeInsets.only(bottom: 32),
                        child: _OutputSection(),
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
