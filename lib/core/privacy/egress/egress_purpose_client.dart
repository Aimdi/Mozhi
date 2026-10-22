import 'package:http/http.dart' as http;
import 'package:mozhi/core/privacy/egress/egress_entry.dart';
import 'package:mozhi/core/privacy/egress/egress_recording_client.dart';

/// An [http.Client] that has every request it sends listed as [purpose] in
/// the network activity: it marks the request for the
/// [EgressRecordingClient] of the wrapped client (one of
/// `NetworkSession`'s), which removes the mark before the request leaves
/// the device. The wrapped client's rules (network policy, proxy) apply
/// unchanged.
///
/// [close] does nothing: the wrapped client is shared and closed by its
/// owner.
class EgressPurposeClient extends http.BaseClient {
  new(this._inner, {required this.purpose});

  final http.Client _inner;
  final EgressPurpose purpose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers[EgressRecordingClient.purposeHeader] = purpose.name;
    return _inner.send(request);
  }

  @override
  void close() {}
}
