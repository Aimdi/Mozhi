import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:mozhi/pairing/protocol/byte_reader.dart';
import 'package:mozhi/pairing/protocol/pairing_code.dart';
import 'package:mozhi/pairing/protocol/pairing_exception.dart';

/// The keys of one connection, one per direction, and the short
/// authentication string both phones show.
class PairingKeys {
  const new({
    required this.outgoing,
    required this.incoming,
    required this.sas,
  });

  /// AES-256-GCM key for the frames this phone sends.
  final SecretKeyData outgoing;

  /// AES-256-GCM key for the frames the other phone sends.
  final SecretKeyData incoming;

  /// Six digits from the transcript; both phones show the same ones unless
  /// someone sits in the middle.
  final String sas;
}

/// The key agreement of a pairing connection (docs/pairing.md):
///
/// 1. sender → receiver: `MZP1` and SHA-256 of its ephemeral X25519 public
///    key (a commitment, so nobody in the middle can pick keys that give
///    both phones the same [PairingKeys.sas]);
/// 2. receiver → sender: `MZP1` and its ephemeral X25519 public key;
/// 3. sender → receiver: its public key, which must match the commitment.
///
/// Both then derive, with HKDF-SHA256 over the X25519 shared secret and
/// the code's one-time secret (salt: SHA-256 of the transcript), a key per
/// direction and six digits for the users to compare. Only someone who
/// knows the code's secret gets the same keys, which the first encrypted
/// frame proves (see `PairingChannel`).
abstract final class PairingHandshake {
  /// Protocol magic and version.
  static const magic = [0x4d, 0x5a, 0x50, 0x31];

  static const _label = 'mozhi-pair-1';
  static const _info = 'mozhi pair keys';

  /// The sender's side, after connecting to the receiver of [code].
  static Future<PairingKeys> initiate({
    required PairingByteReader input,
    required void Function(List<int> bytes) output,
    required PairingCode code,
    required Duration timeout,
    SimpleKeyPair? keyPair,
  }) async {
    final ownKeys = keyPair ?? await X25519().newKeyPair();
    final own = (await ownKeys.extractPublicKey()).bytes;
    final commitment = await _sha256(own);
    output([...magic, ...commitment]);
    final reply = await input.read(magic.length + 32, timeout: timeout);
    _checkMagic(reply);
    final peer = reply.sublist(magic.length);
    output(own);
    return await _derive(
      code: code,
      keyPair: ownKeys,
      peer: peer,
      transcript: [...commitment, ...peer, ...own],
      isSender: true,
    );
  }

  /// The receiver's side, for a connection to the listener of [code].
  static Future<PairingKeys> respond({
    required PairingByteReader input,
    required void Function(List<int> bytes) output,
    required PairingCode code,
    required Duration timeout,
    SimpleKeyPair? keyPair,
  }) async {
    final hello = await input.read(magic.length + 32, timeout: timeout);
    _checkMagic(hello);
    final commitment = hello.sublist(magic.length);
    final ownKeys = keyPair ?? await X25519().newKeyPair();
    final own = (await ownKeys.extractPublicKey()).bytes;
    output([...magic, ...own]);
    final peer = await input.read(32, timeout: timeout);
    if (!_equal(await _sha256(peer), commitment)) {
      throw const PairingProtocolException('Key does not match commitment');
    }
    return await _derive(
      code: code,
      keyPair: ownKeys,
      peer: peer,
      transcript: [...commitment, ...own, ...peer],
      isSender: false,
    );
  }

  static Future<PairingKeys> _derive({
    required PairingCode code,
    required SimpleKeyPair keyPair,
    required List<int> peer,
    required List<int> transcript,
    required bool isSender,
  }) async {
    final shared = await (await X25519().sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(peer, type: KeyPairType.x25519),
    )).extractBytes();
    // A low-order public key gives an all-zero secret; refuse it.
    if (shared.every((byte) => byte == 0)) {
      throw const PairingProtocolException('Invalid public key');
    }
    final salt = await _sha256([...utf8.encode(_label), ...transcript]);
    final okm = await Hkdf(hmac: Hmac.sha256(), outputLength: 68).deriveKey(
      secretKey: SecretKey([...shared, ...code.secret]),
      nonce: salt,
      info: utf8.encode(_info),
    );
    final bytes = okm.bytes;
    final toReceiver = SecretKeyData(bytes.sublist(0, 32));
    final toSender = SecretKeyData(bytes.sublist(32, 64));
    final number = ByteData.sublistView(
      Uint8List.fromList(bytes.sublist(64, 68)),
    ).getUint32(0);
    return PairingKeys(
      outgoing: isSender ? toReceiver : toSender,
      incoming: isSender ? toSender : toReceiver,
      sas: (number % 1000000).toString().padLeft(6, '0'),
    );
  }

  static void _checkMagic(Uint8List message) {
    for (var i = 0; i < magic.length; i++) {
      if (message[i] != magic[i]) {
        throw const PairingProtocolException('Not a Mozhi pairing peer');
      }
    }
  }

  static Future<List<int>> _sha256(List<int> bytes) async =>
      (await Sha256().hash(bytes)).bytes;

  static bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }
}
