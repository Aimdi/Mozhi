import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/on_device_ai_engine.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/device_conditions.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';

/// Whether [state] shows text typed for on-device AI that typing did not
/// translate because the device is strained: the engine is on-device AI
/// with translate-as-you-type on for AI ([instantAi]), the input has text
/// without a translation of it (none, or one of earlier text) and nothing
/// is on its way (see `TranslateCubit`, which holds typing back then).
bool onDeviceAiWaitsForEnter(TranslateState state, {required bool instantAi}) {
  final engine = state.engine;
  return engine != null &&
      isOnDeviceAiEngine(engine) &&
      instantAi &&
      !state.compareMode &&
      state.input.trim().isNotEmpty &&
      !state.isPending &&
      state.status != TranslateStatus.failure &&
      (state.result == null || state.isResultStale);
}

/// One line where the translation would be, while typing does not start
/// on-device AI because the phone is hot or battery saver is on
/// ([DeviceStrain], from [conditions], default [DeviceConditions.instance]):
/// "Your phone is hot, so on-device AI waits until you press Enter or
/// Translate." Shows nothing otherwise ([onDeviceAiWaitsForEnter]). Asks
/// Android only while on-device AI is the engine; a polite live region.
class OnDeviceAiStrainNote extends StatefulWidget {
  const new({this.conditions, super.key});

  final DeviceConditions? conditions;

  @override
  State<OnDeviceAiStrainNote> createState() => _OnDeviceAiStrainNoteState();
}

class _OnDeviceAiStrainNoteState extends State<OnDeviceAiStrainNote> {
  late final DeviceConditions _conditions;
  late final StreamSubscription<DeviceConditionsSnapshot> _changes;

  @override
  void initState() {
    super.initState();
    _conditions = widget.conditions ?? DeviceConditions.instance;
    _changes = _conditions.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_changes.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final instantAi = context.select<SettingsCubit, bool>(
      (cubit) => cubit.state.instantTranslateAi,
    );
    final waits = context.select<TranslateCubit, bool>(
      (cubit) => onDeviceAiWaitsForEnter(cubit.state, instantAi: instantAi),
    );
    // Read only then: asking Android is for on-device AI alone.
    final strain = waits ? _conditions.latest.strain : null;
    if (strain == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = AppPalette.of(context).secondaryText;
    final (icon, message) = switch (strain) {
      DeviceStrain.heat => (
        Icons.thermostat_outlined,
        l10n.translateOnDeviceAiPausedHeat,
      ),
      DeviceStrain.batterySaver => (
        Icons.battery_saver_outlined,
        l10n.translateOnDeviceAiPausedBatterySaver,
      ),
    };
    return Padding(
      key: const Key('translate_on_device_ai_strain'),
      padding: const EdgeInsetsDirectional.only(top: 12, end: 12, bottom: 4),
      child: Semantics(
        liveRegion: true,
        container: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(child: Icon(icon, size: 18, color: muted)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
