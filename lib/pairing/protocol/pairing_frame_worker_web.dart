import 'package:mozhi/pairing/protocol/pairing_frame_codec.dart';
import 'package:mozhi/pairing/protocol/pairing_frame_worker.dart';

/// In a browser (where phone to phone does not run): the codec on the
/// caller's isolate, a frame at a time, without compression.
PairingFrameWorker startPairingFrameWorker({
  required List<int> outgoing,
  required List<int> incoming,
}) => InlinePairingFrameWorker(
  PairingFrameCodec(outgoing: outgoing, incoming: incoming),
);

/// No compression in a browser.
PairingDeflate? get pairingDeflate => null;
