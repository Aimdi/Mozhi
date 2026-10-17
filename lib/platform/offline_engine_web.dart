import 'package:mozhi/offline/data/unavailable_offline_translator.dart';
import 'package:translation_repository/translation_repository.dart';

/// No on-device translation in a browser: an engine that is never
/// available (see `offline_engine_io.dart` for the app).
Future<OfflineTranslator> createOfflineTranslator() async =>
    const UnavailableOfflineTranslator();
