import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:mozhi/usage/models/models.dart';
import 'package:mozhi/usage/widgets/usage_format.dart';

/// Shows a snack bar whenever [UsageTracker.warnings] reports that a
/// provider is near or at its monthly budget.
///
/// Place it below a [ScaffoldMessenger] (e.g. inside `MaterialApp.builder`
/// or around the app shell) or pass [messengerKey].
class UsageWarningListener extends StatefulWidget {
  const UsageWarningListener({
    required this.child,
    this.tracker,
    this.providerName,
    this.messengerKey,
    this.onWarning,
    super.key,
  });

  final Widget child;

  /// Defaults to the [UsageTracker] provided above.
  final UsageTracker? tracker;

  /// Display name of a provider id; null or unknown ids read "Your AI
  /// provider".
  final String? Function(String providerId)? providerName;

  /// Messenger to show the snack bar in; defaults to the nearest one.
  final GlobalKey<ScaffoldMessengerState>? messengerKey;

  /// Called for every warning, e.g. to offer opening the usage page.
  final ValueChanged<UsageWarning>? onWarning;

  @override
  State<UsageWarningListener> createState() => _UsageWarningListenerState();
}

class _UsageWarningListenerState extends State<UsageWarningListener> {
  StreamSubscription<UsageWarning>? _subscription;
  UsageTracker? _tracker;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _subscribe();
  }

  @override
  void didUpdateWidget(UsageWarningListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    _subscribe();
  }

  void _subscribe() {
    final tracker = widget.tracker ?? context.read<UsageTracker>();
    if (identical(tracker, _tracker)) return;
    unawaited(_subscription?.cancel());
    _tracker = tracker;
    _subscription = tracker.warnings.listen(_show);
  }

  void _show(UsageWarning warning) {
    if (!mounted) return;
    widget.onWarning?.call(warning);
    final messenger =
        widget.messengerKey?.currentState ?? ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final l10n = context.l10n;
    final name =
        widget.providerName?.call(warning.providerId) ?? l10n.usageSomeProvider;
    final message = switch (warning.level) {
      UsageBudgetLevel.limitReached => l10n.usageWarningLimitReached(name),
      _ => l10n.usageWarningNearLimit(
        name,
        context.usagePercent((warning.fraction * 100).floor() / 100),
      ),
    };
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
