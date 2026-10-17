import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/core/network/network_session.dart';
import 'package:mozhi/web_translate/data/page_extraction.dart';
import 'package:mozhi/web_translate/data/web_page_fetcher.dart';

/// A client that hands the raw [http.BaseRequest] to [handler].
class RecordingClient extends http.BaseClient {
  new(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  handler;
  final requests = <http.BaseRequest>[];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return handler(request);
  }

  @override
  void close() => closed = true;
}

/// A response that knows its final URL (like browser clients).
class UrlResponse extends http.StreamedResponse
    implements http.BaseResponseWithUrl {
  new(super.stream, super.statusCode, {required this.url, super.headers});

  @override
  final Uri url;
}

final Uri pageUri = Uri.parse('https://example.com/article');

Future<WebPageException> fetchError(WebPageFetcher fetcher, [Uri? uri]) async {
  try {
    await fetcher.fetch(uri ?? pageUri);
  } on WebPageException catch (error) {
    return error;
  }
  fail('expected a WebPageException');
}

void main() {
  group('WebPageFetcher', () {
    test('downloads and decodes a page with browser-like headers', () async {
      late http.Request seen;
      final fetcher = WebPageFetcher(
        isWeb: false,
        client: MockClient((request) async {
          seen = request;
          return http.Response.bytes(
            latin1.encode('<p>café</p>'),
            200,
            headers: {'content-type': 'text/html; charset=ISO-8859-1'},
          );
        }),
      );
      final page = await fetcher.fetch(pageUri);
      expect(page.body, '<p>café</p>');
      expect(page.url, pageUri);
      expect(page.charset, 'windows-1252');
      expect(page.contentType, 'text/html');
      expect(page.truncated, isFalse);
      expect(page.isPlainText, isFalse);
      expect(page.unsupportedCharset, isNull);
      expect(seen.headers['User-Agent'], WebPageFetcher.desktopUserAgent);
      expect(seen.headers['Accept'], contains('text/html'));
      expect(seen.headers['Accept-Language'], isNotNull);
      expect(seen.followRedirects, isFalse);
      expect(fetcher.isWeb, isFalse);
    });

    test('does not set the User-Agent on the web', () async {
      late http.Request seen;
      final fetcher = WebPageFetcher(
        isWeb: true,
        client: MockClient((request) async {
          seen = request;
          return http.Response('<p>x</p>', 200);
        }),
      );
      await fetcher.fetch(pageUri);
      expect(seen.headers.containsKey('User-Agent'), isFalse);
      expect(seen.headers.containsKey('Accept-Language'), isFalse);
      expect(seen.followRedirects, isTrue);
    });

    test('uses the final URL reported by browser clients', () async {
      final finalUri = Uri.parse('https://www.example.com/final');
      final fetcher = WebPageFetcher(
        isWeb: true,
        client: RecordingClient(
          (request) async => UrlResponse(
            Stream.value(utf8.encode('<p>x</p>')),
            200,
            url: finalUri,
          ),
        ),
      );
      expect((await fetcher.fetch(pageUri)).url, finalUri);
    });

    test('follows relative and absolute redirects', () async {
      final fetcher = WebPageFetcher(
        isWeb: false,
        client: MockClient((request) async {
          switch (request.url.path) {
            case '/article':
              return http.Response('', 301, headers: {'location': '/moved'});
            case '/moved':
              return http.Response(
                '',
                302,
                headers: {'location': 'https://other.example.org/final'},
              );
            default:
              return http.Response('<p>${request.url}</p>', 200);
          }
        }),
      );
      final page = await fetcher.fetch(pageUri);
      expect(page.url, Uri.parse('https://other.example.org/final'));
      expect(page.body, '<p>https://other.example.org/final</p>');
    });

    test('gives up after too many redirects', () async {
      final fetcher = WebPageFetcher(
        isWeb: false,
        maxRedirects: 2,
        client: MockClient(
          (request) async =>
              http.Response('', 307, headers: {'location': '/again'}),
        ),
      );
      expect((await fetchError(fetcher)).error, WebPageError.tooManyRedirects);
    });

    test('refuses redirects to other schemes', () async {
      final fetcher = WebPageFetcher(
        isWeb: false,
        client: MockClient(
          (request) async => http.Response(
            '',
            308,
            headers: {'location': 'ftp://example.com/file'},
          ),
        ),
      );
      expect((await fetchError(fetcher)).error, WebPageError.invalidUrl);
    });

    group('redirects to the local network', () {
      WebPageFetcher redirectingTo(String location, {List<Uri>? seen}) =>
          WebPageFetcher(
            isWeb: false,
            client: MockClient((request) async {
              seen?.add(request.url);
              if (request.url.path == '/article') {
                return http.Response('', 302, headers: {'location': location});
              }
              return http.Response('<p>local</p>', 200);
            }),
          );

      for (final target in [
        'http://localhost:8080/admin',
        'http://127.0.0.1/',
        'http://192.168.1.1/cgi-bin/reboot',
        'http://10.0.0.5/',
        'http://169.254.169.254/latest/meta-data/',
        'http://[::1]/',
        'http://[fd00::1]/',
        'http://router.local/',
        'http://nas/',
        'http://2130706433/',
        'http://0x7f.1/',
      ]) {
        test('refuses a public page redirecting to $target', () async {
          final seen = <Uri>[];
          final error = await fetchError(redirectingTo(target, seen: seen));
          expect(error.error, WebPageError.blockedRedirect);
          expect(seen, [pageUri]);
        });
      }

      test('allows redirects when the address typed is local', () async {
        final fetcher = WebPageFetcher(
          isWeb: false,
          client: MockClient((request) async {
            if (request.url.path == '/') {
              return http.Response('', 301, headers: {'location': '/wiki'});
            }
            return http.Response('<p>wiki</p>', 200);
          }),
        );
        final page = await fetcher.fetch(Uri.parse('http://192.168.1.20/'));
        expect(page.url, Uri.parse('http://192.168.1.20/wiki'));
      });

      test('allows public redirect targets with numeric labels', () async {
        final page = await redirectingTo('https://cafe.de/1.2').fetch(pageUri);
        expect(page.url, Uri.parse('https://cafe.de/1.2'));
      });
    });

    test('isLocalNetworkHost', () {
      expect(WebPageFetcher.isLocalNetworkHost('192.168.0.1'), isTrue);
      expect(WebPageFetcher.isLocalNetworkHost('0177.0.0.1'), isTrue);
      expect(WebPageFetcher.isLocalNetworkHost('example.com'), isFalse);
      expect(WebPageFetcher.isLocalNetworkHost('8.8.8.8'), isFalse);
      expect(WebPageFetcher.isLocalNetworkHost('dead.beef'), isFalse);
    });

    test('toString leaves query and credentials out of the URI', () {
      final error = WebPageException(
        WebPageError.httpStatus,
        statusCode: 403,
        uri: Uri.parse('https://u:p@example.com:8443/doc?token=secret#top'),
      );
      expect(
        error.toString(),
        'WebPageException(httpStatus, 403, https://example.com:8443/doc)',
      );
    });

    test('reports HTTP errors with the status code', () async {
      final fetcher = WebPageFetcher(
        isWeb: false,
        client: MockClient((request) async => http.Response('nope', 404)),
      );
      final error = await fetchError(fetcher);
      expect(error.error, WebPageError.httpStatus);
      expect(error.statusCode, 404);
      expect(error.uri, pageUri);
      expect(error.toString(), contains('404'));
    });

    test('rejects content that is not HTML or text', () async {
      final fetcher = WebPageFetcher(
        isWeb: false,
        client: MockClient(
          (request) async => http.Response(
            '%PDF',
            200,
            headers: {'content-type': 'application/pdf'},
          ),
        ),
      );
      final error = await fetchError(fetcher);
      expect(error.error, WebPageError.unsupportedContent);
      expect(error.contentType, 'application/pdf');
    });

    test('accepts plain text and pages without a content type', () async {
      final fetcher = WebPageFetcher(
        isWeb: false,
        client: MockClient(
          (request) async => request.url.path == '/notes.txt'
              ? http.Response(
                  'Plain notes',
                  200,
                  headers: {'content-type': 'text/plain; charset=utf-8'},
                )
              : http.Response('<p>No type</p>', 200, headers: {}),
        ),
      );
      final text = await fetcher.fetch(
        Uri.parse('https://example.com/notes.txt'),
      );
      expect(text.isPlainText, isTrue);
      expect(text.body, 'Plain notes');
      final html = await fetcher.fetch(pageUri);
      expect(html.contentType, isNull);
      expect(html.body, '<p>No type</p>');
    });

    test('truncates bodies larger than the size cap', () async {
      final fetcher = WebPageFetcher(
        isWeb: false,
        maxBytes: 10,
        client: RecordingClient(
          (request) async => http.StreamedResponse(
            Stream.fromIterable([
              utf8.encode('12345678'),
              utf8.encode('90abcdef'),
              utf8.encode('never read'),
            ]),
            200,
          ),
        ),
      );
      final page = await fetcher.fetch(pageUri);
      expect(page.body, '1234567890');
      expect(page.truncated, isTrue);
    });

    test('truncates exactly at a chunk boundary', () async {
      final fetcher = WebPageFetcher(
        isWeb: false,
        maxBytes: 4,
        client: RecordingClient(
          (request) async => http.StreamedResponse(
            Stream.fromIterable([utf8.encode('1234'), utf8.encode('5')]),
            200,
          ),
        ),
      );
      final page = await fetcher.fetch(pageUri);
      expect(page.body, '1234');
      expect(page.truncated, isTrue);
    });

    test('times out', () async {
      final fetcher = WebPageFetcher(
        isWeb: false,
        timeout: const Duration(milliseconds: 20),
        client: RecordingClient(
          (request) => Completer<http.StreamedResponse>().future,
        ),
      );
      expect((await fetchError(fetcher)).error, WebPageError.timeout);
    });

    test('maps a TimeoutException from the client to timeout', () async {
      final fetcher = WebPageFetcher(
        isWeb: false,
        client: RecordingClient(
          (request) async => throw TimeoutException('slow'),
        ),
      );
      final error = await fetchError(fetcher);
      expect(error.error, WebPageError.timeout);
      expect(error.cause, isA<TimeoutException>());
    });

    test('maps client errors to network errors', () async {
      final fetcher = WebPageFetcher(
        isWeb: false,
        client: MockClient(
          (request) async => throw http.ClientException('Connection refused'),
        ),
      );
      final error = await fetchError(fetcher);
      expect(error.error, WebPageError.network);
      expect(error.cause, isA<http.ClientException>());
    });

    test('maps client errors on the web to blocked by browser', () async {
      final fetcher = WebPageFetcher(
        isWeb: true,
        client: MockClient(
          (request) async => throw http.ClientException('Failed to fetch'),
        ),
      );
      expect((await fetchError(fetcher)).error, WebPageError.blockedByBrowser);
    });

    test('rejects non-http addresses without a request', () async {
      final client = RecordingClient((request) async => fail('no request'));
      final fetcher = WebPageFetcher(isWeb: false, client: client);
      final error = await fetchError(fetcher, Uri.parse('file:///etc/passwd'));
      expect(error.error, WebPageError.invalidUrl);
      expect(client.requests, isEmpty);
    });

    test('aborts the request when the trigger completes', () async {
      final client = RecordingClient((request) async {
        await (request as http.Abortable).abortTrigger;
        throw http.RequestAbortedException(request.url);
      });
      final fetcher = WebPageFetcher(isWeb: false, client: client);
      final abort = Completer<void>();
      final result = fetcher.fetch(pageUri, abortTrigger: abort.future);
      abort.complete();
      await expectLater(
        result,
        throwsA(
          isA<WebPageException>()
              .having((e) => e.error, 'error', WebPageError.network)
              .having(
                (e) => e.cause,
                'cause',
                isA<http.RequestAbortedException>(),
              ),
        ),
      );
    });

    test('never closes the client', () {
      final client = RecordingClient((request) async => fail('unused'));
      WebPageFetcher(client: client).close();
      expect(client.closed, isFalse);
    });

    test('uses the web client of the current session by default', () async {
      final previous = NetworkSession.current;
      addTearDown(() => NetworkSession.current = previous);
      final client = RecordingClient(
        (request) async => http.StreamedResponse(
          Stream.value(utf8.encode('<p>Hi</p>')),
          200,
          headers: {'content-type': 'text/html'},
        ),
      );
      NetworkSession.current = NetworkSession(httpClient: client);
      final fetcher = WebPageFetcher(isWeb: false);

      await fetcher.fetch(Uri.parse('http://example.org/'));

      expect(client.requests.single.url, Uri.parse('http://example.org/'));
      fetcher.close();
      expect(client.closed, isFalse);
    });

    test('WebPageException toString lists the details', () {
      const error = WebPageException(
        WebPageError.unsupportedContent,
        contentType: 'image/png',
        cause: 'x',
      );
      expect(error.toString(), contains('unsupportedContent'));
      expect(error.toString(), contains('image/png'));
    });
  });

  group('extractFetchedPage', () {
    test('extracts HTML', () {
      final page = extractFetchedPage(
        FetchedWebPage(
          url: pageUri,
          body: '<title>T</title><p>Hello there.</p>',
          charset: 'utf-8',
          contentType: 'text/html',
        ),
      );
      expect(page.title, 'T');
      expect(page.blocks.single.text, 'Hello there.');
    });

    test('splits plain text and names it after the file', () {
      final page = extractFetchedPage(
        FetchedWebPage(
          url: Uri.parse('https://example.com/docs/read%20me.txt'),
          body: 'One.\n\nTwo.',
          charset: 'utf-8',
          contentType: 'text/plain',
        ),
      );
      expect(page.title, 'read me.txt');
      expect(page.blocks.map((b) => b.text), ['One.', 'Two.']);
    });

    test('names plain text without a path after the host', () {
      final page = extractFetchedPage(
        FetchedWebPage(
          url: Uri.parse('https://example.com/'),
          body: 'One.',
          charset: 'utf-8',
          contentType: 'text/plain',
        ),
      );
      expect(page.title, 'example.com');
    });
  });
}
