import 'package:http/http.dart' as http;
import 'package:mozhi/core/network/network_session.dart';

/// An [http.Client] that sends every request with the client of
/// [NetworkSession.current] at that moment (the proxy and network policy
/// of this run, and its request log). Closing it does nothing: the session
/// owns the client. Model downloads (offline languages, speech, text
/// recognition) use it on every platform.
class CurrentSessionClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      NetworkSession.current.client.send(request);
}
