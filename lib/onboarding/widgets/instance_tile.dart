import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/onboarding/cubit/onboarding_state.dart';
import 'package:mozhi/onboarding/widgets/onboarding_badge.dart';
import 'package:translation_repository/translation_repository.dart';

/// A selectable Mozhi instance with its live latency. Must be placed under
/// a `RadioGroup<String>` (the value is the instance url).
///
/// On narrow tiles or with large text the latency badges move below the
/// title instead of trailing it.
class InstanceTile extends StatelessWidget {
  const new({
    required this.instance,
    this.ping,
    this.isFastest = false,
    super.key,
  });

  final MozhiInstance instance;

  /// Null when the instance was not tested.
  final InstancePing? ping;
  final bool isFastest;

  /// Tiles narrower than this show the badges below the title.
  static const compactWidth = 420.0;

  @override
  Widget build(BuildContext context) {
    final host = Uri.tryParse(instance.url)?.host ?? instance.url;
    final hasLabel = instance.displayName != host;
    final ping = this.ping;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxWidth < compactWidth ||
            MediaQuery.textScalerOf(context).scale(1) > 1.3;
        final indicator = ping == null
            ? null
            : PingIndicator(ping: ping, isFastest: isFastest, inline: compact);
        final hostText = hasLabel
            ? Text(host, maxLines: 1, overflow: TextOverflow.ellipsis)
            : null;
        return RadioListTile<String>(
          value: instance.url,
          title: Text(
            instance.displayName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: compact && indicator != null
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ?hostText,
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: indicator,
                    ),
                  ],
                )
              : hostText,
          secondary: compact || indicator == null
              ? null
              : ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth * 0.4,
                  ),
                  child: indicator,
                ),
        );
      },
    );
  }
}

/// Latency badge (or progress) for an [InstancePing]: the speed, or
/// "Unreachable", "Timed out" or "Doesn't translate" (with the server's
/// message as a tooltip).
class PingIndicator extends StatelessWidget {
  const new({
    required this.ping,
    this.isFastest = false,
    this.inline = false,
    super.key,
  });

  final InstancePing ping;
  final bool isFastest;

  /// Lay the badges out in a row (below a title) instead of a column.
  final bool inline;

  /// Below this the latency reads as good (green).
  static const fast = Duration(milliseconds: 600);

  /// Below this the latency reads as acceptable (amber), above as slow.
  static const slow = Duration(milliseconds: 1500);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    switch (ping.status) {
      case PingStatus.pending:
        final spinner = Semantics(
          label: l10n.onboardingServiceChecking,
          child: const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
        return inline
            ? Align(alignment: AlignmentDirectional.centerStart, child: spinner)
            : spinner;
      case PingStatus.success:
        final latency = ping.latency ?? Duration.zero;
        final color = latency < fast
            ? colors.onboardingSuccess
            : latency < slow
            ? colors.onboardingWarning
            : colors.error;
        final badges = [
          OnboardingBadge(
            label: l10n.onboardingServiceLatency(latency.inMilliseconds),
            color: color,
            icon: Icons.speed,
          ),
          if (isFastest)
            OnboardingBadge(
              label: l10n.onboardingServiceFastest,
              color: colors.primary,
              icon: Icons.bolt,
            ),
        ];
        if (inline) {
          return Wrap(spacing: 8, runSpacing: 4, children: badges);
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          spacing: 4,
          children: badges,
        );
      case PingStatus.failure:
        return Tooltip(
          message: ping.error ?? '',
          child: OnboardingBadge(
            label: l10n.onboardingServiceUnreachable,
            color: colors.error,
            icon: Icons.cloud_off_outlined,
          ),
        );
      case PingStatus.timedOut:
        return OnboardingBadge(
          label: l10n.onboardingServiceTimedOut,
          color: colors.error,
          icon: Icons.timer_off_outlined,
        );
      case PingStatus.noTranslation:
        return Tooltip(
          message: ping.error ?? '',
          child: OnboardingBadge(
            label: l10n.onboardingServiceNoTranslation,
            color: colors.error,
            icon: Icons.error_outline,
          ),
        );
    }
  }
}
