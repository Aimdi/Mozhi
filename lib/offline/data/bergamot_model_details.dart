import 'dart:async';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:translation_repository/translation_repository.dart';

/// The [OfflineModelDetails] of [translator] when it is a
/// [BergamotTranslator], otherwise null.
OfflineModelDetails? offlineModelDetailsOf(OfflineTranslator translator) =>
    translator is BergamotTranslator ? BergamotModelDetails(translator) : null;

/// [OfflineModelDetails] of a [BergamotTranslator]: a language is its
/// models to and from English ([ModelRouter.modelsFor]).
class BergamotModelDetails implements OfflineModelDetails {
  new(this.translator);

  final BergamotTranslator translator;

  @override
  int downloadSize(String code) => translator.downloadSize(code);

  @override
  Future<OfflineStorage> storage(Iterable<String> codes) async {
    final installed = {
      for (final model in await translator.models.installed())
        model.pair: model,
    };
    final outdated = {
      for (final model in await translator.outdatedModels()) model.pair,
    };
    final bytes = <String, int>{};
    final updates = <String>{};
    for (final code in codes) {
      var size = 0;
      for (final model in translator.router.modelsFor(code)) {
        size += installed[model.pair]?.sizeBytes ?? 0;
        if (outdated.contains(model.pair)) updates.add(code);
      }
      if (size > 0) bytes[code] = size;
    }
    return OfflineStorage(
      installedBytes: bytes,
      totalBytes: installed.values.fold(0, (sum, m) => sum + m.sizeBytes),
      outdated: updates,
    );
  }

  @override
  Future<void> download(
    String code, {
    required bool wifiOnly,
    void Function(double fraction)? onProgress,
  }) async {
    final missing = [
      for (final model in translator.router.modelsFor(code))
        if (!await translator.models.isInstalled(model)) model,
    ];
    final total = missing.fold(0, (sum, model) => sum + model.downloadSize);
    final pairs = {for (final model in missing) model.pair};
    final received = <String, int>{};
    final subscription = translator.downloadProgress.listen((progress) {
      if (total == 0 || !pairs.contains(progress.model.pair)) return;
      received[progress.model.pair] = progress.receivedBytes;
      final bytes = received.values.fold(0, (sum, value) => sum + value);
      onProgress?.call((bytes / total).clamp(0, 1).toDouble());
    });
    try {
      await translator.downloadLanguage(code, wifiOnly: wifiOnly);
    } finally {
      await subscription.cancel();
    }
  }
}
