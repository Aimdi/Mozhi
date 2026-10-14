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
/// Reads both cubits from the context; place it below their providers.
class HistoryRetentionListener extends StatefulWidget {
  const new({required this.child, super.key});

  final Widget child;

  @override
  State<HistoryRetentionListener> createState() =>
      _HistoryRetentionListenerState();
}

class _HistoryRetentionListenerState extends State<HistoryRetentionListener> {
  @override
  void initState() {
    super.initState();
    _apply(context.read<SettingsCubit>().state);
  }

  void _apply(AppSettings settings) => unawaited(
    context.read<HistoryCubit>().applyRetention(
      settings.historyRetention.maxAge,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return BlocListener<SettingsCubit, AppSettings>(
      listenWhen: historyRetentionChanged,
      listener: (context, settings) => _apply(settings),
      child: widget.child,
    );
  }
}
