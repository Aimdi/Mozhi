import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/core/network/network.dart';
import 'package:mozhi/core/privacy/egress/egress.dart';

/// A redirect to [location].
http.Response _redirect(int status, String location) =>
    http.Response('moved', status, headers: {'location': location});

/// The refusal of a redirect into the private network, with the redacted
/// [uri] of its target.
Matcher _refusedIntoPrivate(String uri) => throwsA(
  isA<RedirectRefusedException>()
      .having(
        (e) => e.message,
        'message',
        RedirectRefusedException.privateNetworkMessage,
      )
      .having((e) => e.uri.toString(), 'uri', uri),
);

void main() {
  late List<http.Request> sent;

  /// The answers of the servers, by URL; anything else is a 404.
  late Map<String, http.Response> answers;

  setUp(() {
    sent = [];
    answers = {};
  });

  late final mock = MockClient((request) async {
    sent.add(request);
    return answers[request.url.toString()] ?? http.Response('missing', 404);
  });

  BackendHttpClient client({bool hasProxy = false, http.Client? inner}) =>
      BackendHttpClient(
        inner ?? mock,
        policy: NetworkPolicy(hasProxy: hasProxy),
      );

  Iterable<String> sentUrls() => sent.map((r) => r.url.toString());

  group('BackendHttpClient redirects', () {
    test('follows a redirect to another public https host, keeping the '
        'request headers but Authorization', () async {
      answers
        ..['https://huggingface.co/m/resolve/main/model.bin'] = _redirect(
          302,
          'https://cdn-lfs.hf.co/abc/model.bin?sig=1#part',
        )
        ..['https://cdn-lfs.hf.co/abc/model.bin?sig=1'] = http.Response(
          'model',
          206,
          headers: {'content-range': 'bytes 10-14/15'},
        );
      final request =
          http.Request(
              'GET',
              Uri.parse('https://huggingface.co/m/resolve/main/model.bin'),
            )
            ..headers.addAll({
              'Range': 'bytes=10-',
              'If-Range': '"etag"',
              'Accept': '*/*',
              'Accept-Encoding': 'identity',
              'User-Agent': 'Mozhi',
              'Authorization': 'Bearer secret',
              'Cookie': 'session=1',
              'Referer': 'https://app.example/',
            });

      final response = await client().send(request);

      expect(response.statusCode, 206);
      expect(await response.stream.bytesToString(), 'model');
      expect(sentUrls(), [
        'https://huggingface.co/m/resolve/main/model.bin',
        'https://cdn-lfs.hf.co/abc/model.bin?sig=1',
      ]);
      expect(sent.map((r) => r.followRedirects), everyElement(isFalse));
      expect(sent.map((r) => r.method), everyElement('GET'));
      expect(
        sent.first.headers,
        containsPair('Authorization', 'Bearer secret'),
      );
      expect(sent.last.headers, {
        'Range': 'bytes=10-',
        'If-Range': '"etag"',
        'Accept': '*/*',
        'Accept-Encoding': 'identity',
        'User-Agent': 'Mozhi',
      });
      // Callers see where the answer came from.
      final last = Uri.parse('https://cdn-lfs.hf.co/abc/model.bin?sig=1');
      expect(response.request?.url, last);
      expect(response, isA<http.BaseResponseWithUrl>());
      expect((response as http.BaseResponseWithUrl).url, last);
      expect(response.headers['content-range'], 'bytes 10-14/15');
    });

    test('keeps Authorization on the same origin only, and drops it for '
        'good once the origin changed', () async {
      answers
        ..['https://dl.example/a'] = _redirect(301, '/b')
        ..['https://dl.example/b'] = _redirect(302, 'https://cdn.example/c')
        ..['https://cdn.example/c'] = _redirect(307, 'https://dl.example/d')
        ..['https://dl.example/d'] = http.Response('ok', 200);

      await client().get(
        Uri.parse('https://dl.example/a'),
        headers: {'authorization': 'Basic x'},
      );

      expect(sent.map((r) => r.headers['authorization']), [
        'Basic x',
        'Basic x',
        null,
        null,
      ]);
    });

    test('resolves relative Locations against the current URL', () async {
      answers
        ..['https://dl.example/models/a/file'] = _redirect(302, 'other')
        ..['https://dl.example/models/a/other'] = _redirect(301, '../b/file')
        ..['https://dl.example/models/b/file'] = _redirect(
          308,
          '//mirror.example:8443/x?y=1',
        )
        ..['https://mirror.example:8443/x?y=1'] = http.Response('ok', 200);

      final response = await client().get(
        Uri.parse('https://dl.example/models/a/file'),
      );

      expect(response.body, 'ok');
      expect(sentUrls(), [
        'https://dl.example/models/a/file',
        'https://dl.example/models/a/other',
        'https://dl.example/models/b/file',
        'https://mirror.example:8443/x?y=1',
      ]);
    });

    for (final status in BackendHttpClient.redirectStatuses) {
      test('follows a $status for GET and HEAD with the same method', () async {
        answers
          ..['https://dl.example/a'] = _redirect(status, '/b')
          ..['https://dl.example/b'] = http.Response('', 200);

        await client().get(Uri.parse('https://dl.example/a'));
        await client().head(Uri.parse('https://dl.example/a'));

        expect(sent.map((r) => (r.method, r.url.path)), [
          ('GET', '/a'),
          ('GET', '/b'),
          ('HEAD', '/a'),
          ('HEAD', '/b'),
        ]);
      });
    }

    test('drops user info in the Location', () async {
      answers
        ..['https://dl.example/a'] = _redirect(
          302,
          'https://me:pw@cdn.example/b',
        )
        ..['https://cdn.example/b'] = http.Response('ok', 200);

      await client().get(Uri.parse('https://dl.example/a'));

      expect(sent.last.url.toString(), 'https://cdn.example/b');
    });

    test('refuses a downgrade from https to http', () async {
      answers['https://mirror.example/a'] = _redirect(
        302,
        'http://mirror.example/a?lang=de',
      );
      await expectLater(
        client().get(Uri.parse('https://mirror.example/a')),
        throwsA(
          isA<CleartextRefusedException>().having(
            (e) => e.uri.toString(),
            'uri',
            'http://mirror.example/a',
          ),
        ),
      );

      // Even where plain http is allowed.
      answers['https://192.168.1.4/a'] = _redirect(301, 'http://192.168.1.4/a');
      await expectLater(
        client().get(Uri.parse('https://192.168.1.4/a')),
        throwsA(
          isA<RedirectRefusedException>()
              .having(
                (e) => e.message,
                'message',
                allOf(
                  RedirectRefusedException.downgradeMessage,
                  startsWith(RedirectRefusedException.marker),
                ),
              )
              .having((e) => e.uri.toString(), 'uri', 'http://192.168.1.4/a'),
        ),
      );

      expect(sentUrls(), ['https://mirror.example/a', 'https://192.168.1.4/a']);
    });

    for (final (:target, :redacted) in [
      (
        target: 'https://192.168.1.1/admin?pw=1#x',
        redacted: 'https://192.168.1.1/admin',
      ),
      (target: 'http://192.168.1.1/', redacted: 'http://192.168.1.1/'),
      (
        target: 'https://x.tail123.ts.net/m',
        redacted: 'https://x.tail123.ts.net/m',
      ),
      (target: 'https://localhost:8080/', redacted: 'https://localhost:8080/'),
      (target: 'https://[fd00::1]/', redacted: 'https://[fd00::1]/'),
      (target: 'https://nas.local/', redacted: 'https://nas.local/'),
      (target: 'https://router/', redacted: 'https://router/'),
    ]) {
      test('refuses a redirect from a public server to $target', () async {
        answers
          ..['https://mirror.example/a'] = _redirect(302, target)
          ..[target] = http.Response('ok', 200);

        await expectLater(
          client().get(Uri.parse('https://mirror.example/a')),
          // Plain http to the LAN is allowed, a downgrade is not.
          target.startsWith('http:')
              ? throwsA(isA<RedirectRefusedException>())
              : _refusedIntoPrivate(redacted),
        );
        // Nothing was sent to the target.
        expect(sentUrls(), ['https://mirror.example/a']);
      });
    }

    test('refuses a public server sending the request to a .onion address, '
        'and a .onion server sending it into the local network', () async {
      answers
        ..['https://mirror.example/a'] = _redirect(302, 'http://abc.onion/a')
        ..['http://abc.onion/b'] = _redirect(302, 'http://192.168.1.1/b')
        ..['http://abc.onion/c'] = _redirect(302, '/d')
        ..['http://abc.onion/d'] = http.Response('ok', 200);
      final proxied = client(hasProxy: true);

      await expectLater(
        proxied.get(Uri.parse('https://mirror.example/a')),
        _refusedIntoPrivate('http://abc.onion/a'),
      );
      await expectLater(
        proxied.get(Uri.parse('http://abc.onion/b')),
        _refusedIntoPrivate('http://192.168.1.1/b'),
      );
      // Within the hidden service is fine.
      expect((await proxied.get(Uri.parse('http://abc.onion/c'))).body, 'ok');

      expect(sentUrls(), [
        'https://mirror.example/a',
        'http://abc.onion/b',
        'http://abc.onion/c',
        'http://abc.onion/d',
      ]);
    });

    test(
      'refuses a .onion hop without a proxy before it is looked up',
      () async {
        answers['https://mirror.example/a'] = _redirect(
          307,
          'https://abc.onion/a?q=1',
        );

        await expectLater(
          client().get(Uri.parse('https://mirror.example/a')),
          throwsA(
            isA<ProxyRequiredException>().having(
              (e) => e.uri.toString(),
              'uri',
              'https://abc.onion/a',
            ),
          ),
        );
        expect(sentUrls(), ['https://mirror.example/a']);
      },
    );

    test('follows plain http redirects within the local network, and from '
        'it to public https servers', () async {
      answers
        ..['http://192.168.1.4:8080/m'] = _redirect(302, 'http://nas.local/m')
        ..['http://nas.local/m'] = _redirect(302, 'https://huggingface.co/m')
        ..['https://huggingface.co/m'] = http.Response('ok', 200);

      final response = await client().get(
        Uri.parse('http://192.168.1.4:8080/m'),
      );

      expect(response.body, 'ok');
      expect(sentUrls(), [
        'http://192.168.1.4:8080/m',
        'http://nas.local/m',
        'https://huggingface.co/m',
      ]);
    });

    for (final location in [
      'ftp://mirror.example/a',
      'file:///etc/passwd',
      'data:text/plain,x',
      'https:///no-host',
    ]) {
      test('refuses a redirect to $location', () async {
        answers['https://mirror.example/a'] = _redirect(302, location);

        await expectLater(
          client().get(Uri.parse('https://mirror.example/a')),
          throwsA(
            isA<RedirectRefusedException>().having(
              (e) => e.message,
              'message',
              RedirectRefusedException.unsupportedMessage,
            ),
          ),
        );
        expect(sent, hasLength(1));
      });
    }

    test('gives up after the request\'s maxRedirects', () async {
      for (var hop = 0; hop < 10; hop++) {
        answers['https://dl.example/$hop'] = _redirect(302, '/${hop + 1}');
      }

      await expectLater(
        client().get(Uri.parse('https://dl.example/0')),
        throwsA(
          isA<http.ClientException>()
              .having((e) => e.message, 'message', 'Redirect limit exceeded')
              .having((e) => e.uri.toString(), 'uri', 'https://dl.example/5'),
        ),
      );
      // The default of 5 redirects, as in dart:io.
      expect(sent, hasLength(6));

      sent.clear();
      await expectLater(
        client().send(
          http.Request('GET', Uri.parse('https://dl.example/0'))
            ..maxRedirects = 1,
        ),
        throwsA(isA<http.ClientException>()),
      );
      expect(sent, hasLength(2));

      sent.clear();
      await expectLater(
        client().send(
          http.Request('GET', Uri.parse('https://dl.example/0'))
            ..maxRedirects = 0,
        ),
        throwsA(isA<http.ClientException>()),
      );
      expect(sent, hasLength(1));
    });

    test('returns a redirect without a usable Location as it is', () async {
      answers
        ..['https://dl.example/a'] = http.Response('Found', 302)
        ..['https://dl.example/b'] = _redirect(302, 'http://[::1');

      final missing = await client().get(Uri.parse('https://dl.example/a'));
      final broken = await client().get(Uri.parse('https://dl.example/b'));

      expect((missing.statusCode, missing.body), (302, 'Found'));
      expect((broken.statusCode, broken.body), (302, 'moved'));
      expect(sent, hasLength(2));
    });

    test('passes other requests through untouched', () async {
      answers['https://api.example/v1/models'] = _redirect(
        302,
        'https://other.example/v1/models',
      );

      final post = await client().post(
        Uri.parse('https://api.example/v1/models'),
        body: 'x',
      );
      final manual = await client().send(
        http.Request('GET', Uri.parse('https://api.example/v1/models'))
          ..followRedirects = false
          ..maxRedirects = 0,
      );

      expect(post.statusCode, 302);
      expect(manual.statusCode, 302);
      expect(sent, hasLength(2));
      expect(sent.first.method, 'POST');
      // Not changed: dart:io never follows a POST by itself.
      expect(sent.first.followRedirects, isTrue);
      expect(sent.first.body, 'x');
      expect(sent.last.followRedirects, isFalse);
      expect(sent.last.maxRedirects, 0);
    });

    test('does not wrap a response that was not redirected', () async {
      final answer = http.StreamedResponse(const Stream.empty(), 200);
      final inner = _RecordingClient((_) => answer);

      final response = await client(inner: inner)
          .get(Uri.parse('https://dl.example/a'));

      expect(response.statusCode, 200);
      expect(inner.sent.single.followRedirects, isFalse);
    });

    test(
      'drains the body of every redirect and keeps the abort trigger',
      () async {
        final drained = <String>[];
        Stream<List<int>> body(String url) async* {
          yield utf8.encode('moved');
          drained.add(url);
        }

        final inner = _RecordingClient(
          (request) => switch (request.url.path) {
            '/a' => http.StreamedResponse(
              body('/a'),
              302,
              headers: {'location': '/b'},
            ),
            '/b' => http.StreamedResponse(
              body('/b'),
              303,
              headers: {'location': 'https://cdn.example/c'},
            ),
            _ => http.StreamedResponse(Stream.value(utf8.encode('ok')), 200),
          },
        );
        final abort = Completer<void>();

        final response = await client(inner: inner).send(
          http.AbortableRequest(
            'GET',
            Uri.parse('https://dl.example/a'),
            abortTrigger: abort.future,
          ),
        );

        expect(await response.stream.bytesToString(), 'ok');
        expect(drained, ['/a', '/b']);
        expect(inner.sent, hasLength(3));
        for (final request in inner.sent) {
          expect(request, isA<http.Abortable>());
          expect((request as http.Abortable).abortTrigger, same(abort.future));
        }
      },
    );

    test('records every hop in the egress ledger of the session', () async {
      answers
        ..['https://github.com/o/r/releases/download/v1/de.tar'] = _redirect(
          302,
          'https://release-assets.githubusercontent.com/x/de.tar?sig=1',
        )
        ..['https://release-assets.githubusercontent.com/x/de.tar?sig=1'] =
            http.Response('model', 200)
        ..['https://mirror.example/a'] = _redirect(302, 'https://10.0.0.1/a');
      final session = NetworkSession(httpClient: mock);

      final response = await session.modelClient.get(
        Uri.parse('https://github.com/o/r/releases/download/v1/de.tar'),
      );
      await expectLater(
        session.modelClient.get(Uri.parse('https://mirror.example/a')),
        throwsA(isA<RedirectRefusedException>()),
      );

      expect(response.body, 'model');
      final entries = session.ledger.entries;
      expect(entries.map((e) => (e.destination.host, e.statusCode)), [
        ('github.com', 302),
        ('release-assets.githubusercontent.com', 200),
        ('mirror.example', 302),
      ]);
      expect(
        entries.map((e) => e.purpose),
        everyElement(EgressPurpose.modelDownload),
      );
      expect(
        entries.map((e) => e.outcome),
        everyElement(EgressOutcome.succeeded),
      );
      // The refused hop was never sent.
      expect(sent.map((r) => r.url.host), isNot(contains('10.0.0.1')));
    });
  });
}

/// An [http.Client] that records the requests it is given (not copies) and
/// answers them with [answer].
class _RecordingClient extends http.BaseClient {
  new(this.answer);

  final http.StreamedResponse Function(http.BaseRequest request) answer;
  final sent = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent.add(request);
    await request.finalize().drain<void>();
    return answer(request);
  }
}
