import 'dart:io';

import 'package:mozhi/core/privacy/egress/egress_entry.dart';

/// [EgressFailure] of the `dart:io` errors; null for others.
EgressFailure? platformFailureOf(Object error) => switch (error) {
  // IOClient rethrows socket errors as a ClientException that is also a
  // SocketException.
  SocketException() => EgressFailure.connection,
  TlsException() => EgressFailure.secureConnection,
  HttpException() => EgressFailure.connection,
  _ => null,
};
