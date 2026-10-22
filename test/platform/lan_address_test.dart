import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/platform/lan_address.dart';
import 'package:mozhi/platform/lan_address_io.dart' as io;

void main() {
  group('isPrivateIPv4', () {
    test('accepts the RFC 1918 ranges', () {
      for (final address in [
        '10.0.0.1',
        '10.255.255.255',
        '172.16.0.1',
        '172.31.255.254',
        '192.168.0.1',
        '192.168.43.1',
      ]) {
        expect(isPrivateIPv4(address), isTrue, reason: address);
      }
    });

    test('refuses everything else', () {
      for (final address in [
        '127.0.0.1',
        '100.64.0.1', // Carrier-grade NAT.
        '100.101.102.103', // Tailscale.
        '169.254.1.1', // Link-local.
        '172.15.0.1',
        '172.32.0.1',
        '192.169.0.1',
        '8.8.8.8',
        '0.0.0.0',
        '255.255.255.255',
        '10.0.0',
        '10.0.0.1.2',
        '10.0.0.256',
        '10.0.0.-1',
        '10.0.0.0001',
        '10.a.0.1',
        'fe80::1',
        '',
      ]) {
        expect(isPrivateIPv4(address), isFalse, reason: address);
      }
    });
  });

  group('rankLanAddresses', () {
    test('puts Wi-Fi first, then the hotspot, Ethernet and the rest', () {
      expect(
        rankLanAddresses([
          (name: 'eth0', addresses: ['192.168.2.5']),
          (name: 'ap0', addresses: ['192.168.43.1']),
          (name: 'bridge0', addresses: ['172.20.0.1']),
          (name: 'wlan0', addresses: ['192.168.1.23']),
        ]),
        ['192.168.1.23', '192.168.43.1', '192.168.2.5', '172.20.0.1'],
      );
    });

    test('keeps the platform order within a rank', () {
      expect(
        rankLanAddresses([
          (name: 'wlan1', addresses: ['10.0.0.2']),
          (name: 'swlan0', addresses: ['10.0.0.3', '10.0.0.4']),
        ]),
        ['10.0.0.2', '10.0.0.3', '10.0.0.4'],
      );
    });

    test('skips mobile data, VPNs, loopback and public addresses', () {
      expect(
        rankLanAddresses([
          (name: 'lo', addresses: ['127.0.0.1']),
          (name: 'rmnet_data0', addresses: ['10.120.4.7']),
          (name: 'ccmni1', addresses: ['10.33.1.2']),
          (name: 'tun0', addresses: ['10.8.0.2']),
          (name: 'wg0', addresses: ['10.66.0.2']),
          (name: 'tailscale0', addresses: ['100.101.102.103']),
          (name: 'v4-rmnet_data0', addresses: ['192.0.0.4']),
          (name: 'wlan0', addresses: ['100.64.3.4', '203.0.113.9']),
          (name: 'WLAN0', addresses: ['192.168.1.9']),
        ]),
        ['192.168.1.9'],
      );
    });

    test('lists an address once', () {
      expect(
        rankLanAddresses([
          (name: 'wlan0', addresses: ['192.168.1.2', '192.168.1.2']),
          (name: 'eth0', addresses: ['192.168.1.2']),
        ]),
        ['192.168.1.2'],
      );
    });
  });

  group('localNetworkAddresses', () {
    tearDown(() => debugLanInterfaces = null);

    test('ranks what the platform lists', () async {
      debugLanInterfaces = () async => [
        (name: 'rmnet0', addresses: ['10.1.2.3']),
        (name: 'wlan0', addresses: ['192.168.1.23']),
      ];

      expect(await localNetworkAddresses(), ['192.168.1.23']);
    });

    test('is empty when listing fails', () async {
      debugLanInterfaces = () async => throw StateError('no network');

      expect(await localNetworkAddresses(), isEmpty);
    });

    test('lists the host machine without throwing', () async {
      final addresses = await localNetworkAddresses();

      expect(addresses.every(isPrivateIPv4), isTrue);
    });
  });

  group('lanInterfaces (dart:io)', () {
    test('lists IPv4 addresses only', () async {
      final interfaces = await io.lanInterfaces();

      for (final interface in interfaces) {
        expect(interface.addresses.every((a) => !a.contains(':')), isTrue);
      }
    });
  });
}
