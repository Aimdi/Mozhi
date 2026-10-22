import 'dart:io';

import 'package:llama_engine/llama_engine.dart';
import 'package:mozhi/on_device_ai/data/on_device_models.dart';
import 'package:mozhi/pairing/data/pairing_packs.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';

/// The on-device AI models ([OnDeviceModels]) as pairing items: one per
/// installed model (the exact catalogue file), keyed by model id.
///
/// A phone takes a model its own catalogue lists with the same file (name,
/// size and SHA-256) and that its memory is enough for (not
/// [OnDeviceFit.tooBig]), and installs it with [OnDeviceModels.importFiles],
/// which checks it again; the received file is moved into place (it is a
/// temporary copy of a few GB). Receiving a model does not change which
/// one is in use.
class LlamaPairingPacks implements PairingPacks {
  new(this.models);

  final OnDeviceModels models;

  @override
  PairingItemKind get kind => PairingItemKind.onDeviceAi;

  PairingFile _fileOf(LlamaCatalogModel model) =>
      PairingFile(name: model.name, size: model.size, sha256: model.sha256);

  @override
  Future<List<PairingOutgoingItem>> outgoing() async {
    final items = <PairingOutgoingItem>[];
    for (final installed in await models.manager.installed()) {
      final listed = models.catalog.model(installed.id);
      if (listed == null || !installed.matches(listed)) continue;
      items.add(
        PairingOutgoingItem(
          PairingItem(kind: kind, key: listed.id, files: [_fileOf(listed)]),
          {listed.name: File(installed.path).openRead},
        ),
      );
    }
    return items;
  }

  @override
  Future<PairingPlan> plan(PairingItem item) async {
    final model = models.catalog.model(item.key);
    if (model == null || models.fitOf(model) == OnDeviceFit.tooBig) {
      return const PairingPlan.incompatible();
    }
    if (await models.pathOf(model.id) != null) {
      return const PairingPlan.installed();
    }
    final expected = _fileOf(model);
    return matchesOffer(item, expected)
        ? PairingPlan.available([expected])
        : const PairingPlan.incompatible();
  }

  @override
  Future<PairingItemOutcome> install(PairingItem item, List<File> files) async {
    final result = await models.importFiles(
      [for (final file in files) file.path],
      move: true,
      choose: false,
    );
    return switch (result.models[item.key]) {
      LlamaImportStatus.installed ||
      LlamaImportStatus.alreadyInstalled => PairingItemOutcome.installed,
      LlamaImportStatus.failed => pairingOutcomeOf(
        result.errors[item.key] ?? 'failed',
      ),
      LlamaImportStatus.checksumMismatch || null => PairingItemOutcome.damaged,
    };
  }
}
