import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_speech/whisper_speech.dart';

/// Little-endian 16-bit PCM bytes of [samples].
Uint8List pcm(List<int> samples) {
  final data = ByteData(samples.length * 2);
  for (final (index, sample) in samples.indexed) {
    data.setInt16(index * 2, sample, Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  group('pcm16ToFloat32', () {
    test('scales signed 16-bit little-endian samples to -1..1', () {
      final samples = pcm16ToFloat32(pcm([0, 16384, -16384, 32767, -32768]));
      expect(samples, [0, 0.5, -0.5, closeTo(1, 1e-4), -1]);
    });

    test('ignores a trailing odd byte and accepts plain lists', () {
      expect(pcm16ToFloat32([0x00, 0x40, 0x7f]), [0.5]);
      expect(pcm16ToFloat32(const []), isEmpty);
    });
  });

  group('rmsDbfs', () {
    test('is 0 dBFS for a full-scale square wave', () {
      expect(rmsDbfs(Float32List.fromList([1, -1, 1, -1])), closeTo(0, 1e-9));
    });

    test('is about -3 dBFS for a full-scale sine', () {
      final sine = Float32List.fromList([
        for (var i = 0; i < 1600; i++) math.sin(2 * math.pi * i / 16),
      ]);
      expect(rmsDbfs(sine), closeTo(-3.01, 0.05));
    });

    test('reports silence for zeros, nothing or an empty range', () {
      expect(rmsDbfs(Float32List(10)), silenceDbfs);
      expect(rmsDbfs(Float32List(0)), silenceDbfs);
      expect(rmsDbfs(Float32List.fromList([1, 1]), 1, 1), silenceDbfs);
      expect(rmsDbfs(Float32List.fromList([1e-9])), silenceDbfs);
    });

    test('measures a range', () {
      final samples = Float32List.fromList([0, 0, 0.5, 0.5]);
      expect(rmsDbfs(samples, 2), closeTo(-6.02, 0.01));
      expect(rmsDbfs(samples, 0, 2), silenceDbfs);
      expect(rmsDbfs(samples, 2, 99), closeTo(-6.02, 0.01));
    });
  });

  group(Pcm16Buffer, () {
    test('collects chunks and keeps a sample split between them', () {
      final buffer = Pcm16Buffer();
      final bytes = pcm([16384, -16384, 8192]);
      expect(buffer.add(bytes.sublist(0, 3)), 1);
      expect(buffer.add(bytes.sublist(3)), 2);
      expect(buffer.length, 3);
      expect(buffer.toFloat32List(), [0.5, -0.5, 0.25]);
      expect(buffer.add(const []), 0);
      expect(buffer.isFull, isFalse);
    });

    test('reports the loudness of the last chunk', () {
      final buffer = Pcm16Buffer();
      expect(buffer.lastLevel, silenceDbfs);
      buffer.add(pcm([16384, -16384]));
      expect(buffer.lastLevel, closeTo(-6.02, 0.01));
      buffer.add(pcm([0, 0]));
      expect(buffer.lastLevel, silenceDbfs);
    });

    test('grows past its initial capacity', () {
      final buffer = Pcm16Buffer()
        ..add(Uint8List(40000 * 2))
        ..add(pcm([16384]));
      expect(buffer.length, 40001);
      expect(buffer.toFloat32List().last, 0.5);
      expect(buffer.duration, const Duration(microseconds: 2500062));
    });

    test('stops at maxSamples', () {
      final buffer = Pcm16Buffer(maxSamples: 3);
      expect(buffer.add(pcm([1, 2])), 2);
      expect(buffer.add(pcm([3, 4])), 1);
      expect(buffer.isFull, isTrue);
      expect(buffer.add(pcm([5])), 0);
      expect(buffer.length, 3);
    });

    test('window() holds 30 s at 16 kHz', () {
      final buffer = Pcm16Buffer.window();
      expect(buffer.maxSamples, 480000);
      expect(whisperWindow, const Duration(seconds: 30));
      expect(whisperSampleRate, 16000);
    });

    test('clear() starts over', () {
      final buffer = Pcm16Buffer()
        ..add(pcm([16384]))
        ..add([0x00])
        ..clear();
      expect(buffer.length, 0);
      expect(buffer.lastLevel, silenceDbfs);
      expect(buffer.duration, Duration.zero);
      // The dangling byte was dropped too.
      buffer.add(pcm([16384]));
      expect(buffer.toFloat32List(), [0.5]);
    });
  });
}
