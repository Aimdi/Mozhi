import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_speech/whisper_speech.dart';

void main() {
  group(Pcm16Decoder, () {
    test('converts chunks and keeps a split sample for the next', () {
      final decoder = Pcm16Decoder();
      // 0x4000 (0.5) and 0xC000 (-0.5), split after three bytes.
      expect(decoder.convert([0x00, 0x40, 0x00]), [0.5]);
      expect(decoder.convert([0xC0]), [-0.5]);
      expect(decoder.convert(const []), isEmpty);
      expect(decoder.convert(Uint8List.fromList([0xff, 0x7f])), [
        32767 / 32768,
      ]);
    });

    test('reset drops a dangling byte', () {
      final decoder = Pcm16Decoder()
        ..convert([0x00])
        ..reset();
      expect(decoder.convert([0x00, 0x40]), [0.5]);
    });
  });
}
