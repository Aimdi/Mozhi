// The CPU variant guard of IsolateLlamaEngine with a fake native layer in
// the real background isolate.
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:llama_engine/src/engine/cpu_variant_guard.dart';
import 'package:llama_engine/src/engine/ffi/bindings.dart';
import 'package:llama_engine/src/engine/ffi/isolate_engine.dart';
import 'package:llama_engine/src/engine/ffi/native_engine.dart';
import 'package:path/path.dart' as p;

import '../../helpers/fake_llama_native.dart';

const String _i8mm = LlamaBindings.i8mmLibraryName;
const String _baseline = LlamaBindings.libraryName;

/// [FakeLlamaNative] that says it opened [library].
final class _NamedNative implements LlamaNative {
  new(this.library, this._inner);

  @override
  final String library;

  final FakeLlamaNative _inner;

  @override
  String get engine => 'fake engine 1';

  @override
  String? get loadedModelPath => _inner.loadedModelPath;

  @override
  LlamaModelInfo load(
    String path, {
    required int contextSize,
    required int threads,
  }) => _inner.load(path, contextSize: contextSize, threads: threads);

  @override
  void unload() => _inner.unload();

  @override
  int countTokens(List<LlamaChatMessage> messages) =>
      _inner.countTokens(messages);

  @override
  void begin(LlamaGenerateRequest request, {int cancelFlag = 0}) =>
      _inner.begin(request, cancelFlag: cancelFlag);

  @override
  String? next() => _inner.next();

  @override
  LlamaGenerateStats stats() => _inner.stats();

  @override
  void end() => _inner.end();

  @override
  void dispose() => _inner.dispose();
}

const hello = LlamaGenerateRequest(
  messages: [LlamaChatMessage(LlamaRole.user, 'hello')],
);

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('llama_iso_guard_'));
  tearDown(() => root.deleteSync(recursive: true));

  CpuVariantGuard guard(int processId) => CpuVariantGuard(
    directory: root.path,
    variants: const {_i8mm, LlamaBindings.dotprodLibraryName},
    processId: processId,
  );

  IsolateLlamaEngine engine(
    int processId, [
    FakeScript script = const FakeScript(pieces: ['ok']),
  ]) => IsolateLlamaEngine(
    libraries: const [_i8mm, _baseline],
    opener: (libraries) =>
        _NamedNative(libraries.first, FakeLlamaNative(script)),
    variantGuard: guard(processId),
  );

  List<String> markers() => [
    for (final entry in root.listSync())
      if (entry.path.endsWith('.marker')) p.basename(entry.path),
  ];

  test('verifies a variant with its first generation', () async {
    final first = engine(1);
    await first.load('a.gguf');
    // Opened: no marker; not verified before it computed.
    expect(markers(), isEmpty);
    expect(guard(1).needsCheck(_i8mm, version: 'fake engine 1'), isTrue);

    expect(await first.generate(hello).toList(), ['ok']);
    expect(markers(), isEmpty);
    expect(guard(1).read().verified, {_i8mm: 'fake engine 1'});
    // A later generation needs no marker.
    expect(await first.generate(hello).toList(), ['ok']);
    await first.dispose();

    // The next start uses it again.
    final next = engine(2);
    await next.load('a.gguf');
    expect(await next.generate(hello).toList(), ['ok']);
    expect(guard(2).read().skipped, isEmpty);
    await next.dispose();
  });

  test('a variant that dies while computing is skipped next time', () async {
    final crashing = engine(1, const FakeScript(dieOnNext: true));
    await crashing.load('a.gguf');
    await expectLater(
      crashing.generate(hello),
      emitsError(isA<LlamaEngineException>()),
    );
    // The process "died": its marker stays.
    expect(markers(), ['llama_cpu_variant.compute.marker']);
    await crashing.dispose();

    final next = engine(2);
    final info = await next.load('a.gguf');
    expect(info.name, 'a.gguf');
    expect(guard(2).read().skipped, {_i8mm});
    expect(markers(), isEmpty);
    expect(await next.generate(hello).toList(), ['ok']);
    // The baseline is never guarded.
    expect(guard(2).read().verified, isEmpty);
    await next.dispose();
  });

  test('a marker left while opening skips the variant', () async {
    File(p.join(root.path, 'llama_cpu_variant.open.marker'))
        .writeAsStringSync(jsonEncode({'library': _i8mm, 'pid': 1}));
    final next = engine(2);
    await next.load('a.gguf');
    expect(guard(2).read().skipped, {_i8mm});
    await next.dispose();
  });

  test('an engine error is no crash: not verified, no marker', () async {
    final failing = engine(
      1,
      const FakeScript(beginError: LlamaEngineException('begin')),
    );
    await failing.load('a.gguf');
    await expectLater(
      failing.generate(hello),
      emitsError(isA<LlamaEngineException>()),
    );
    expect(markers(), isEmpty);
    expect(guard(1).read().verified, isEmpty);
    await failing.dispose();
  });

  test('a library that does not open removes the open marker', () async {
    final failing = IsolateLlamaEngine(
      libraries: const [_i8mm, _baseline],
      opener: (libraries) => throw const LlamaEngineException('no library'),
      variantGuard: guard(1),
    );
    await expectLater(
      failing.load('a.gguf'),
      throwsA(isA<LlamaEngineException>()),
    );
    expect(markers(), isEmpty);
    await failing.dispose();
  });
}
