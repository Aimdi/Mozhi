import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:translation_repository/translation_repository.dart';

class _MockTranslationRepository extends Mock implements TranslationRepository;

class _FakeAudioOutput implements AudioOutput {
  final played = <Uint8List>[];
  final completions = StreamController<void>.broadcast();

  @override
  Stream<void> get onComplete => completions.stream;

  @override
  Future<void> play(Uint8List bytes) async => played.add(bytes);

  @override
  Future<void> setPlaybackRate(double rate) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() => completions.close();
}

/// A device engine that reports its progress ([progress], chunk-local).
class _ProgressTts implements DeviceTts, DeviceTtsProgress {
  bool supported = true;
  final spoken = <String>[];
  final completions = StreamController<void>.broadcast();
  final progress = StreamController<SpokenRange>.broadcast();
  int stops = 0;

  /// Thrown by the speak call with this number (from 1).
  int? failAt;

  /// The second speak call waits for it when set.
  Completer<void>? secondGate;

  @override
  bool get isSupported => supported;

  @override
  DeviceVoice? get activeVoice => null;

  @override
  Future<bool> isLanguageAvailable(String languageTag) async => true;

  @override
  Future<void> setLanguage(String languageTag, {DeviceVoice? voice}) async {}

  @override
  Future<void> setSpeechRate({required bool slow, double rate = 1}) async {}

  @override
  Future<List<DeviceVoice>> voices(String languageTag) async => const [];

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    if (spoken.length == 2) await secondGate?.future;
    if (failAt == spoken.length) throw const DeviceTtsException('rejected');
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Stream<void> get onComplete => completions.stream;

  @override
  Stream<SpokenRange> get onProgress => progress.stream;

  @override
  Future<void> dispose() async {
    await completions.close();
    await progress.close();
  }
}

void main() {
  late _MockTranslationRepository repository;
  late _FakeAudioOutput output;
  late _ProgressTts device;
  late SpeechService service;
  late List<SpokenRange?> ranges;
  late StreamSubscription<SpokenRange?> subscription;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  SpeechService create({int chunkLength = maxDeviceSpeechChunkLength}) {
    final created = SpeechService(
      repository: repository,
      output: output,
      deviceTts: device,
      store: MemoryStore(),
      deviceChunkLength: chunkLength,
    );
    ranges = [];
    subscription = created.spokenRanges.listen(ranges.add);
    return created;
  }

  setUp(() {
    repository = _MockTranslationRepository();
    when(() => repository.instances).thenReturn(const []);
    when(() => repository.privacyMode).thenReturn(PrivacyMode.online);
    output = _FakeAudioOutput();
    device = _ProgressTts();
    service = create();
  });

  tearDown(() => subscription.cancel());

  test('the device chunk length stays below Android’s limit', () {
    expect(maxDeviceSpeechChunkLength, lessThan(4000));
  });

  test('reports the word being read as offsets into the text', () async {
    await service.toggle(
      id: 'target',
      text: '  Hello world',
      languageCode: 'en',
    );
    expect(device.spoken, ['Hello world']);
    device.progress
      ..add(const SpokenRange(0, 5))
      ..add(const SpokenRange(6, 11));
    await flush();
    expect(ranges, [const SpokenRange(2, 7), const SpokenRange(8, 13)]);
  });

  test('null once reading ends, stops or fails', () async {
    await service.toggle(id: 'target', text: 'Hello world', languageCode: 'en');
    device.progress.add(const SpokenRange(0, 5));
    await flush();
    device.completions.add(null);
    await flush();
    expect(ranges, [const SpokenRange(0, 5), null]);
    expect(service.current, isNull);

    await service.toggle(id: 'target', text: 'Hello world', languageCode: 'en');
    device.progress.add(const SpokenRange(6, 11));
    await flush();
    await service.stop();
    await flush();
    expect(ranges.skip(2), [const SpokenRange(6, 11), null]);
  });

  test('a new clip starts without the old range', () async {
    await service.toggle(id: 'source', text: 'Bonjour', languageCode: 'fr');
    device.progress.add(const SpokenRange(0, 7));
    await flush();
    await service.toggle(id: 'target', text: 'Hello', languageCode: 'en');
    await flush();
    expect(ranges, [const SpokenRange(0, 7), null]);
  });

  test('progress after a stop or outside the part is ignored', () async {
    await service.toggle(id: 'target', text: 'Hello', languageCode: 'en');
    device.progress
      ..add(const SpokenRange(2, 9))
      ..add(const SpokenRange(3, 3));
    await flush();
    await service.stop();
    device.progress.add(const SpokenRange(0, 5));
    await flush();
    expect(ranges, isEmpty);
  });

  test('long texts are read in parts, offsets across the parts', () async {
    service = create(chunkLength: 12);
    const text = 'One two. Three four. Five.';
    await service.toggle(id: 'target', text: text, languageCode: 'en');
    expect(device.spoken, ['One two.']);
    device.progress.add(const SpokenRange(4, 7));
    await flush();
    expect(ranges.last, const SpokenRange(4, 7));

    device.completions.add(null);
    await flush();
    expect(device.spoken, ['One two.', 'Three four.']);
    expect(service.current, 'target');
    device.progress.add(const SpokenRange(6, 10));
    await flush();
    expect(ranges.last, const SpokenRange(15, 19));
    expect(text.substring(15, 19), 'four');

    device.completions.add(null);
    await flush();
    expect(device.spoken.last, 'Five.');
    device.progress.add(const SpokenRange(0, 4));
    await flush();
    expect(text.substring(ranges.last!.start, ranges.last!.end), 'Five');

    device.completions.add(null);
    await flush();
    expect(service.current, isNull);
    expect(ranges.last, isNull);
  });

  test('a part the engine rejects ends the reading', () async {
    service = create(chunkLength: 12);
    device.failAt = 2;
    await service.toggle(
      id: 'target',
      text: 'One two. Three four.',
      languageCode: 'en',
    );
    device.completions.add(null);
    await flush();
    expect(device.spoken, ['One two.', 'Three four.']);
    expect(service.current, isNull);
  });

  test('a part that starts after a stop is stopped', () async {
    service = create(chunkLength: 12);
    final gate = device.secondGate = Completer<void>();
    await service.toggle(
      id: 'target',
      text: 'One two. Three four.',
      languageCode: 'en',
    );
    device.completions.add(null);
    await flush();
    expect(device.spoken, ['One two.', 'Three four.']);
    await service.stop();
    final stops = device.stops;
    gate.complete();
    await flush();
    expect(device.stops, stops + 1);
    expect(service.current, isNull);
  });

  test('Mozhi clips report no range', () async {
    device.supported = false;
    when(() => repository.instances)
        .thenReturn(const [MozhiInstance(url: 'https://mozhi.example')]);
    when(
      () => repository.textToSpeech(
        text: any(named: 'text'),
        languageCode: any(named: 'languageCode'),
      ),
    ).thenAnswer((_) async => Uint8List.fromList([1]));
    await service.toggle(id: 'target', text: 'Bonjour', languageCode: 'fr');
    device.progress.add(const SpokenRange(0, 7));
    await flush();
    expect(output.played, hasLength(1));
    expect(ranges, isEmpty);
  });

  test('forgetting local data stops and forgets the reading', () async {
    await service.toggle(id: 'target', text: 'Hello', languageCode: 'en');
    device.progress.add(const SpokenRange(0, 5));
    await flush();
    await service.forgetLocalData();
    device.progress.add(const SpokenRange(0, 5));
    await flush();
    expect(ranges, [const SpokenRange(0, 5), null]);
  });

  test('dispose closes the ranges', () async {
    final done = Completer<void>();
    service.spokenRanges.listen(null, onDone: done.complete);
    await service.dispose();
    await done.future;
  });

  test('an engine without progress reports no range', () async {
    final plain = SpeechService(
      repository: repository,
      output: output,
      deviceTts: _PlainTts(),
    );
    final seen = <SpokenRange?>[];
    final listening = plain.spokenRanges.listen(seen.add);
    await plain.toggle(id: 'target', text: 'Hello', languageCode: 'en');
    await flush();
    expect(seen, isEmpty);
    await listening.cancel();
  });
}

/// A device engine without progress reports.
class _PlainTts extends Fake implements DeviceTts {
  @override
  bool get isSupported => true;

  @override
  DeviceVoice? get activeVoice => null;

  @override
  Future<bool> isLanguageAvailable(String languageTag) async => true;

  @override
  Future<void> setLanguage(String languageTag, {DeviceVoice? voice}) async {}

  @override
  Future<void> setSpeechRate({required bool slow, double rate = 1}) async {}

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stop() async {}

  @override
  Stream<void> get onComplete => const Stream.empty();
}
