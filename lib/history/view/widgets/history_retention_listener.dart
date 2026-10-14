import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';

/// Whether [current] changes how long history entries are kept.
bool historyRetentionChanged(AppSettings previous, AppSettings current) =>
    previous.historyRetention != current.historyRetention;

/// Keeps the [HistoryCubit] in sync with [AppSettings.historyRetention]
/// (history auto-delete): applies the current setting when inserted and
/// every change after that, so expired entries are deleted right away.
///
/// Entries also expire while the app keeps running, so with a retention
/// set it is applied again whenever the app is resumed and every
/// [pruneInterval] (an app left open for days, e.g. on desktop or the web).
///
/// Reads both cubits from the context; place it below their providers.
class HistoryRetentionListener extends StatefulWidget {
  const new({required this.child, super.key});

  /// How often the retention is applied again while the app runs.
  static const pruneInterval = Duration(hours: 1);

  final Widget child;

  @override
  State<HistoryRetentionListener> createState() =>
      _HistoryRetentionListenerState();
}

class _HistoryRetentionListenerState extends State<HistoryRetentionListener> {
  late final AppLifecycleListener _lifecycle;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _prune);
    _apply(context.read<SettingsCubit>().state);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  void _apply(AppSettings settings) {
    final maxAge = settings.historyRetention.maxAge;
    _timer?.cancel();
    _timer = maxAge == null
        ? null
        : Timer.periodic(
            HistoryRetentionListener.pruneInterval,
            (_) => _prune(),
          );
    unawaited(context.read<HistoryCubit>().applyRetention(maxAge));
  }

  /// Deletes the entries that expired since the retention was last applied.
  void _prune() {
    if (!mounted) return;
    final maxAge = context.read<SettingsCubit>().state.historyRetention.maxAge;
    if (maxAge == null) return;
    unawaited(context.read<HistoryCubit>().applyRetention(maxAge));
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<SettingsCubit, AppSettings>(
      listenWhen: historyRetentionChanged,
      listener: (context, settings) => _apply(settings),
      child: widget.child,
    );
  }
}
