import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/pairing/data/whisper_pairing_packs.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:whisper_speech/whisper_speech.dart';

import '../helpers/fake_packs.dart';

class _MockEngine extends Mock implements WhisperEngine;

class _MockVadEngine extends Mock implements WhisperVadEngine;

void main() {
  late Directory temp;
  late Uint8List tiny;
  late Uint8List vad;
  late MemoryStore store;
  final speeches = <OfflineSpeech>[];

  WhisperCatalogModel model(String id, Uint8List bytes, {bool sha256 = true}) =>
      WhisperCatalogModel(
        id: id,
        name: 'ggml-$id.bin',
        url: Uri.parse('https://models.example/ggml-$id.bin'),
        size: bytes.length,
        sha1: sha1Of(bytes),
        sha256: sha256 ? sha256Of(bytes) : null,
      );

  OfflineSpeech speech(
    String folder, {
    bool available = true,
    Uint8List? tinyBytes,
  }) {
    final engine = _MockEngine();
    when(() => engine.release(any())).thenAnswer((_) async {});
    when(engine.dispose).thenAnswer((_) async {});
    final detector = _MockVadEngine();
    when(() => detector.release(any())).thenAnswer((_) async {});
    when(detector.dispose).thenAnswer((_) async {});
    final result = OfflineSpeech(
      whisper: WhisperSpeech(
        catalog: WhisperModelCatalog(
          models: [model('tiny', tinyBytes ?? tiny)],
          vad: model('silero', vad, sha256: false),
        ),
        root: Directory('${temp.path}/$folder'),
        httpClient: MockClient(
          (request) async => http.Response.bytes(
            request.url.path.contains('tiny') ? tiny : vad,
            200,
          ),
        ),
        engine: engine,
        vadEngine: detector,
        isAvailable: available,
      ),
      store: store,
    );
    speeches.add(result);
    return result;
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('mozhi_pairing_whisper_');
    tiny = bytesOf(300, 7);
    vad = bytesOf(100, 13);
    store = MemoryStore();
  });

  tearDown(() async {
    for (final speech in speeches) {
      await speech.dispose();
    }
    speeches.clear();
    temp.deleteSync(recursive: true);
  });

  Future<List<File>> copy(PairingItem item, List<int> bytes) async => [
    File('${temp.path}/in/${item.files.single.name}')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes),
  ];

  group('WhisperPairingPacks', () {
    test('offers the installed models and the speech detector', () async {
      final sender = speech('sender');
      await sender.download('tiny');
      final packs = WhisperPairingPacks(sender);
      expect(packs.kind, PairingItemKind.speech);
      final outgoing = await packs.outgoing();
      expect([for (final o in outgoing) o.item.key], ['silero', 'tiny']);
      final file = outgoing.last.item.files.single;
      expect(file.name, 'ggml-tiny.bin');
      expect(file.size, 300);
      expect(file.sha1, sha1Of(tiny));
      expect(file.sha256, sha256Of(tiny));
      expect(
        await outgoing.last.readers['ggml-tiny.bin']!()
            .expand((c) => c)
            .toList(),
        tiny,
      );
    });

    test('leaves out files the catalogue does not list', () async {
      final sender = speech('sender');
      await sender.download('tiny');
      // The same folder with another catalogue: the installed file no
      // longer matches.
      final other = speech('sender', tinyBytes: bytesOf(300, 9));
      expect(
        [
          for (final o in await WhisperPairingPacks(other).outgoing())
            o.item.key,
        ],
        ['silero'],
      );
    });

    test('a phone without the model takes and installs it', () async {
      final sender = speech('sender');
      await sender.download('tiny');
      final item = (await WhisperPairingPacks(sender).outgoing()).last.item;
      final receiver = speech('receiver');
      final packs = WhisperPairingPacks(receiver);
      final plan = await packs.plan(item);
      expect(plan.status, PairingItemStatus.available);
      expect(
        await packs.install(item, await copy(item, tiny)),
        PairingItemOutcome.installed,
      );
      expect(await receiver.installed(), {'tiny'});
      expect(await packs.plan(item), const PairingPlan.installed());
    });

    test('a damaged or unknown file installs nothing', () async {
      final sender = speech('sender');
      await sender.download('tiny');
      final item = (await WhisperPairingPacks(sender).outgoing()).last.item;
      final packs = WhisperPairingPacks(speech('receiver'));
      expect(
        await packs.install(item, await copy(item, bytesOf(300, 5))),
        PairingItemOutcome.damaged,
      );
      expect(
        await packs.install(item, await copy(item, bytesOf(12, 5))),
        PairingItemOutcome.damaged,
      );
    });

    test('takes nothing it does not know or cannot run', () async {
      const item = PairingItem(
        kind: PairingItemKind.speech,
        key: 'large',
        files: [PairingFile(name: 'ggml-large.bin', size: 1)],
      );
      expect(
        await WhisperPairingPacks(speech('receiver')).plan(item),
        const PairingPlan.incompatible(),
      );
      final tinyItem = PairingItem(
        kind: PairingItemKind.speech,
        key: 'tiny',
        files: [
          PairingFile(name: 'ggml-tiny.bin', size: 300, sha1: sha1Of(tiny)),
        ],
      );
      expect(
        await WhisperPairingPacks(speech('off', available: false))
            .plan(tinyItem),
        const PairingPlan.incompatible(),
      );
      const otherFile = PairingItem(
        kind: PairingItemKind.speech,
        key: 'tiny',
        files: [PairingFile(name: 'ggml-tiny.bin', size: 299)],
      );
      expect(
        await WhisperPairingPacks(speech('receiver')).plan(otherFile),
        const PairingPlan.incompatible(),
      );
    });
  });
}
