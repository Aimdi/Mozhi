import 'dart:math' as math;
import 'dart:typed_data';

/// The sample rate Whisper expects: 16 kHz mono.
const whisperSampleRate = 16000;

/// The audio Whisper reads at once: 30 s. Longer recordings are transcribed
/// window by window (slower, and words at a window boundary may be lost),
/// so voice input stops recording at this length.
const whisperWindow = Duration(seconds: 30);

/// Loudness reported for digital silence: -100 dBFS.
const silenceDbfs = -100.0;

/// Converts little-endian signed 16-bit PCM ([bytes]) to samples in
/// `-1..1` (a trailing odd byte is ignored).
Float32List pcm16ToFloat32(List<int> bytes) {
  final data = bytes is Uint8List
      ? ByteData.sublistView(bytes)
      : ByteData.sublistView(Uint8List.fromList(bytes));
  final samples = Float32List(data.lengthInBytes ~/ 2);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = data.getInt16(i * 2, Endian.little) / 32768;
  }
  return samples;
}

/// Root-mean-square loudness of `samples[start..end)` in dBFS: 0 for a
/// full-scale square wave, about -3 for a full-scale sine, [silenceDbfs]
/// for silence or no samples.
double rmsDbfs(Float32List samples, [int start = 0, int? end]) {
  final stop = math.min(end ?? samples.length, samples.length);
  if (start >= stop) return silenceDbfs;
  var sum = 0.0;
  for (var i = start; i < stop; i++) {
    final sample = samples[i];
    sum += sample * sample;
  }
  final rms = math.sqrt(sum / (stop - start));
  if (rms <= 0) return silenceDbfs;
  return math.max(20 * math.log(rms) / math.ln10, silenceDbfs);
}

/// Converts a stream of little-endian 16-bit PCM chunks (from a microphone)
/// to Whisper's float samples chunk by chunk, without collecting them:
/// a chunk may split a sample (an odd number of bytes), whose dangling byte
/// is kept for the next chunk.
final class Pcm16Decoder {
  int? _pendingByte;

  /// The samples [chunk] completes.
  Float32List convert(List<int> chunk) {
    if (chunk.isEmpty) return Float32List(0);
    final bytes = Uint8List(chunk.length + (_pendingByte == null ? 0 : 1));
    var offset = 0;
    if (_pendingByte case final pending?) {
      bytes[0] = pending;
      offset = 1;
    }
    bytes.setRange(offset, bytes.length, chunk);
    _pendingByte = bytes.length.isOdd ? bytes.last : null;
    return pcm16ToFloat32(bytes);
  }

  /// Forgets a dangling byte (a new stream).
  void reset() => _pendingByte = null;
}

/// Collects a recording that arrives as chunks of little-endian 16-bit
/// PCM (from a microphone stream) as Whisper's float samples.
///
/// Chunks may split a sample (an odd number of bytes): the dangling byte
/// is kept for the next chunk. With [maxSamples] (e.g. 30 s at 16 kHz,
/// [whisperWindow]) the buffer stops growing once full and drops the rest.
final class Pcm16Buffer {
  new({this.maxSamples})
    : assert(maxSamples == null || maxSamples > 0, 'maxSamples must be > 0'),
      _samples = Float32List(maxSamples ?? 16000);

  /// [whisperWindow] at [whisperSampleRate]: 480 000 samples.
  factory window() =>
      Pcm16Buffer(maxSamples: whisperWindow.inSeconds * whisperSampleRate);

  /// The most samples kept (null: unlimited).
  final int? maxSamples;

  Float32List _samples;
  int _length = 0;
  int? _pendingByte;
  double _lastLevel = silenceDbfs;

  /// Samples collected so far.
  int get length => _length;

  /// [length] at [whisperSampleRate].
  Duration get duration =>
      Duration(microseconds: _length * 1000000 ~/ whisperSampleRate);

  /// Whether [maxSamples] are collected (later chunks are dropped).
  bool get isFull => maxSamples != null && _length >= maxSamples!;

  /// Loudness of the samples of the last [add] in dBFS ([rmsDbfs]).
  double get lastLevel => _lastLevel;

  /// Appends a chunk; returns how many samples were kept (fewer than in
  /// the chunk once the buffer is full).
  int add(List<int> chunk) {
    if (chunk.isEmpty) return 0;
    final bytes = Uint8List(chunk.length + (_pendingByte == null ? 0 : 1));
    var offset = 0;
    if (_pendingByte case final pending?) {
      bytes[0] = pending;
      offset = 1;
    }
    bytes.setRange(offset, bytes.length, chunk);
    _pendingByte = bytes.length.isOdd ? bytes.last : null;
    final samples = pcm16ToFloat32(bytes);
    _lastLevel = rmsDbfs(samples);
    final room = maxSamples == null
        ? samples.length
        : math.min(samples.length, maxSamples! - _length);
    if (room <= 0) return 0;
    _ensureCapacity(_length + room);
    _samples.setRange(_length, _length + room, samples);
    _length += room;
    return room;
  }

  /// A copy of the samples collected so far.
  Float32List toFloat32List() =>
      Float32List.fromList(Float32List.sublistView(_samples, 0, _length));

  /// Forgets everything collected.
  void clear() {
    _length = 0;
    _pendingByte = null;
    _lastLevel = silenceDbfs;
  }

  void _ensureCapacity(int needed) {
    if (needed <= _samples.length) return;
    var capacity = _samples.length * 2;
    while (capacity < needed) {
      capacity *= 2;
    }
    final grown = Float32List(capacity)..setRange(0, _length, _samples);
    _samples = grown;
  }
}
