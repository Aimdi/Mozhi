import 'dart:async';
import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:mozhi/offline/data/offline_model_import.dart';
import 'package:mozhi/offline/data/picked_import_file.dart';
import 'package:mozhi/settings/models/model_source.dart';
import 'package:translation_repository/translation_repository.dart';

/// The [OfflineModelDetails] of [translator] when it is a
/// [BergamotTranslator], otherwise null. In the web app (models in the
/// browser's storage, [OpfsModelManager]) imports read the picked files by
/// their contents ([WebBergamotModelDetails]): a browser has no paths.
OfflineModelDetails? offlineModelDetailsOf(OfflineTranslator translator) =>
    switch (translator) {
      BergamotTranslator(:final OpfsModelManager models) =>
        WebBergamotModelDetails(translator, models),
      final BergamotTranslator bergamot => BergamotModelDetails(bergamot),
      _ => null,
    };

/// [OfflineModelDetails] of a [BergamotTranslator]: a language is its
/// models to and from English ([ModelRouter.modelsFor]). Imports go to
/// [BergamotModelManager.importFiles] with the translator's catalog.
/// Downloads come from the [ModelSource] in use when they start
/// (`modelSource`, default [ModelSource.current]: the settings').
class BergamotModelDetails
    implements
        OfflineModelDetails,
        OfflineModelImport,
        OfflineLanguageDirections {
  new(this.translator, {ModelSource Function()? modelSource})
    : _modelSource = modelSource ?? _currentSource;

  final BergamotTranslator translator;
  final ModelSource Function() _modelSource;

  static ModelSource _currentSource() => ModelSource.current;

  @override
  int downloadSize(String code) => translator.downloadSize(code);

  /// [BergamotTranslator.targetLanguages] and
  /// [BergamotTranslator.sourceLanguages] that are not
  /// [BergamotTranslator.supportedLanguages] (models in one direction
  /// only, e.g. English to Azerbaijani).
  @override
  Map<String, OfflineLanguageDirection> get oneWayLanguages {
    final both = translator.supportedLanguages;
    final into = translator.targetLanguages;
    final from = translator.sourceLanguages;
    return {
      for (final code in into)
        if (!both.contains(code) && !from.contains(code))
          code: OfflineLanguageDirection.intoOnly,
      for (final code in from)
        if (!both.contains(code) && !into.contains(code))
          code: OfflineLanguageDirection.fromOnly,
    };
  }

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
    return reportOf(result.models, [
      for (final file in result.unmatched) file.uri.pathSegments.last,
    ]);
  }

  /// The [OfflineImportReport] of an import that ended with [outcomes]
  /// and the names of the [unmatched] files.
  static OfflineImportReport reportOf(
    List<ModelImportOutcome> outcomes,
    List<String> unmatched,
  ) => OfflineImportReport(
    models: [
      for (final outcome in outcomes)
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
          missingFiles: [for (final file in outcome.missing) file.downloadName],
          error: switch (outcome.error) {
            final Object error => OfflineModelError.of(error),
            null => null,
          },
        ),
    ],
    unmatchedFiles: unmatched,
  );

  /// With a mirror as the model source, each file's [OfflineModelFile]
  /// also has its URL there ([bergamotMirrorUrl]), where the app's own
  /// downloads go.
  @override
  List<OfflineModelFile> manualFiles(String code) {
    final mirror = _modelSource().mirror();
    return [
      for (final model in translator.router.modelsFor(code))
        for (final file in model.files.values)
          OfflineModelFile(
            source: ModelRouter.reportedCode(model.source),
            target: ModelRouter.reportedCode(model.target),
            name: file.downloadName,
            url: '${file.url}',
            size: file.size,
            mirrorUrl: mirror == null
                ? null
                : '${bergamotMirrorUrl(mirror, model, file)}',
          ),
    ];
  }
}

/// [BergamotModelDetails] of the web app's translator (models in the
/// browser's private storage, [models]): imports read the picked files by
/// their contents ([OpfsModelManager.importSources]) with the same checks
/// as the Android app's; a browser has no paths for [importFiles].
class WebBergamotModelDetails extends BergamotModelDetails
    implements OfflineModelContentsImport {
  new(super.translator, this.models, {super.modelSource});

  /// The translator's model manager.
  final OpfsModelManager models;

  @override
  Future<OfflineImportReport> importFiles(List<String> paths) =>
      Future.error(UnsupportedError('A browser has no file paths'));

  @override
  Future<OfflineImportReport> importContents(
    List<PickedImportFile> files,
  ) async {
    final result = await models.importSources(
      files,
      catalog: translator.catalog,
    );
    return BergamotModelDetails.reportOf(result.models, [
      for (final file in result.unmatched) file.name,
    ]);
  }
}
