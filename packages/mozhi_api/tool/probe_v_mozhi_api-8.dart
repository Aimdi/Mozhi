import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi_api/mozhi_api.dart';

Future<void> main() async {
  Future<void> probe(String label, MozhiApiClient client) async {
    try {
      await client.getVersion();
      print('$label: no error');
    } on MozhiApiException catch (e) {
      print('$label: MozhiApiException(${e.message}) retryable=${e.isRetryable}');
    } on Object catch (e) {
      print('$label: RAW ${e.runtimeType}: $e');
    } finally {
      client.close();
    }
  }

  await probe('unnormalized real client',
      MozhiApiClient(baseUrl: Uri.parse('mozhi.example.com')));
  await probe('normalized real client (unreachable)',
      MozhiApiClient(baseUrl: MozhiApiClient.normalizeBaseUrl('mozhi.invalid'),
          timeout: const Duration(seconds: 5)));
  await probe('custom client throwing StateError',
      MozhiApiClient(baseUrl: Uri.parse('https://x.test'),
          httpClient: MockClient((_) async => throw StateError('boom'))));
  // Can normalizeBaseUrl produce a URI that the real client rejects?
  for (final input in ['localhost:3000', 'http://[::1]:3000', 'https://a_b.c',
      'http://user@host:1/x/api', 'xn--bcher-kva.example']) {
    final uri = MozhiApiClient.normalizeBaseUrl(input);
    print('$input -> $uri host=${uri.host}');
  }
  print(http.Client);
}
