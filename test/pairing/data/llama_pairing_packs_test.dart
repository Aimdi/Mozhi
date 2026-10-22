import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/on_device_ai/data/on_device_models.dart';
import 'package:mozhi/pairing/data/llama_pairing_packs.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';
import 'package:mozhi/platform/native_memory.dart';
import 'package:mozhi/settings/models/model_source.dart';

import '../../on_device_ai/helpers.dart';
import '../helpers/fake_packs.dart';

void main() {
  late Directory temp;
  late Uint8List hyBytes;
  late Uint8List qwenBytes;
  final created = <OnDeviceModels>[];

  setUp(() {
    temp = Directory.systemTemp.createTempSync('mozhi_pairing_llama_');
    hyBytes = ggufBytes(300, seed: 7);
    qwenBytes = ggufBytes(200, seed: 9);
  });

  tearDown(() async {
    for (final models in created) {
      await models.dispose();
    }
    created.clear();
    temp.deleteSync(recursive: true);
  });

  OnDeviceModels models(
    String folder, {
    Uint8List? hy,
    int ramMb = 12000,
    MemoryStore? store,
  }) {
    final hyModel = fakeOnDeviceModel(
      'hy',
      hy ?? hyBytes,
      role: LlamaModelRole.translation,
    );
    final qwenModel = fakeOnDeviceModel('qwen', qwenBytes, minRamMb: 8000);
    final result = OnDeviceModels(
      catalog: LlamaModelCatalog(models: [hyModel, qwenModel]),
      manager: LlamaModelManager(
        root: Directory('${temp.path}/$folder'),
        httpClient: modelServer({
          'hy.gguf': hy ?? hyBytes,
          'qwen.gguf': qwenBytes,
        }),
      ),
      store: store ?? MemoryStore(),
      memory: DeviceMemory(totalBytes: ramMb * 1024 * 1024),
      modelSource: () => ModelSource.defaultHosts,
    );
    created.add(result);
    return result;
  }

  Future<List<File>> copy(PairingItem item, List<int> bytes) async => [
    File('${temp.path}/in/${item.files.single.name}')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes),
  ];

  group(LlamaPairingPacks, () {
    test('offers the installed models', () async {
      final sender = models('sender');
      await sender.download('hy');
      final packs = LlamaPairingPacks(sender);
      expect(packs.kind, PairingItemKind.onDeviceAi);
      final outgoing = await packs.outgoing();
      expect([for (final o in outgoing) o.item.key], ['hy']);
      final file = outgoing.single.item.files.single;
      expect(file.name, 'hy.gguf');
      expect(file.size, 300);
      expect(file.sha256, sha256Of(hyBytes));
      expect(
        await outgoing.single.readers['hy.gguf']!().expand((c) => c).toList(),
        hyBytes,
      );
    });

    test('leaves out files the catalogue does not list', () async {
      final sender = models('sender');
      await sender.download('hy');
      final other = models('sender', hy: ggufBytes(300, seed: 11));
      expect(await LlamaPairingPacks(other).outgoing(), isEmpty);
    });

    test('a phone takes a model it lists with the same file', () async {
      final sender = models('sender');
      await sender.download('hy');
      final item = (await LlamaPairingPacks(sender).outgoing()).single.item;

      final store = MemoryStore();
      final receiver = models('receiver', store: store);
      await receiver.download('qwen');
      final packs = LlamaPairingPacks(receiver);
      final plan = await packs.plan(item);
      expect(plan.status, PairingItemStatus.available);
      expect(plan.files.single.sha256, sha256Of(hyBytes));

      final files = await copy(item, hyBytes);
      expect(await packs.install(item, files), PairingItemOutcome.installed);
      expect(files.single.existsSync(), isFalse, reason: 'moved into place');
      expect(await receiver.pathOf('hy'), isNotNull);
      expect((await packs.plan(item)).status, PairingItemStatus.installed);
      // Receiving does not change the chosen models.
      expect(store.values, {OnDeviceModels.assistantModelKey: 'qwen'});
    });

    test('refuses unknown models, other files and models too big', () async {
      final receiver = models('receiver', ramMb: 6000);
      final packs = LlamaPairingPacks(receiver);
      PairingItem item(String key, String name, int size, String sha) =>
          PairingItem(
            kind: PairingItemKind.onDeviceAi,
            key: key,
            files: [PairingFile(name: name, size: size, sha256: sha)],
          );
      expect(
        (await packs.plan(item('x', 'x.gguf', 1, 'a' * 64))).status,
        PairingItemStatus.incompatible,
      );
      expect(
        (await packs.plan(item('hy', 'hy.gguf', 300, 'a' * 64))).status,
        PairingItemStatus.incompatible,
      );
      expect(
        (await packs.plan(item('qwen', 'qwen.gguf', 200, sha256Of(qwenBytes))))
            .status,
        PairingItemStatus.incompatible,
        reason: 'qwen needs 8000 MB',
      );
    });

    test('reports a damaged file and a failed install', () async {
      final receiver = models('receiver');
      final packs = LlamaPairingPacks(receiver);
      final item = PairingItem(
        kind: PairingItemKind.onDeviceAi,
        key: 'hy',
        files: [
          PairingFile(name: 'hy.gguf', size: 300, sha256: sha256Of(hyBytes)),
        ],
      );
      final damaged = Uint8List.fromList(hyBytes)..[0] ^= 1;
      expect(
        await packs.install(item, await copy(item, damaged)),
        PairingItemOutcome.damaged,
      );
      // A file where the models folder should be: installing fails.
      receiver.manager.modelsDirectory.deleteSync(recursive: true);
      File('${temp.path}/receiver/models')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('in the way');
      expect(
        await packs.install(item, await copy(item, hyBytes)),
        PairingItemOutcome.failed,
      );
      expect(await packs.install(item, const []), PairingItemOutcome.damaged);
    });
  });
}
