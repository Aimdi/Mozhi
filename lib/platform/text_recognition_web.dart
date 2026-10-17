import 'package:mozhi/image_translate/data/text_recognition_service.dart';

/// No on-device text recognition in a browser (see
/// `text_recognition_io.dart` for the app).
TextRecognitionService defaultTextRecognitionService() =>
    const UnavailableTextRecognitionService();

/// Nothing is stored in a browser.
Future<void> deleteTextRecognitionFiles() async {}
