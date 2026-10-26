import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/live/live_engine.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// "Translate live with": a sheet of the engines the live features (the
/// live camera, live captions) may translate with, the one in use checked
/// ([resolveLiveEngine]). The offline engine comes first (the default),
/// then on-device AI models, then the other engines.
///
/// Picking an engine that sends text off the device
/// ([liveEngineLeavesDevice]) first asks, once, in a dialog that says it
/// will get everything live translation reads; only an OK stores it
/// (`SettingsCubit.setLiveEngine`; the offline engine is stored as null).
/// Cancelling the sheet or the dialog keeps the engine in use.
///
/// Reads the [SettingsCubit] above [context]; the engines come from the
/// `TranslateCubit` when there is one.
Future<void> showLiveEnginePicker(BuildContext context) async {
  final settings = context.read<SettingsCubit>();
  final engines = _engines(context);
  final current = resolveLiveEngine(settings.state, engines);
  final picked = await showModalBottomSheet<TranslationEngine>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => LiveEnginePickerSheet(
      engines: liveEngineChoices(engines),
      selected: current,
    ),
  );
  if (picked == null || picked.id == current.id || !context.mounted) return;
  if (liveEngineLeavesDevice(picked)) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => LiveEngineConfirmDialog(engine: picked),
    );
    if (!(confirmed ?? false) || !context.mounted) return;
  }
  settings.setLiveEngine(
    picked.id == TranslationEngine.offlineId ? null : picked.id,
  );
}

/// The engines the app offers now, empty without a translator.
List<TranslationEngine> _engines(BuildContext context) {
  try {
    return context.read<TranslateCubit>().state.engines;
  } on ProviderNotFoundException {
    return const [];
  }
}

/// [engines] in the picker's order: the offline engine first (also when
/// [engines] lacks it), then the on-device AI models, then the others as
/// they come. Each engine once.
List<TranslationEngine> liveEngineChoices(List<TranslationEngine> engines) {
  final seen = <String>{TranslationEngine.offlineId};
  final offline = engines.firstWhere(
    (engine) => engine.id == TranslationEngine.offlineId,
    orElse: TranslationEngine.offline,
  );
  final onDevice = <TranslationEngine>[];
  final others = <TranslationEngine>[];
  for (final engine in engines) {
    if (!seen.add(engine.id)) continue;
    (engine.isOnDevice ? onDevice : others).add(engine);
  }
  return [offline, ...onDevice, ...others];
}

/// The sheet of [showLiveEnginePicker]; pops the chosen engine.
class LiveEnginePickerSheet extends StatelessWidget {
  const new({required this.engines, required this.selected, super.key});

  final List<TranslationEngine> engines;
  final TranslationEngine selected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        key: const Key('live_engine_picker'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Semantics(
              header: true,
              child: Text(
                l10n.liveEnginePickerTitle,
                style: theme.textTheme.titleLarge,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              l10n.liveEnginePickerBody,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: palette.secondaryText,
              ),
            ),
          ),
          for (final engine in engines) _EngineTile(engine, selected: selected),
        ],
      ),
    );
  }
}

class _EngineTile extends StatelessWidget {
  const new(this.engine, {required this.selected});

  final TranslationEngine engine;
  final TranslationEngine selected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final isSelected = engine.id == selected.id;
    final where = engine.isOffline
        ? l10n.liveEngineOffline
        : engine.isOnDevice
        ? l10n.liveEngineOnDevice
        : l10n.liveEngineNetwork;
    final subtitle = engine.subtitle;
    return ListTile(
      key: Key('live_engine_${engine.id}'),
      selected: isSelected,
      leading: Icon(
        engine.isOffline
            ? Icons.phone_android
            : engine.isOnDevice
            ? Icons.memory
            : Icons.cloud_outlined,
      ),
      title: Text(engine.name),
      subtitle: Text(
        subtitle == null || subtitle.isEmpty ? where : '$where · $subtitle',
      ),
      trailing: isSelected
          ? Icon(Icons.check, color: theme.colorScheme.primary)
          : null,
      onTap: () => Navigator.of(context).pop(engine),
    );
  }
}

/// Asks before a live feature streams text to [engine], an engine that
/// sends it off the device; pops true for OK.
class LiveEngineConfirmDialog extends StatelessWidget {
  const new({required this.engine, super.key});

  final TranslationEngine engine;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      key: const Key('live_engine_confirm'),
      icon: const Icon(Icons.cloud_outlined),
      title: Text(l10n.liveEngineConfirmTitle(engine.name)),
      content: Text(l10n.liveEngineConfirmBody(engine.name)),
      actions: [
        TextButton(
          key: const Key('live_engine_confirm_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: const Key('live_engine_confirm_ok'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.liveEngineConfirmAction(engine.name)),
        ),
      ],
    );
  }
}
