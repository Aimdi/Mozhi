import 'dart:async';
import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:mozhi/offline/data/offline_model_import.dart';
import 'package:mozhi/settings/models/model_source.dart';
import 'package:translation_repository/translation_repository.dart';

/// The [OfflineModelDetails] of [translator] when it is a
/// [BergamotTranslator], otherwise null. In the web app (models in the
/// browser's storage, [OpfsModelManager]) they have no imports: a browser
/// has no model files to read.
OfflineModelDetails? offlineModelDetailsOf(OfflineTranslator translator) =>
    switch (translator) {
      BergamotTranslator(models: OpfsModelManager()) =>
        DownloadOnlyModelDetails(BergamotModelDetails(translator)),
      final BergamotTranslator bergamot => BergamotModelDetails(bergamot),
      _ => null,
    };

/// [details] without anything else they implement (such as
/// [OfflineModelImport]): sizes, storage and downloads only.
class DownloadOnlyModelDetails implements OfflineModelDetails {
  const new(this.details);

  final OfflineModelDetails details;

  @override
  int downloadSize(String code) => details.downloadSize(code);

  @override
  Future<OfflineStorage> storage(Iterable<String> codes) =>
      details.storage(codes);

  @override
  Future<void> download(
    String code, {
    required bool wifiOnly,
    void Function(double fraction)? onProgress,
  }) => details.download(code, wifiOnly: wifiOnly, onProgress: onProgress);
}

/// [OfflineModelDetails] of a [BergamotTranslator]: a language is its
/// models to and from English ([ModelRouter.modelsFor]). Imports go to
/// [BergamotModelManager.importFiles] with the translator's catalog.
/// Downloads come from the [ModelSource] in use when they start
/// (`modelSource`, default [ModelSource.current]: the settings').
class BergamotModelDetails implements OfflineModelDetails, OfflineModelImport {
  new(this.translator, {ModelSource Function()? modelSource})
    : _modelSource = modelSource ?? _currentSource;

  final BergamotTranslator translator;
  final ModelSource Function() _modelSource;

  static ModelSource _currentSource() => ModelSource.current;

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
    final source = _modelSource();
    translator.models
      ..mirror = source.mirror()
      ..fallbackToDefault = source.fallsBackToDefault;
    try {
      await translator.downloadLanguage(code, wifiOnly: wifiOnly);
    } finally {
      await subscription.cancel();
    }
  }

  @override
  Future<OfflineImportReport> importFiles(List<String> paths) async {
    final result = await translator.models.importFiles([
      for (final path in paths) File(path),
    ], catalog: translator.catalog);
    return OfflineImportReport(
      models: [
        for (final outcome in result.models)
          OfflineImportedModel(
            source: ModelRouter.reportedCode(outcome.model.source),
            target: ModelRouter.reportedCode(outcome.model.target),
            status: switch (outcome.status) {
              ModelImportStatus.installed => OfflineImportStatus.installed,
              ModelImportStatus.alreadyInstalled =>
                OfflineImportStatus.alreadyInstalled,
              ModelImportStatus.incomplete => OfflineImportStatus.incomplete,
              ModelImportStatus.checksumMismatch => OfflineImportStatus.damaged,
              ModelImportStatus.failed => OfflineImportStatus.failed,
            },
            missingFiles: [
              for (final file in outcome.missing) file.downloadName,
            ],
            error: switch (outcome.error) {
              final Object error => OfflineModelError.of(error),
              null => null,
            },
          ),
      ],
      unmatchedFiles: [
        for (final file in result.unmatched) file.uri.pathSegments.last,
      ],
    );
  }

  @override
  List<OfflineModelFile> manualFiles(String code) => [
    for (final model in translator.router.modelsFor(code))
      for (final file in model.files.values)
        OfflineModelFile(
          source: ModelRouter.reportedCode(model.source),
          target: ModelRouter.reportedCode(model.target),
          name: file.downloadName,
          url: '${file.url}',
          size: file.size,
        ),
  ];
}
