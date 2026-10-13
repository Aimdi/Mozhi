/// Pure Dart clients for classic machine translation APIs that users can
/// connect directly with their own key or server:
///
/// * [DeeplClient] for the DeepL API v2 (Free and Pro),
/// * [LibreTranslateClient] for LibreTranslate servers,
///
/// plus helpers that convert the app's language codes to each service's
/// codes and back. Web safe (no `dart:io`).
library;

import 'package:mt_api/mt_api.dart';

export 'src/deepl/deepl_client.dart';
export 'src/deepl/deepl_language_codes.dart';
export 'src/deepl/deepl_models.dart';
export 'src/libre/libre_language_codes.dart';
export 'src/libre/libre_models.dart';
export 'src/libre/libre_translate_client.dart';
export 'src/mt_api_exception.dart';
