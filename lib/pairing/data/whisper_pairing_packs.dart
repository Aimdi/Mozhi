import 'dart:io';

import 'package:mozhi/pairing/data/pairing_packs.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';
import 'package:mozhi/voice/offline/offline_speech.dart';
import 'package:whisper_speech/whisper_speech.dart';

/// The offline speech models ([OfflineSpeech]) as pairing items: one per
/// installed Whisper model and the speech detector, keyed by model id.
///
/// A phone takes a model its own catalogue lists with the same file (name,
/// size, SHA-1 and SHA-256) and installs it with
/// [WhisperSpeech.importFiles], which checks it again. Receiving a model
/// does not change which one voice input uses.
class WhisperPairingPacks implements PairingPacks {
  new(this.speech);

  final OfflineSpeech speech;

  @override
  PairingItemKind get kind => PairingItemKind.speech;

  WhisperModelCatalog get _catalog => speech.whisper.catalog;

  List<WhisperCatalogModel> get _listed => [..._catalog.models, ?_catalog.vad];

  WhisperCatalogModel? _model(String id) {
    for (final model in _listed) {
      if (model.id == id) return model;
    }
    return null;
  }

  @override
  Future<List<PairingOutgoingItem>> outgoing() async {
    final items = <PairingOutgoingItem>[];
    for (final installed in await speech.whisper.models.installed()) {
      final listed = _model(installed.id);
      if (listed == null || !installed.matches(listed)) continue;
      items.add(
        PairingOutgoingItem(
          PairingItem(
            kind: kind,
            key: listed.id,
            files: [
              PairingFile(
                name: listed.name,
                size: listed.size,
                sha1: listed.sha1,
                sha256: listed.sha256,
              ),
            ],
          ),
          {listed.name: File(installed.path).openRead},
        ),
      );
    }
    return items;
  }

  @override
  Future<PairingPlan> plan(PairingItem item) async {
    final model = _model(item.key);
    if (!speech.isAvailable || model == null) {
      return const PairingPlan.incompatible();
    }
    final installed = await speech.whisper.models.installedModel(model.id);
    if (installed != null && installed.matches(model)) {
      return const PairingPlan.installed();
    }
    final expected = PairingFile(
      name: model.name,
      size: model.size,
      sha1: model.sha1,
      sha256: model.sha256,
    );
    return matchesOffer(item, expected)
        ? PairingPlan.available([expected])
        : const PairingPlan.incompatible();
  }

  @override
  Future<PairingItemOutcome> install(PairingItem item, List<File> files) async {
    final result = await speech.whisper.importFiles(files);
    for (final outcome in result.models) {
      if (outcome.model.id != item.key) continue;
      return switch (outcome.status) {
        WhisperImportStatus.installed ||
        WhisperImportStatus.alreadyInstalled => PairingItemOutcome.installed,
        WhisperImportStatus.checksumMismatch => PairingItemOutcome.damaged,
        WhisperImportStatus.failed => pairingOutcomeOf(
          outcome.error ?? 'failed',
        ),
      };
    }
    return PairingItemOutcome.damaged;
  }
}
