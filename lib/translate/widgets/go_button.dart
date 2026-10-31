import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart' show AppLook;
import 'package:mozhi/core/haptics.dart';
import 'package:mozhi/core/widgets/composer_card.dart' show ComposerGoButton;
import 'package:mozhi/core/widgets/x_ui.dart' show AppPalette;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/skeleton.dart' show loadingRevealDelay;
import 'package:mozhi/translate/widgets/terminal_chrome.dart';

/// Whether the go button can translate [state]'s input: there is some.
bool translateGoEnabled(TranslateState state) => state.input.trim().isNotEmpty;

/// Whether the input of [state] is being translated: the compare run in
/// compare mode, the main translation otherwise.
bool translateGoBusy(TranslateState state) => state.compareMode
    ? state.comparing
    : state.status == TranslateStatus.translating;

/// Whether instant translation translates [state]'s input by itself with
/// [settings] (`AppSettings.instantTranslate` for Mozhi and on-device
/// engines, `instantTranslateAi` for AI engines); never in compare mode,
/// where the go button runs the comparison.
bool translateGoInstant(TranslateState state, AppSettings settings) =>
    _instant(state, (settings.instantTranslate, settings.instantTranslateAi));

bool _instant(TranslateState state, (bool, bool) instant) {
  final engine = state.engine;
  if (engine == null || state.compareMode) return false;
  final (mozhi, ai) = instant;
  return engine.isAi ? ai : mozhi;
}

/// The go button at the trailing end of the `LanguageBar`, like the go
/// buttons of Dictionary and Proofread ([ComposerGoButton]'s size and
/// arrow: a 40 dp circle in a 48 dp target, so it never overflows the
/// bar). Enabled while there is input, it translates the input right away
/// (`TranslateCubit.translate`, which also cancels a pending instant
/// translation) or again; in compare mode it compares.
///
/// When instant translation already handles typed text ([instant]; null:
/// [translateGoInstant] with the `SettingsCubit` above, when there is one)
/// the button steps back to a quiet arrow without its accent fill
/// ("translate now"), in the same place so the bar never moves, and only
/// stands out as the stop button while a translation runs.
///
/// Once a translation (or compare run) has taken [loadingRevealDelay], a
/// progress ring turns around it and pressing it stops the translation
/// (`TranslateCubit.stopTranslation`); quick translations never flash the
/// ring, and a press meant for "Translate" does not stop one that has just
/// started.
///
/// Its accessible name is "Translate" ("Stop translating" while it
/// stops); the tooltip adds the keyboard shortcut (Ctrl/Cmd+Enter).
///
/// In the terminal look ([AppLook.isTerminal]) it is the accent-filled
/// `run ⏎` at the end of the input box (`^C stop` with a small progress
/// ring while it stops); the visible words are decoration, the name and
/// tooltip stay the same.
class TranslateGoButton extends StatelessWidget {
  const new({this.instant, super.key});

  /// Whether instant translation handles typed text (see the class docs);
  /// null works it out from the settings.
  final bool? instant;

  @override
  Widget build(BuildContext context) {
    final settings = _instantSettingsOf(context);
    return BlocBuilder<TranslateCubit, TranslateState>(
      buildWhen: (previous, current) =>
          translateGoEnabled(previous) != translateGoEnabled(current) ||
          translateGoBusy(previous) != translateGoBusy(current) ||
          previous.engine != current.engine ||
          previous.compareMode != current.compareMode,
      builder: (context, state) {
        final cubit = context.read<TranslateCubit>();
        return _GoButton(
          enabled: translateGoEnabled(state),
          busy: translateGoBusy(state),
          quiet: instant ?? (settings != null && _instant(state, settings)),
          onGo: () {
            Haptics.light(context);
            unawaited(cubit.translate());
          },
          onStop: cubit.stopTranslation,
        );
      },
    );
  }

  /// The instant translation settings (Mozhi, AI) the button follows
  /// (rebuilding when they change), or null without a `SettingsCubit`
  /// above.
  (bool, bool)? _instantSettingsOf(BuildContext context) {
    try {
      return context.select<SettingsCubit, (bool, bool)>(
        (cubit) =>
            (cubit.state.instantTranslate, cubit.state.instantTranslateAi),
      );
    } on ProviderNotFoundException {
      return null;
    }
  }
}

class _GoButton extends StatefulWidget {
  const new({
    required this.enabled,
    required this.busy,
    required this.onGo,
    required this.onStop,
    this.quiet = false,
  });

  final bool enabled;
  final bool busy;

  /// Instant translation handles the input: no accent fill.
  final bool quiet;
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
    final scheme = Theme.of(context).colorScheme;
    final stoppable = _stoppable && widget.enabled;
    final label = stoppable
        ? l10n.translateStopTranslating
        : l10n.translateTranslateButton;
    if (AppLook.of(context).isTerminal) {
      return _terminal(context, label: label, stoppable: stoppable);
    }
    final style = stoppable
        ? ComposerGoButton.styleOf(scheme, tonal: true)
        : widget.quiet
        ? ComposerGoButton.styleOf(scheme).copyWith(
            backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
            foregroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.disabled)
                  ? scheme.onSurface.withValues(alpha: 0.38)
                  : scheme.primary,
            ),
          )
        : ComposerGoButton.styleOf(scheme);
    // One structure in both states, so a focused button keeps the focus
    // when it turns into the stop button and back.
    return SizedBox.square(
      dimension: ComposerGoButton.targetSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Its own node, so the tooltip stays with the button (else it
          // would join the nearest container, e.g. the whole screen).
          Semantics(
            container: true,
            child: Tooltip(
              message: stoppable
                  ? l10n.translateStopTranslating
                  : l10n.translateShortcutTranslate,
              // The label already says "Stop translating".
              excludeFromSemantics: stoppable,
              child: IconButton(
                key: const Key('translate_translate_button'),
                // Filled (accent) to go, tonal to stop.
                style: style,
                onPressed: !widget.enabled
                    ? null
                    : stoppable
                    ? widget.onStop
                    : widget.onGo,
                icon: Icon(
                  stoppable ? Icons.stop_rounded : ComposerGoButton.defaultIcon,
                  semanticLabel: label,
                ),
              ),
            ),
          ),
          if (stoppable)
            // Decorative: the translation itself says "Translating…".
            const IgnorePointer(
              child: ExcludeSemantics(
                child: SizedBox.square(
                  dimension: ComposerGoButton.ringSize,
                  child: CircularProgressIndicator(
                    key: Key('translate_go_progress'),
                    strokeWidth: 2.5,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The terminal look's `run ⏎` (see [TranslateGoButton]).
  Widget _terminal(
    BuildContext context, {
    required String label,
    required bool stoppable,
  }) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    final filled = widget.enabled && !stoppable;
    return Semantics(
      container: true,
      child: Tooltip(
        message: stoppable
            ? l10n.translateStopTranslating
            : l10n.translateShortcutTranslate,
        excludeFromSemantics: stoppable,
        child: TextButton(
          key: const Key('translate_translate_button'),
          style: TextButton.styleFrom(
            minimumSize: const Size(64, 44),
            tapTargetSize: MaterialTapTargetSize.padded,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            shape: RoundedRectangleBorder(
              side: BorderSide(
                color: filled ? scheme.primary : palette.hairline,
              ),
            ),
            backgroundColor: filled ? scheme.primary : Colors.transparent,
            foregroundColor: filled ? scheme.onPrimary : scheme.primary,
            disabledBackgroundColor: Colors.transparent,
            disabledForegroundColor: palette.secondaryText,
            textStyle: Theme.of(context).textTheme.labelLarge
                ?.copyWith(fontSize: 13, fontWeight: FontWeight.w800),
          ),
          onPressed: !widget.enabled
              ? null
              : stoppable
              ? widget.onStop
              : widget.onGo,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (stoppable) ...[
                const ExcludeSemantics(
                  child: SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(
                      key: Key('translate_go_progress'),
                      strokeWidth: 2,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Semantics(
                  label: label,
                  excludeSemantics: true,
                  child: TerminalGlyph(stoppable ? '^C stop' : 'run ⏎'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
