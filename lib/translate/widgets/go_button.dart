import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/skeleton.dart' show loadingRevealDelay;

/// Whether the go button can translate [state]'s input: there is some.
bool translateGoEnabled(TranslateState state) => state.input.trim().isNotEmpty;

/// Whether the input of [state] is being translated: the compare run in
/// compare mode, the main translation otherwise.
bool translateGoBusy(TranslateState state) => state.compareMode
    ? state.comparing
    : state.status == TranslateStatus.translating;

/// The go button at the end of the `LanguageBar` (Kagi's rocket): always
/// shown, enabled while there is input. It translates the input right away
/// (`TranslateCubit.translate`, which also cancels a pending instant
/// translation) or again; in compare mode it compares.
///
/// Once a translation (or compare run) has taken [loadingRevealDelay], a
/// progress ring turns around it and pressing it stops the translation
/// (`TranslateCubit.stopTranslation`); quick translations never flash the
/// ring, and a press meant for "Translate" does not stop one that has just
/// started.
///
/// Its accessible name is "Translate" ("Stop translating" while it
/// stops); the tooltip adds the keyboard shortcut (Ctrl/Cmd+Enter).
class TranslateGoButton extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TranslateCubit, TranslateState>(
      buildWhen: (previous, current) =>
          translateGoEnabled(previous) != translateGoEnabled(current) ||
          translateGoBusy(previous) != translateGoBusy(current),
      builder: (context, state) {
        final cubit = context.read<TranslateCubit>();
        return _GoButton(
          enabled: translateGoEnabled(state),
          busy: translateGoBusy(state),
          onGo: () => unawaited(cubit.translate()),
          onStop: cubit.stopTranslation,
        );
      },
    );
  }
}

class _GoButton extends StatefulWidget {
  const new({
    required this.enabled,
    required this.busy,
    required this.onGo,
    required this.onStop,
  });

  final bool enabled;
  final bool busy;
  final VoidCallback onGo;
  final VoidCallback onStop;

  @override
  State<_GoButton> createState() => _GoButtonState();
}

class _GoButtonState extends State<_GoButton> {
  /// Turns [_stoppable] on once the work has run for [loadingRevealDelay].
  Timer? _reveal;

  /// Whether the button shows the progress ring and stops.
  bool _stoppable = false;

  @override
  void initState() {
    super.initState();
    _watch();
  }

  @override
  void didUpdateWidget(_GoButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.busy != widget.busy) _watch();
  }

  @override
  void dispose() {
    _reveal?.cancel();
    super.dispose();
  }

  void _watch() {
    _reveal?.cancel();
    _reveal = null;
    _stoppable = false;
    if (!widget.busy) return;
    _reveal = Timer(loadingRevealDelay, () {
      if (mounted) setState(() => _stoppable = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final stoppable = _stoppable && widget.enabled;
    final label = stoppable
        ? l10n.translateStopTranslating
        : l10n.translateTranslateButton;
    // One structure in both states, so a focused button keeps the focus
    // when it turns into the stop button and back.
    return Stack(
      alignment: Alignment.center,
      children: [
        Tooltip(
          message: stoppable
              ? l10n.translateStopTranslating
              : l10n.translateShortcutTranslate,
          child: IconButton(
            key: const Key('translate_translate_button'),
            style: stoppable
                ? IconButton.styleFrom(
                    backgroundColor: Theme.of(context)
                        .colorScheme
                        .secondaryContainer,
                    foregroundColor: Theme.of(context)
                        .colorScheme
                        .onSecondaryContainer,
                  )
                : _filledStyle(Theme.of(context).colorScheme),
            onPressed: !widget.enabled
                ? null
                : stoppable
                ? widget.onStop
                : widget.onGo,
            icon: Icon(
              stoppable ? Icons.stop_rounded : Icons.rocket_launch,
              semanticLabel: label,
            ),
          ),
        ),
        if (stoppable)
          // Decorative: the translation itself says "Translating…".
          const IgnorePointer(
            child: ExcludeSemantics(
              child: SizedBox.square(
                dimension: 46,
                child: CircularProgressIndicator(
                  key: Key('translate_go_progress'),
                  strokeWidth: 2.5,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Material 3's filled icon button.
  static ButtonStyle _filledStyle(ColorScheme scheme) => IconButton.styleFrom(
    backgroundColor: scheme.primary,
    foregroundColor: scheme.onPrimary,
    disabledBackgroundColor: scheme.onSurface.withValues(alpha: 0.12),
    disabledForegroundColor: scheme.onSurface.withValues(alpha: 0.38),
  );
}
