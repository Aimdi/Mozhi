import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:mozhi/on_device_ai/data/on_device_ai.dart';
import 'package:translation_repository/translation_repository.dart';

import 'fake_on_device_models.dart';

export 'fake_on_device_models.dart';

/// [OnDeviceAi] over [models], with [providers] and a [status] to drive.
class FakeOnDeviceAi extends Fake implements OnDeviceAi {
  new(this.models);

  @override
  final FakeOnDeviceModels models;

  @override
  List<AiProviderConfig> providers = const [];

  final providersController =
      StreamController<List<AiProviderConfig>>.broadcast();

  @override
  Stream<List<AiProviderConfig>> get providersChanges =>
      providersController.stream;

  @override
  OnDeviceAiStatus currentStatus = const OnDeviceAiIdle();

  final statusController = StreamController<OnDeviceAiStatus>.broadcast();

  @override
  Stream<OnDeviceAiStatus> get status => statusController.stream;

  /// Times [continueAnyway] was called.
  int continued = 0;

  @override
  void continueAnyway() => continued++;

  /// Emits [next] as the status.
  void report(OnDeviceAiStatus next) {
    currentStatus = next;
    statusController.add(next);
  }

  /// Installs [model]: its provider appears.
  void install(LlamaCatalogModel model) {
    providers = [...providers, OnDeviceAi.providerFor(model)];
    if (model.role == LlamaModelRole.translation) {
      models.translationModel = model.id;
    } else {
      models.assistantModel = model.id;
    }
    providersController.add(providers);
    models.controller.add(null);
  }

  Future<void> close() async {
    await providersController.close();
    await statusController.close();
    await models.controller.close();
  }
}
