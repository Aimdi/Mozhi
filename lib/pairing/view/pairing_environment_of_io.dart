import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/on_device_ai/data/on_device_models.dart';
import 'package:mozhi/pairing/data/bergamot_pairing_packs.dart';
import 'package:mozhi/pairing/data/dictionary_pairing_packs.dart';
import 'package:mozhi/pairing/data/llama_pairing_packs.dart';
import 'package:mozhi/pairing/data/pairing_environment.dart';
import 'package:mozhi/pairing/data/pairing_packs.dart';
import 'package:mozhi/pairing/data/tesseract_pairing_packs.dart';
import 'package:mozhi/pairing/data/whisper_pairing_packs.dart';
import 'package:mozhi/platform/mlkit_bindings.dart';
import 'package:mozhi/platform/text_recognition_io.dart'
    show textRecognitionFolder;
import 'package:mozhi/transcribe/data/screen_awake.dart';
import 'package:mozhi/voice/offline/offline_speech.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart';
import 'package:translation_repository/translation_repository.dart';

/// The app's pairing dependencies, from what the widget tree provides: the
/// backup sections ([BackupRegistry]), the offline translation models
/// (when the [OfflineTranslator] is Bergamot's), the speech models
/// ([OfflineSpeech]), the on-device AI models ([OnDeviceModels]), the text
/// recognition data of the build's recognizer and the offline dictionaries
/// ([DictionaryPacks]). Whatever is missing is neither offered nor taken.
/// Transfers use the app's cache folder and keep the screen on
/// ([ScreenAwake]).
PairingEnvironment pairingEnvironmentOf(BuildContext context) {
  T? read<T>() {
    try {
      return context.read<T>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  final translator = read<OfflineTranslator>();
  final speech = read<OfflineSpeech>();
  final onDeviceModels = read<OnDeviceModels>();
  final dictionaries = read<DictionaryPacks>();
  final ocr = textRecognitionLanguageDataOf(createTextRecognitionService());
  final screen = ScreenAwake();
  return PairingEnvironment(
    library: PairingLibrary(
      backup: read<BackupRegistry>(),
      packs: [
        if (translator case final BergamotTranslator bergamot)
          BergamotPairingPacks(bergamot),
        if (speech != null) WhisperPairingPacks(speech),
        if (onDeviceModels != null) LlamaPairingPacks(onDeviceModels),
        if (ocr != null && ocr.isSupported)
          TesseractPairingPacks(
            data: ocr,
            catalog: loadBundledTessdataCatalog,
            dataDirectory: _tessdata,
          ),
        if (dictionaries != null) DictionaryPairingPacks(dictionaries),
      ],
    ),
    temporaryDirectory: getTemporaryDirectory,
    keepScreenOn: screen.setEnabled,
  );
}

/// Deletes what transfers left in the app's cache folder ("Delete all
/// local data"); pairing stores nothing else.
Future<void> deletePairingFiles() async {
  try {
    await PairingEnvironment.deleteFiles(getTemporaryDirectory);
  } on Object {
    // No cache folder (tests, desktop): nothing to delete.
  }
}

// coverage:ignore-start
// A platform call: only in the app.
/// The folder Tesseract reads (`<support>/tesseract/tessdata`, see
/// `TessdataManager.dataDirectory`).
Future<Directory> _tessdata() async => Directory(
  '${(await getApplicationSupportDirectory()).path}/'
  '$textRecognitionFolder/tessdata',
);
// coverage:ignore-end
