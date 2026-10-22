import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:mozhi/core/network/http_client_factory.dart';
import 'package:mozhi/core/privacy/egress/egress_entry.dart';
import 'package:mozhi/core/privacy/egress/egress_failure_io.dart'
    if (dart.library.js_interop) 'package:mozhi/core/privacy/egress/egress_failure_web.dart'
    as platform;

/// How a request that threw [error] ended: [EgressOutcome.notSent] when it
/// was refused before anything was sent, [EgressOutcome.cancelled] when the
/// app aborted it, else [EgressOutcome.failed].
EgressOutcome egressOutcomeOf(Object error) => switch (error) {
  InvalidProxyException() => EgressOutcome.notSent,
  http.RequestAbortedException() => EgressOutcome.cancelled,
  _ => EgressOutcome.failed,
};

/// Why a request that threw [error] failed, without looking at anything
/// it carried.
EgressFailure egressFailureOf(Object error) {
  if (error is TimeoutException) return EgressFailure.timeout;
  return platform.platformFailureOf(error) ??
      (error is http.ClientException
          ? EgressFailure.connection
          : EgressFailure.other);
}
