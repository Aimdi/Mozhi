import 'dart:io';

/// See `localNetworkAddresses` in `lan_address.dart`.
Future<List<({String name, List<String> addresses})>> lanInterfaces() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  return [
    for (final interface in interfaces)
      (
        name: interface.name,
        addresses: [
          for (final address in interface.addresses)
            if (address.type == InternetAddressType.IPv4) address.address,
        ],
      ),
  ];
}
