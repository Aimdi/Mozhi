import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/pairing/protocol/pairing_address.dart';

void main() {
  group('PairingAddressPolicy', () {
    const policy = PairingAddressPolicy();

    bool allows(String address, [PairingAddressPolicy with_ = policy]) =>
        with_.allows(InternetAddress(address));

    test('allows private IPv4 addresses', () {
      expect(allows('10.0.0.5'), isTrue);
      expect(allows('10.255.255.255'), isTrue);
      expect(allows('172.16.0.1'), isTrue);
      expect(allows('172.31.255.1'), isTrue);
      expect(allows('192.168.43.1'), isTrue);
    });

    test('refuses everything else', () {
      expect(allows('8.8.8.8'), isFalse);
      expect(allows('172.15.0.1'), isFalse);
      expect(allows('172.32.0.1'), isFalse);
      expect(allows('192.169.0.1'), isFalse);
      expect(allows('100.64.0.1'), isFalse);
      expect(allows('169.254.1.1'), isFalse);
      expect(allows('127.0.0.1'), isFalse);
      expect(allows('fd00::1'), isFalse);
      expect(allows('::1'), isFalse);
    });

    test('allows loopback only when asked (tests)', () {
      const loopback = PairingAddressPolicy(allowLoopback: true);
      expect(allows('127.0.0.1', loopback), isTrue);
      expect(allows('8.8.8.8', loopback), isFalse);
      expect(allows('::1', loopback), isFalse);
    });

    test('checks raw addresses', () {
      expect(PairingAddressPolicy.isPrivateIPv4([192, 168, 0, 1]), isTrue);
      expect(PairingAddressPolicy.isPrivateIPv4([192, 168, 0]), isFalse);
    });
  });
}
