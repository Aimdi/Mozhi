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

/// Adaptive translate screen: single column on phones, input and output
/// side by side from [TranslateLayout.wideBreakpoint].
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
                return width >= TranslateLayout.wideBreakpoint
                    ? const _WideLayout()
                    : const _NarrowLayout();
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
      actions: const [OptionsButton(), _CompareToggle(), SizedBox(width: 8)],
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
          icon: const Icon(Icons.view_agenda_outlined),
          selectedIcon: const Icon(Icons.view_agenda),
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
