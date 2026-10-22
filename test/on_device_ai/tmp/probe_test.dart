import 'package:flutter_test/flutter_test.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:mozhi/on_device_ai/data/on_device_ai.dart';
import 'package:path/path.dart' as p;
import 'package:translation_repository/translation_repository.dart';

import '../data/helpers.dart';

void main() {
  final pkg = p.absolute('packages', 'llama_engine');
  final lib = p.join(pkg, 'build', 'native', 'linux', 'libmozhi_llama.so');
  String model(String t) => p.join(pkg, 'build', 'test_models', 'llama-test-$t.gguf');
  test('probe', () async {
    final ai = OnDeviceAi(
      models: FakeOnDeviceModels(
        catalog: LlamaModelCatalog(models: [catalogModel('hy-test', role: LlamaModelRole.translation, family: 'hunyuan-dense', contextSize: 2048)]),
        paths: {'hy-test': model('hunyuan-dense')},
        translationModel: 'hy-test',
      ),
      engine: createLlamaEngine(libraryPath: lib),
    );
    ai.status.listen((s) => print('status $s'));
    final repository = TranslationRepository(
      llmClientFactory: onDeviceClientFactory(ai, (_) => throw StateError('x')),
      snapshotInterval: Duration.zero,
    )..updateConfiguration(instances: const [], providers: ai.providers)..updatePrivacy(mode: PrivacyMode.offlineOnly);
    final engine = (await repository.getEngines()).first;
    final sw = Stopwatch()..start();
    var n = 0;
    try {
      await for (final r in repository.translate(engine, const TranslationRequest(text: 'Hello', source: Language(code: 'en', name: 'English'), target: Language(code: 'de', name: 'German')))) {
        n++;
        if (n % 200 == 0 || r.isComplete) print('${sw.elapsedMilliseconds}ms #$n ${r.text.length} ${r.isComplete}');
      }
    } on Object catch (e) {
      print('${sw.elapsedMilliseconds}ms error $e after $n');
    }
    repository.dispose();
    await ai.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));
}
