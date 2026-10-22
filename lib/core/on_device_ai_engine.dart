import 'package:translation_repository/translation_repository.dart';

/// Prefix of the engine ids of on-device AI models: `ai:device-<modelId>`,
/// the AI providers the installed on-device models make (`OnDeviceAi`;
/// provider ids `device-<modelId>`, never stored in the settings).
const onDeviceAiEnginePrefix = 'ai:device-';

/// Whether [engineId] has the form of an on-device AI model's id
/// ([onDeviceAiEnginePrefix]). Only for telling apart what the repository
/// already placed on this device (`OnDeviceDestination`): an id alone
/// proves nothing (use [isOnDeviceAiEngine] for engines).
bool isOnDeviceAiEngineId(String? engineId) =>
    (engineId?.startsWith(onDeviceAiEnginePrefix) ?? false) &&
    engineId!.length > onDeviceAiEnginePrefix.length;

/// Whether [engine] is an AI model that runs inside the app, on this device
/// (llama.cpp; `TranslationEngine.onDevice`, set by the repository from
/// the provider): its text never leaves the device.
bool isOnDeviceAiEngine(TranslationEngine engine) =>
    engine.isAi && engine.isOnDevice;
