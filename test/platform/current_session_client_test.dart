import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/core/network/network.dart';
import 'package:mozhi/core/privacy/egress/egress.dart';
import 'package:mozhi/platform/current_session_client.dart';

void main() {
  group(CurrentSessionClient, () {
    late NetworkSession previous;

    setUp(() => previous = NetworkSession.current);
    tearDown(() => NetworkSession.current = previous);

    test('lists its requests as model downloads', () async {
      final session = NetworkSession(
        httpClient: MockClient((request) async => http.Response('ok', 200)),
      );
      NetworkSession.current = session;

      await CurrentSessionClient().get(
        Uri.parse('https://mirror.example/models/tesseract/deu.traineddata'),
      );

      final entry = session.ledger.entries.single;
      expect(entry.purpose, EgressPurpose.modelDownload);
      expect(entry.destination.kind, EgressDestinationKind.modelHost);
    });
  });
}
