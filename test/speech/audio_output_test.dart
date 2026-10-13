import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/speech/audio_output.dart';

class _MockAudioPlayer extends Mock implements AudioPlayer;

void main() {
  group(AudioPlayersOutput, () {
    final bytes = Uint8List.fromList([1, 2, 3]);
    late AudioPlayer player;
    late StreamController<void> completions;
    late int created;
    late AudioPlayersOutput output;

    setUpAll(() {
      registerFallbackValue(BytesSource(Uint8List(0)));
    });

    setUp(() {
      player = _MockAudioPlayer();
      completions = StreamController<void>.broadcast();
      created = 0;
      when(() => player.onPlayerComplete).thenAnswer((_) => completions.stream);
      when(() => player.play(any())).thenAnswer((_) async {});
      when(() => player.stop()).thenAnswer((_) async {});
      when(() => player.dispose()).thenAnswer((_) async {});
      when(() => player.setPlaybackRate(any())).thenAnswer((_) async {});
      output = AudioPlayersOutput(
        createPlayer: () {
          created++;
          return player;
        },
      );
    });

    tearDown(() => completions.close());

    test('can be created and disposed without touching the plugin', () async {
      final output = AudioPlayersOutput();

      await output.stop();
      await output.dispose();
    });

    test('creates the player lazily, once', () async {
      expect(created, 0);

      await output.play(bytes);
      await output.play(bytes);

      expect(created, 1);
    });

    test('plays the clip as an MP3 byte source', () async {
      await output.play(bytes);

      final source =
          verify(() => player.play(captureAny())).captured.single
              as BytesSource;
      expect(source.bytes, bytes);
      expect(source.mimeType, 'audio/mpeg');
    });

    test('falls back to a data URI when bytes are not supported', () async {
      when(() => player.play(any(that: isA<BytesSource>())))
          .thenThrow(Exception('BytesSource is not supported'));

      await output.play(bytes);

      final captured = verify(() => player.play(captureAny())).captured;
      final source = captured.last as UrlSource;
      expect(source.url, startsWith('data:audio/mpeg;base64,'));
      expect(Uri.parse(source.url).data!.contentAsBytes(), bytes);
      expect(source.mimeType, 'audio/mpeg');
    });

    test('throws when the fallback fails too', () async {
      when(() => player.play(any())).thenThrow(Exception('unplayable'));

      await expectLater(output.play(bytes), throwsException);
    });

    test('forwards completion events', () async {
      await output.play(bytes);
      final completed = expectLater(output.onComplete, emits(anything));

      completions.add(null);

      await completed;
    });

    test('stop is a no-op before anything was played', () async {
      await output.stop();

      expect(created, 0);
    });

    test('stop stops the player', () async {
      await output.play(bytes);

      await output.stop();

      verify(() => player.stop()).called(1);
    });

    group('setPlaybackRate', () {
      test('does not touch the player at normal speed', () async {
        await output.setPlaybackRate(1);

        expect(created, 0);
      });

      test('sets the rate on the player once per change', () async {
        await output.setPlaybackRate(0.7);
        await output.setPlaybackRate(0.7);
        await output.setPlaybackRate(1);

        final rates = verify(() => player.setPlaybackRate(captureAny()))
            .captured;
        expect(rates, [0.7, 1]);
      });

      test('retries a rate the player rejected', () async {
        when(() => player.setPlaybackRate(any()))
            .thenThrow(Exception('unsupported'));

        await expectLater(output.setPlaybackRate(0.7), throwsException);
        await expectLater(output.setPlaybackRate(0.7), throwsException);

        verify(() => player.setPlaybackRate(0.7)).called(2);
      });
    });

    test('dispose releases the player and closes the stream', () async {
      await output.play(bytes);
      final done = expectLater(output.onComplete, emitsDone);

      await output.dispose();

      await done;
      verify(() => player.dispose()).called(1);
      expect(completions.hasListener, isFalse);
    });
  });
}
