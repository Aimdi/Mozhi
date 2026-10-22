import 'package:flutter_test/flutter_test.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:path/path.dart' as p;

void main() {
  final pkg = p.absolute('packages', 'llama_engine');
  final lib = p.join(pkg, 'build', 'native', 'linux', 'libmozhi_llama.so');
  String model(String t) => p.join(pkg, 'build', 'test_models', 'llama-test-$t.gguf');
  test('probe', () async {
    final engine = createLlamaEngine(libraryPath: lib);
    for (final t in ['hunyuan-dense']) {
      await engine.load(model(t), contextSize: 2048);
      for (final (name, sampling, json) in [
        ('default', const LlamaSampling(), false),

      ]) {
        final sw = Stopwatch()..start();
        LlamaGenerateStats? stats;
        final out = await engine.generate(LlamaGenerateRequest(
          messages: const [LlamaChatMessage(LlamaRole.user, 'Translate the following text into German. Note that you should only output the translated result without any additional explanation:\n\nHello')],
          sampling: sampling, maxTokens: 1990, jsonOutput: json,
          onFinish: (s) => stats = s,
        )).join();
        // ignore: avoid_print
        print('$t $name ${sw.elapsedMilliseconds}ms ${stats} ${out.length} ${out.substring(0, out.length.clamp(0, 40))}');
      }
    }
    await engine.dispose();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
