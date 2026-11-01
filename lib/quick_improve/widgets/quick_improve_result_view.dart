import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/widgets/proofread_diff_text.dart';
import 'package:mozhi/proofread/widgets/proofread_labels.dart';
import 'package:mozhi/quick_improve/cubit/quick_improve_state.dart';
import 'package:mozhi/translate/widgets/on_device_ai_loading.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart'
    show TranslateLayout;
import 'package:translation_repository/translation_repository.dart'
    show ConsentRequiredException, DataDestination;

/// The result area of the quick improve sheet: progress while the engines
/// load and while the text is proofread, the improved text with its
/// changes highlighted (or plain, with the eye button), or why there is
/// none: no AI engine ([onAddProvider], [onSetUpOnDeviceAi]), engines that
/// failed to load ([onReloadEngines]), a consent to give (inline, as in
/// quick translate) or an error with Retry ([onRetry]).
class QuickImproveResultView extends StatefulWidget {
  const new({
    required this.state,
    required this.onRetry,
    this.onReloadEngines,
    this.onAddProvider,
    this.onSetUpOnDeviceAi,
    this.destination,
    super.key,
  });

  final QuickImproveState state;
  final VoidCallback onRetry;

  /// Loads the engine list again ([QuickImproveStatus.enginesFailed]).
  final VoidCallback? onReloadEngines;

  /// Opens the AI provider settings ([QuickImproveStatus.noEngine]); no
  /// button without it.
  final VoidCallback? onAddProvider;

  /// Opens the on-device AI settings ([QuickImproveStatus.noEngine]),
  /// where a model fits the phone; no button without it.
  final VoidCallback? onSetUpOnDeviceAi;

  /// Where the text was sent, shown under the improved text.
  final DataDestination? destination;

  @override
  State<QuickImproveResultView> createState() => _QuickImproveResultViewState();
}

class _QuickImproveResultViewState extends State<QuickImproveResultView> {
  bool _showChanges = true;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    final state = widget.state;

    final child = switch (state.status) {
      QuickImproveStatus.loadingEngines => _Progress(
        key: const ValueKey('loadingEngines'),
        label: l10n.translateLoadingEngines,
      ),
      QuickImproveStatus.improving => OnDeviceAiExtraLoading(
        key: const ValueKey('improving'),
        engine: state.engine,
        child: _Progress(label: l10n.quickImproveImproving),
      ),
      QuickImproveStatus.noEngine => _Message(
        key: const ValueKey('noEngine'),
        icon: Icons.spellcheck,
        color: palette.secondaryText,
        title: l10n.proofreadEmptyTitle,
        message: widget.onSetUpOnDeviceAi == null
            ? l10n.proofreadEmptyBody
            : l10n.proofreadEmptyBodyOnDevice,
        action: _noEngineActions(l10n),
      ),
      QuickImproveStatus.enginesFailed => _Message(
        key: const ValueKey('enginesFailed'),
        icon: Icons.cloud_off_outlined,
        color: scheme.error,
        title: l10n.proofreadEnginesErrorTitle,
        message: l10n.proofreadEnginesErrorBody,
        action: widget.onReloadEngines == null
            ? null
            : FilledButton.tonalIcon(
                key: const Key('quick_improve_reload_engines'),
                onPressed: widget.onReloadEngines,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.commonRetry),
              ),
      ),
      QuickImproveStatus.failure when state.error is ConsentRequiredException =>
        ConsentInlinePrompt(
          key: const Key('quick_improve_consent'),
          consent: state.error! as ConsentRequiredException,
          onGranted: widget.onRetry,
        ),
      QuickImproveStatus.failure => _Message(
        key: const ValueKey('failure'),
        icon: Icons.error_outline,
        color: scheme.error,
        title: l10n.quickImproveErrorTitle,
        message: l10n.proofreadError(state.error),
        action: FilledButton.icon(
          key: const Key('quick_improve_error_retry'),
          onPressed: state.canImprove ? widget.onRetry : null,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.commonRetry),
        ),
      ),
      QuickImproveStatus.success when state.isUnchanged => _Message(
        key: const ValueKey('unchanged'),
        icon: Icons.check_circle_outline,
        color: palette.success,
        message: l10n.quickImproveUnchanged,
        footer: _footer(context, state),
      ),
      QuickImproveStatus.success => _result(context, state),
    };

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 150),
      layoutBuilder: (current, previous) =>
          Stack(children: [...previous, ?current]),
      child: child,
    );
  }

  Widget? _noEngineActions(AppLocalizations l10n) {
    final addProvider = widget.onAddProvider;
    final onDevice = widget.onSetUpOnDeviceAi;
    final buttons = [
      if (onDevice != null)
        FilledButton.icon(
          key: const Key('quick_improve_set_up_on_device_ai'),
          onPressed: onDevice,
          icon: const Icon(Icons.memory),
          label: Text(l10n.commonSetUpOnDeviceAi),
        ),
      if (addProvider != null && onDevice == null)
        FilledButton.icon(
          key: const Key('quick_improve_add_provider'),
          onPressed: addProvider,
          icon: const Icon(Icons.add),
          label: Text(l10n.proofreadEmptyAction),
        )
      else if (addProvider != null)
        OutlinedButton.icon(
          key: const Key('quick_improve_add_provider'),
          onPressed: addProvider,
          icon: const Icon(Icons.add),
          label: Text(l10n.proofreadEmptyAction),
        ),
    ];
    if (buttons.isEmpty) return null;
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }

  Widget _result(BuildContext context, QuickImproveState state) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final text = state.improvedText;
    final style = TranslateLayout.outputTextStyle(
      context,
      text.length,
    )?.copyWith(height: 1.45);
    return Column(
      key: const ValueKey('result'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.quickImproveResultLabel,
                style: theme.textTheme.labelLarge,
              ),
            ),
            IconButton(
              key: const Key('quick_improve_show_changes'),
              tooltip: _showChanges
                  ? l10n.proofreadHideChanges
                  : l10n.proofreadShowChanges,
              isSelected: _showChanges,
              color: theme.colorScheme.primary,
              onPressed: () => setState(() => _showChanges = !_showChanges),
              icon: const Icon(Icons.visibility_off_outlined),
              selectedIcon: const Icon(Icons.visibility_outlined),
            ),
          ],
        ),
        Semantics(
          liveRegion: true,
          label: l10n.quickImproveResultLabel,
          child: _showChanges
              ? ProofreadDiffText(
                  key: const Key('quick_improve_diff'),
                  segments: state.segments,
                  style: style,
                )
              : SelectableText(
                  text,
                  key: const Key('quick_improve_text'),
                  style: style,
                ),
        ),
        ?_footer(context, state),
      ],
    );
  }

  /// The summary, the personal data the shield kept on the device and
  /// where the text was sent.
  Widget? _footer(BuildContext context, QuickImproveState state) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final summary = state.result?.summary.trim() ?? '';
    final masked = state.maskedPersonalData;
    final destination = widget.destination;
    if (summary.isEmpty && masked == 0 && destination == null) return null;
    final small = theme.textTheme.bodySmall?.copyWith(
      color: palette.secondaryText,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          if (summary.isNotEmpty)
            Row(
              key: const Key('quick_improve_summary'),
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Icon(
                  Icons.auto_awesome_outlined,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                Expanded(
                  child: Text(
                    summary,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: palette.secondaryText,
                    ),
                  ),
                ),
              ],
            ),
          // Personal data the shield kept on this device, as in the
          // Proofread tab.
          if (masked > 0)
            Semantics(
              key: const Key('quick_improve_personal_data_kept'),
              container: true,
              hint: l10n.translatePersonalDataKeptHint,
              child: Row(
                spacing: 8,
                children: [
                  Icon(
                    Icons.shield_outlined,
                    size: 18,
                    color: palette.secondaryText,
                  ),
                  Expanded(
                    child: Text(
                      l10n.translatePersonalDataKept(masked),
                      style: small,
                    ),
                  ),
                ],
              ),
            ),
          if (destination != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: DestinationChip(
                key: const Key('quick_improve_destination'),
                destination: destination,
                engineId: state.engine?.id,
              ),
            ),
        ],
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const new({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(
            key: const Key('quick_improve_progress'),
            semanticsLabel: label,
            borderRadius: BorderRadius.circular(
              AppLook.of(context).controlRadius(4),
            ),
          ),
          const SizedBox(height: 12),
          ExcludeSemantics(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppPalette.of(context).secondaryText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const new({
    required this.icon,
    required this.color,
    required this.message,
    this.title,
    this.action,
    this.footer,
    super.key,
  });

  final IconData icon;
  final Color color;
  final String? title;
  final String message;
  final Widget? action;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          liveRegion: true,
          container: true,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title case final String title) ...[
                      Text(title, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 4),
                    ],
                    Text(
                      message,
                      style: theme.textTheme.bodyLarge?.copyWith(color: color),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (action case final Widget action) ...[
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 36),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: action,
            ),
          ),
        ],
        ?footer,
      ],
    );
  }
}
