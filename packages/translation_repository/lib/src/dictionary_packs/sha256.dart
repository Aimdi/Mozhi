import 'dart:typed_data';

/// SHA-256 (FIPS 180-4) in pure Dart, fed in chunks: checks dictionary
/// packs (their data section, and whole downloads) on Android and on the
/// web without another dependency. Every intermediate value stays below
/// 2^53, so it computes the same digest when compiled to JavaScript.
///
/// ```dart
/// final hash = Sha256()..add(bytes);
/// print(hash.close()); // lower-case hex
/// ```
final class Sha256 {
  final Uint32List _state = Uint32List.fromList(const [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]);
  final Uint8List _chunk = Uint8List(64);
  final Uint32List _words = Uint32List(64);
  int _chunkLength = 0;
  int _length = 0;
  String? _digest;

  /// The hex digest of [data].
  static String of(List<int> data) => (Sha256()..add(data)).close();

  /// Adds [data] to the message. Throws [StateError] once [close]d.
  void add(List<int> data) {
    if (_digest != null) throw StateError('Sha256 is closed');
    _length += data.length;
    var index = 0;
    if (_chunkLength > 0) {
      while (_chunkLength < 64 && index < data.length) {
        _chunk[_chunkLength++] = data[index++];
      }
      if (_chunkLength < 64) return;
      _process(_chunk, 0);
      _chunkLength = 0;
    }
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    while (index + 64 <= bytes.length) {
      _process(bytes, index);
      index += 64;
    }
    while (index < bytes.length) {
      _chunk[_chunkLength++] = bytes[index++];
    }
  }

  /// Finishes the message and returns its lower-case hex digest (again on
  /// later calls).
  String close() {
    final done = _digest;
    if (done != null) return done;
    final bits = _length * 8;
    final high = (_length / 0x20000000).floor();
    final padding = Uint8List((_chunkLength < 56 ? 56 : 120) - _chunkLength)
      ..[0] = 0x80;
    final length = _length;
    add(padding);
    add([
      (high >> 24) & 0xff,
      (high >> 16) & 0xff,
      (high >> 8) & 0xff,
      high & 0xff,
      (bits >> 24) & 0xff,
      (bits >> 16) & 0xff,
      (bits >> 8) & 0xff,
      bits & 0xff,
    ]);
    _length = length;
    final buffer = StringBuffer();
    for (final word in _state) {
      buffer.write(word.toRadixString(16).padLeft(8, '0'));
    }
    return _digest = buffer.toString();
  }

  void _process(Uint8List bytes, int offset) {
    final w = _words;
    for (var i = 0; i < 16; i++) {
      final at = offset + i * 4;
      w[i] =
          bytes[at] << 24 |
          bytes[at + 1] << 16 |
          bytes[at + 2] << 8 |
          bytes[at + 3];
    }
    for (var i = 16; i < 64; i++) {
      final a = w[i - 15];
      final b = w[i - 2];
      final s0 = _rotate(a, 7) ^ _rotate(a, 18) ^ (a >>> 3);
      final s1 = _rotate(b, 17) ^ _rotate(b, 19) ^ (b >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & _mask;
    }
    var a = _state[0];
    var b = _state[1];
    var c = _state[2];
    var d = _state[3];
    var e = _state[4];
    var f = _state[5];
    var g = _state[6];
    var h = _state[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotate(e, 6) ^ _rotate(e, 11) ^ _rotate(e, 25);
      final choice = (e & f) ^ (~e & _mask & g);
      final t1 = (h + s1 + choice + _k[i] + w[i]) & _mask;
      final s0 = _rotate(a, 2) ^ _rotate(a, 13) ^ _rotate(a, 22);
      final majority = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + majority) & _mask;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & _mask;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & _mask;
    }
    _state[0] = (_state[0] + a) & _mask;
    _state[1] = (_state[1] + b) & _mask;
    _state[2] = (_state[2] + c) & _mask;
    _state[3] = (_state[3] + d) & _mask;
    _state[4] = (_state[4] + e) & _mask;
    _state[5] = (_state[5] + f) & _mask;
    _state[6] = (_state[6] + g) & _mask;
    _state[7] = (_state[7] + h) & _mask;
  }

  static const _mask = 0xffffffff;

  static int _rotate(int x, int n) => ((x >>> n) | (x << (32 - n))) & _mask;

  static const _k = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, //
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];
}
