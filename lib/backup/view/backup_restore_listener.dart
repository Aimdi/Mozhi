import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/backup/sections/app_backup_sections.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/presets/cubit/glossary_cubit.dart';
import 'package:mozhi/presets/cubit/presets_cubit.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';

/// After a backup, sync or another phone restored data
/// ([BackupRegistry.restored]), reloads what the app holds in memory of
/// it: the settings ([SettingsCubit]), the history ([HistoryCubit], which
/// applies "Delete history automatically" again), the presets
/// ([PresetsCubit]) and the glossaries ([GlossaryCubit]), each when its
/// section was restored.
///
/// Place it below those cubits; without a [BackupRegistry] above it does
/// nothing. Renders [child].
class BackupRestoreListener extends StatefulWidget {
  const new({required this.child, super.key});

  final Widget child;

  @override
  State<BackupRestoreListener> createState() => _BackupRestoreListenerState();
}

class _BackupRestoreListenerState extends State<BackupRestoreListener> {
  StreamSubscription<Set<String>>? _subscription;

  @override
  void initState() {
    super.initState();
    final registry = _maybe<BackupRegistry>();
    _subscription = registry?.restored.listen(_reload);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  T? _maybe<T>() {
    try {
      return context.read<T>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  void _reload(Set<String> sections) {
    if (!mounted) return;
    if (sections.contains(SettingsBackupSection.sectionId)) {
      unawaited(_maybe<SettingsCubit>()?.load());
    }
    if (sections.contains(HistoryBackupSection.sectionId)) {
      unawaited(_maybe<HistoryCubit>()?.load());
    }
    if (sections.contains(PresetsBackupSection.sectionId)) {
      unawaited(_maybe<PresetsCubit>()?.load());
    }
    if (sections.contains(GlossariesBackupSection.sectionId)) {
      unawaited(_maybe<GlossaryCubit>()?.load());
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
