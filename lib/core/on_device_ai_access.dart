import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/on_device_ai/data/on_device_models.dart';

/// The app's on-device AI models ([OnDeviceModels]) when they are
/// provided above [context]: only in the Android app on a phone that can
/// run on-device AI (not on the web, not on 32-bit phones). Null elsewhere.
OnDeviceModels? maybeOnDeviceModels(BuildContext context) {
  try {
    return context.read<OnDeviceModels>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// Whether a model of [models]' catalogue fits this phone: enough memory
/// for it ([OnDeviceFit.ok]), or just enough ([OnDeviceFit.slow]). An
/// empty catalogue, or a phone whose memory is unknown, fits nothing.
bool onDeviceAiModelFits(OnDeviceModels models) => models.catalog.models.any(
  (model) => switch (models.fitOf(model)) {
    OnDeviceFit.ok || OnDeviceFit.slow => true,
    OnDeviceFit.tooBig || OnDeviceFit.unknown => false,
  },
);

/// The ids of the models [models] uses: the selected translation and
/// assistant models (every installed model is selected by default); empty
/// while none is installed.
List<String> onDeviceAiModelsInUse(OnDeviceModels models) => [
  ?models.translationModel,
  ?models.assistantModel,
];

/// Whether [models] has an installed model ([onDeviceAiModelsInUse]).
bool onDeviceAiInstalled(OnDeviceModels models) =>
    onDeviceAiModelsInUse(models).isNotEmpty;

/// The display names of the models [models] uses ("Hy-MT2 1.8B, Qwen3
/// 1.7B"); empty while none is installed.
String onDeviceAiModelNames(OnDeviceModels models) => [
  for (final id in onDeviceAiModelsInUse(models))
    models.catalog.model(id)?.displayName ?? id,
].join(', ');

/// Opens the On-device AI settings above the current screen (back returns
/// to it).
void openOnDeviceAiSettings(BuildContext context) =>
    unawaited(GoRouter.of(context).push<void>(AppRoutes.onDeviceAi));
