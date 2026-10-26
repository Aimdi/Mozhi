import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/presets/cubit/glossary_cubit.dart';
import 'package:mozhi/presets/cubit/presets_cubit.dart';
import 'package:mozhi/quick_translate/quick_translate_host.dart';
import 'package:mozhi/screen_translate/screen_translate_host.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/sync/data/sync_service.dart';

/// Runs [service] while the app runs (no background service): syncs once
/// after the first frame ([SyncService.start]), tells it about changes to
/// the data the app holds ([SyncService.notifyChanged]: the history,
/// settings, presets, glossaries and phrasebook found above, plus
/// [changes]) and syncs a pending change when the app goes to the
/// background ([SyncService.flush]).
///
/// Changes cost nothing until sync is set up, and then nothing on the
/// network unless the synced data changed (see [SyncService]).
class SyncScope extends StatefulWidget {
  const new({
    required this.service,
    required this.child,
    this.changes = const [],
    super.key,
  });

  /// [child] under a [SyncScope] for [service]; just [child] without a
  /// service, and in the quick translate and screen-translate windows
  /// (second copies of the app that live for one translation: the main
  /// window syncs).
  static Widget wrap({required SyncService? service, required Widget child}) {
    if (service == null ||
        QuickTranslateHost.instance.isActive ||
        ScreenTranslateHost.instance.isActive) {
      return child;
    }
    return SyncScope(service: service, child: child);
  }

  final SyncService service;
  final Widget child;

  /// More changes to listen to (data the cubits above don't hold).
  final List<Stream<Object?>> changes;

  @override
  State<SyncScope> createState() => _SyncScopeState();
}

class _SyncScopeState extends State<SyncScope> with WidgetsBindingObserver {
  final _subscriptions = <StreamSubscription<Object?>>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    T? maybe<T>() {
      try {
        return context.read<T>();
      } on ProviderNotFoundException {
        return null;
      }
    }

    final streams = <Stream<Object?>>[
      ?maybe<HistoryCubit>()?.stream,
      ?maybe<SettingsCubit>()?.stream,
      ?maybe<PresetsCubit>()?.stream,
      ?maybe<GlossaryCubit>()?.stream,
      ?maybe<PhrasebookRepository>()?.changes,
      ...widget.changes,
    ];
    for (final stream in streams) {
      _subscriptions.add(stream.listen((_) => widget.service.notifyChanged()));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.service.start());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(widget.service.flush());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
