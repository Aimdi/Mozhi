import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';

/// Whether [current] changes how long history entries are kept.
bool historyRetentionChanged(AppSettings previous, AppSettings current) =>
    previous.historyRetention != current.historyRetention;

/// Whether [current] turns incognito on or off.
bool historyIncognitoChanged(AppSettings previous, AppSettings current) =>
    previous.incognito != current.incognito;

/// Whether [current] turns "Save history" on or off.
bool historySavingChanged(AppSettings previous, AppSettings current) =>
    previous.saveHistory != current.saveHistory;

/// Keeps the [HistoryCubit] in sync with [AppSettings.historyRetention]
/// (history auto-delete): applies the current setting when inserted and
/// every change after that, so expired entries are deleted right away.
///
/// It also hands [AppSettings.incognito] and [AppSettings.saveHistory] to
/// the cubit ([HistoryCubit.setIncognito], [HistoryCubit.setSaveHistory]),
/// so no automatic history is written while either pauses it, whichever
/// screen translates, and favourites starred meanwhile are kept only as
/// favourites.
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
    final settings = context.read<SettingsCubit>().state;
    _apply(settings);
    _applyIncognito(settings);
    _applySaving(settings);
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

  void _applyIncognito(AppSettings settings) =>
      context.read<HistoryCubit>().setIncognito(enabled: settings.incognito);

  void _applySaving(AppSettings settings) => context
      .read<HistoryCubit>()
      .setSaveHistory(enabled: settings.saveHistory);

  /// Deletes the entries that expired since the retention was last applied.
  void _prune() {
    if (!mounted) return;
    final maxAge = context.read<SettingsCubit>().state.historyRetention.maxAge;
    if (maxAge == null) return;
    unawaited(context.read<HistoryCubit>().applyRetention(maxAge));
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocListener(
      listeners: [
        BlocListener<SettingsCubit, AppSettings>(
          listenWhen: historyRetentionChanged,
          listener: (context, settings) => _apply(settings),
        ),
        BlocListener<SettingsCubit, AppSettings>(
          listenWhen: historyIncognitoChanged,
          listener: (context, settings) => _applyIncognito(settings),
        ),
        BlocListener<SettingsCubit, AppSettings>(
          listenWhen: historySavingChanged,
          listener: (context, settings) => _applySaving(settings),
        ),
      ],
      child: widget.child,
    );
  }
}
