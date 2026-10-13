import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlkit_translator/mlkit_translator.dart';
import 'package:translation_repository/translation_repository.dart';

/// Channel names and methods from the plugin sources
/// (google_mlkit_translation 0.15.1, google_mlkit_language_id 0.15.1).
const _translatorChannel = MethodChannel('google_mlkit_on_device_translator');
const _identifierChannel = MethodChannel('google_mlkit_language_identifier');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  late Set<String> downloaded;
  late String identified;

  Future<Object?> translatorHandler(MethodCall call) async {
    calls.add(call);
    final args = call.arguments as Map<Object?, Object?>;
    switch (call.method) {
      case 'nlp#manageLanguageModelModels':
        final model = args['model']! as String;
        switch (args['task']) {
          case 'check':
            return downloaded.contains(model);
          case 'download':
            downloaded.add(model);
            return 'success';
          case 'delete':
            downloaded.remove(model);
            return 'success';
        }
        return null;
      case 'nlp#startLanguageTranslator':
        return '${args['source']}>${args['target']}: ${args['text']}';
      case 'nlp#closeLanguageTranslator':
        return null;
    }
    throw MissingPluginException(call.method);
  }

  Future<Object?> identifierHandler(MethodCall call) async {
    calls.add(call);
    if (call.method == 'nlp#startLanguageIdentifier') return identified;
    return null;
  }

  setUp(() {
    calls = [];
    downloaded = {'en'};
    identified = 'und';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          ..setMockMethodCallHandler(_translatorChannel, translatorHandler)
          ..setMockMethodCallHandler(_identifierChannel, identifierHandler);
    addTearDown(() {
      messenger
        ..setMockMethodCallHandler(_translatorChannel, null)
        ..setMockMethodCallHandler(_identifierChannel, null);
    });
  });

  group('GoogleMlKitBindings', () {
    late GoogleMlKitBindings bindings;

    setUp(() => bindings = GoogleMlKitBindings());

    test('checks, downloads and deletes models', () async {
      expect(await bindings.isModelDownloaded('de'), isFalse);
      expect(await bindings.downloadModel('de', wifiRequired: true), isTrue);
      expect(await bindings.isModelDownloaded('de'), isTrue);
      expect(await bindings.deleteModel('de'), isTrue);

      expect(calls.map((c) => c.method).toSet(), {
        'nlp#manageLanguageModelModels',
      });
      expect(calls.map((c) => c.arguments), [
        {'task': 'check', 'model': 'de'},
        {'task': 'download', 'model': 'de', 'wifi': true},
        {'task': 'check', 'model': 'de'},
        {'task': 'delete', 'model': 'de'},
      ]);
    });

    test('passes wifiRequired: false', () async {
      await bindings.downloadModel('fr', wifiRequired: false);
      expect(calls.single.arguments, {
        'task': 'download',
        'model': 'fr',
        'wifi': false,
      });
    });

    test('translates and closes', () async {
      final translator = bindings.createTranslator(source: 'en', target: 'de');
      expect(await translator.translate('Hi'), 'en>de: Hi');
      await translator.close();

      expect(calls.map((c) => c.method), [
        'nlp#startLanguageTranslator',
        'nlp#closeLanguageTranslator',
      ]);
      final start = calls.first.arguments as Map<Object?, Object?>;
      final close = calls.last.arguments as Map<Object?, Object?>;
      expect(start, containsPair('source', 'en'));
      expect(start, containsPair('target', 'de'));
      expect(close['id'], start['id']);
    });

    test('rejects codes that are not ML Kit languages', () {
      expect(
        () => bindings.createTranslator(source: 'zh-CN', target: 'en'),
        throwsArgumentError,
      );
      expect(calls, isEmpty);
    });

    test('identifies languages and closes', () async {
      identified = 'fr';
      final identifier = bindings.createLanguageIdentifier(
        confidenceThreshold: 0.7,
      );
      expect(await identifier.identify('Bonjour'), 'fr');
      await identifier.close();

      expect(calls.map((c) => c.method), [
        'nlp#startLanguageIdentifier',
        'nlp#closeLanguageIdentifier',
      ]);
      expect(
        calls.first.arguments,
        allOf(
          containsPair('text', 'Bonjour'),
          containsPair('confidence', 0.7),
          containsPair('possibleLanguages', false),
        ),
      );
    });
  });

  group('MlKitOfflineTranslator with the plugin channels', () {
    late MlKitOfflineTranslator translator;

    setUp(() => translator = MlKitOfflineTranslator(isAvailable: true));

    test('never starts a translation with a missing model', () async {
      await expectLater(
        translator.translate('Hallo', source: 'de', target: 'en'),
        throwsA(isA<OfflineModelMissingException>()),
      );
      expect(
        calls.where((c) => c.method == 'nlp#startLanguageTranslator'),
        isEmpty,
      );
      expect(calls.map((c) => (c.arguments as Map)['task']).toSet(), {'check'});
    });

    test('downloads, translates, identifies and disposes', () async {
      await translator.downloadLanguage('de-DE');
      expect(await translator.downloadedLanguages(), {'en', 'de'});
      expect(
        await translator.translate('Hello', source: 'en', target: 'de'),
        'en>de: Hello',
      );
      identified = 'iw';
      expect(await translator.identifyLanguage('שלום'), 'he');
      await translator.dispose();
      expect(
        calls.map((c) => c.method),
        containsAll(<String>[
          'nlp#closeLanguageTranslator',
          'nlp#closeLanguageIdentifier',
        ]),
      );
      await translator.deleteLanguage('de');
      expect(downloaded, {'en'});
    });
  });
}
