import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/onboarding/cubit/onboarding_state.dart';
import 'package:mozhi/onboarding/widgets/onboarding_badge.dart';
import 'package:translation_repository/translation_repository.dart';

/// A selectable Mozhi instance with its live latency. Must be placed under
/// a `RadioGroup<String>` (the value is the instance url).
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

  @override
  Widget build(BuildContext context) {
    final host = Uri.tryParse(instance.url)?.host ?? instance.url;
    final hasLabel = instance.displayName != host;
    return RadioListTile<String>(
      value: instance.url,
      title: Text(
        instance.displayName,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: hasLabel
          ? Text(host, maxLines: 1, overflow: TextOverflow.ellipsis)
          : null,
      secondary: ping == null
          ? null
          : PingIndicator(ping: ping!, isFastest: isFastest),
    );
  }
}

/// Latency badge (or progress) for an [InstancePing].
class PingIndicator extends StatelessWidget {
  const new({required this.ping, this.isFastest = false, super.key});

  final InstancePing ping;
  final bool isFastest;

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
        return Semantics(
          label: l10n.onboardingServiceChecking,
          child: const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case PingStatus.success:
        final latency = ping.latency ?? Duration.zero;
        final color = latency < fast
            ? colors.onboardingSuccess
            : latency < slow
            ? colors.onboardingWarning
            : colors.error;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            OnboardingBadge(
              label: l10n.onboardingServiceLatency(latency.inMilliseconds),
              color: color,
              icon: Icons.speed,
            ),
            if (isFastest) ...[
              const SizedBox(height: 4),
              OnboardingBadge(
                label: l10n.onboardingServiceFastest,
                color: colors.primary,
                icon: Icons.bolt,
              ),
            ],
          ],
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
    }
  }
}
