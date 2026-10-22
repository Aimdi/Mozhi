// coverage:ignore-file

/// See `localNetworkAddresses` in `lan_address.dart`: none on the web.
Future<List<({String name, List<String> addresses})>> lanInterfaces() async =>
    const [];
