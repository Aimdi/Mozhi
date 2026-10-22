import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/pairing/protocol/byte_reader.dart';
import 'package:mozhi/pairing/protocol/pairing_exception.dart';

void main() {
  const timeout = Duration(seconds: 5);

  group('PairingByteReader', () {
    late StreamController<List<int>> source;
    late PairingByteReader reader;

    setUp(() {
      source = StreamController();
      reader = PairingByteReader(source.stream, maxBuffered: 8);
    });

    tearDown(() => reader.cancel());

    test('reads exact lengths across chunks', () async {
      source
        ..add([1, 2, 3])
        ..add(Uint8List.fromList([4, 5]))
        ..add([])
        ..add([6]);
      expect(await reader.read(2, timeout: timeout), [1, 2]);
      expect(await reader.read(3, timeout: timeout), [3, 4, 5]);
      expect(await reader.read(0, timeout: timeout), isEmpty);
      expect(await reader.read(1, timeout: timeout), [6]);
    });

    test('waits for bytes that have not arrived yet', () async {
      final read = reader.read(4, timeout: timeout);
      source.add([1, 2]);
      await Future<void>.delayed(Duration.zero);
      expect(reader.buffered, 2);
      source.add([3, 4, 5]);
      expect(await read, [1, 2, 3, 4]);
      expect(reader.buffered, 1);
    });

    test('pauses the stream while it holds too much', () async {
      source.add(List.filled(10, 1));
      await Future<void>.delayed(Duration.zero);
      expect(source.isPaused, isTrue);
      expect(await reader.read(4, timeout: timeout), hasLength(4));
      expect(source.isPaused, isFalse);
      // A read for more than is buffered resumes the stream.
      source.add(List.filled(10, 2));
      await Future<void>.delayed(Duration.zero);
      expect(source.isPaused, isTrue);
      final read = reader.read(20, timeout: timeout);
      expect(source.isPaused, isFalse);
      source.add(List.filled(4, 3));
      expect(await read, hasLength(20));
    });

    test('times out', () async {
      await expectLater(
        reader.read(1, timeout: const Duration(milliseconds: 10)),
        throwsA(isA<PairingTimeoutException>()),
      );
      // Bytes arriving later are kept for the next read.
      source.add([7]);
      expect(await reader.read(1, timeout: timeout), [7]);
    });

    test('fails reads after the stream closes', () async {
      source.add([1]);
      final read = reader.read(2, timeout: timeout);
      await source.close();
      await expectLater(read, throwsA(isA<PairingClosedException>()));
      expect(await reader.read(1, timeout: timeout), [1]);
      await expectLater(
        reader.read(1, timeout: timeout),
        throwsA(isA<PairingClosedException>()),
      );
    });

    test('fails reads after a stream error', () async {
      final read = reader.read(2, timeout: timeout);
      source.addError(StateError('reset'));
      await expectLater(
        read,
        throwsA(
          isA<PairingClosedException>().having(
            (e) => e.message,
            'message',
            contains('reset'),
          ),
        ),
      );
      await expectLater(
        reader.read(1, timeout: timeout),
        throwsA(isA<PairingClosedException>()),
      );
    });

    test('fails a pending read when cancelled', () async {
      final read = expectLater(
        reader.read(1, timeout: timeout),
        throwsA(isA<PairingClosedException>()),
      );
      await reader.cancel();
      await read;
    });

    test('allows one read at a time and no negative lengths', () async {
      expect(() => reader.read(-1, timeout: timeout), throwsArgumentError);
      unawaited(reader.read(1, timeout: timeout).then((_) {}, onError: (_) {}));
      expect(() => reader.read(1, timeout: timeout), throwsStateError);
    });
  });
}
