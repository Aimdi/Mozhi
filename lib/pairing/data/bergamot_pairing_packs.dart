import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:mozhi/pairing/data/pairing_packs.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';

/// The on-device translation models ([BergamotTranslator]) as pairing
/// items: one per downloaded language (both directions), its files named
/// `<pair>/<file>` as installed (decompressed).
///
/// A phone takes a language when its own catalogue lists the same files
/// (name, size and SHA-256 of the decompressed file) for the models it
/// does not have yet, and installs them with
/// [BergamotModelManager.importFiles], which checks them again.
class BergamotPairingPacks implements PairingPacks {
  new(this.translator);

  final BergamotTranslator translator;

  @override
  PairingItemKind get kind => PairingItemKind.translation;

  @override
  Future<List<PairingOutgoingItem>> outgoing() async {
    if (!translator.isAvailable) return const [];
    final installed = {
      for (final model in await translator.models.installed())
        model.pair: model,
    };
    final codes = (await translator.downloadedLanguages()).toList()..sort();
    final offered = <String>{};
    final items = <PairingOutgoingItem>[];
    for (final code in codes) {
      final models = translator.router.modelsFor(code);
      // English needs no models; languages that share all their models
      // (Croatian, Bosnian and Serbian) are offered once.
      final pairs = ([for (final model in models) model.pair]..sort()).join();
      if (models.isEmpty ||
          models.any((model) => !installed.containsKey(model.pair)) ||
          !offered.add(pairs)) {
        continue;
      }
      final files = <PairingFile>[];
      final readers = <String, PairingFileReader>{};
      for (final model in models) {
        final local = installed[model.pair]!;
        final listed = translator.catalog.model(local.source, local.target);
        for (final MapEntry(key: fileKind, value: path)
            in local.files.entries) {
          final file = File(path);
          final size = await file.length();
          final known = listed?.version == local.version
              ? listed!.files[fileKind]
              : null;
          final name = '${local.pair}/${file.uri.pathSegments.last}';
          files.add(
            PairingFile(
              name: name,
              size: size,
              sha256: known != null && known.uncompressedSize == size
                  ? known.uncompressedSha256
                  : null,
            ),
          );
          readers[name] = file.openRead;
        }
      }
      items.add(
        PairingOutgoingItem(
          PairingItem(kind: kind, key: code, files: files),
          readers,
          language: code,
        ),
      );
    }
    return items;
  }

  @override
  Future<PairingPlan> plan(PairingItem item) async {
    final models = translator.router.modelsFor(item.key);
    if (!translator.isAvailable || models.isEmpty) {
      return const PairingPlan.incompatible();
    }
    final needed = <PairingFile>[];
    for (final model in models) {
      if (await translator.models.isInstalled(model)) continue;
      for (final file in model.files.values) {
        final expected = PairingFile(
          name: '${model.pair}/${file.name}',
          size: file.uncompressedSize,
          sha256: file.uncompressedSha256,
        );
        if (!matchesOffer(item, expected)) {
          return const PairingPlan.incompatible();
        }
        needed.add(expected);
      }
    }
    return needed.isEmpty
        ? PairingPlan.installed(language: item.key)
        : PairingPlan.available(needed, language: item.key);
  }

  @override
  Future<PairingItemOutcome> install(PairingItem item, List<File> files) async {
    final result = await translator.models.importFiles(
      files,
      catalog: translator.catalog,
    );
    for (final outcome in result.models) {
      switch (outcome.status) {
        case ModelImportStatus.installed || ModelImportStatus.alreadyInstalled:
          continue;
        case ModelImportStatus.failed:
          return pairingOutcomeOf(outcome.error ?? 'failed');
        case ModelImportStatus.incomplete || ModelImportStatus.checksumMismatch:
          return PairingItemOutcome.damaged;
      }
    }
    for (final model in translator.router.modelsFor(item.key)) {
      if (!await translator.models.isInstalled(model)) {
        return PairingItemOutcome.damaged;
      }
    }
    return PairingItemOutcome.installed;
  }
}
