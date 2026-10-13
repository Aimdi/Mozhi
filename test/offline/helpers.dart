import 'package:mocktail/mocktail.dart';
import 'package:translation_repository/translation_repository.dart';

class MockOfflineTranslator extends Mock implements OfflineTranslator;

/// Supported languages of [stubOfflineTranslator], deliberately unsorted.
const testOfflineLanguages = {'fr', 'de', 'en', 'ja', 'xx'};

/// An available translator with [downloaded] models; downloads and
/// deletions succeed immediately.
MockOfflineTranslator stubOfflineTranslator({
  bool available = true,
  Set<String> downloaded = const {'en', 'de'},
}) {
  final translator = MockOfflineTranslator();
  when(() => translator.isAvailable).thenReturn(available);
  when(() => translator.supportedLanguages).thenReturn(testOfflineLanguages);
  when(translator.downloadedLanguages).thenAnswer((_) async => {...downloaded});
  when(
    () => translator.downloadLanguage(any(), wifiOnly: any(named: 'wifiOnly')),
  ).thenAnswer((_) async {});
  when(() => translator.deleteLanguage(any())).thenAnswer((_) async {});
  return translator;
}
