import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:http_parser/http_parser.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

class _MockHttpClient extends Mock implements http.Client;

final Uri _baseUrl = Uri.parse('https://mozhi.example');

/// Mozhi (Fiber) sends `application/json` without a charset.
http.Response _json(String body, {int status = 200}) => http.Response.bytes(
  utf8.encode(body),
  status,
  headers: {'content-type': 'application/json'},
);

http.Response _text(
  String body,
  int status, {
  String? reasonPhrase,
  Map<String, String> headers = const {},
}) => http.Response.bytes(
  utf8.encode(body),
  status,
  reasonPhrase: reasonPhrase,
  headers: headers,
);

/// The `Authorization` header for [credentials] (`user:password`).
String _basic(String credentials) =>
    'Basic ${base64Encode(utf8.encode(credentials))}';

Matcher _throwsMozhiError({
  required int? statusCode,
  Object message = anything,
  Object uri = anything,
}) => throwsA(
  isA<MozhiApiException>()
      .having((e) => e.statusCode, 'statusCode', statusCode)
      .having((e) => e.message, 'message', message)
      .having((e) => e.uri, 'uri', uri),
);

/// A minimal `multipart/form-data` parser, so tests can check what actually
/// goes over the wire. Header names are lowercased.
List<({Map<String, String> headers, List<int> content})> _parseMultipart(
  List<int> body,
  String boundary,
) {
  final chunks = latin1.decode(body).split('--$boundary');
  // chunks.first is the (empty) preamble, chunks.last the closing `--\r\n`.
  return chunks.sublist(1, chunks.length - 1).map(_parsePart).toList();
}

({Map<String, String> headers, List<int> content}) _parsePart(String chunk) {
  final part = chunk.substring(2, chunk.length - 2); // the framing CRLFs
  final separator = part.indexOf('\r\n\r\n');
  final headers = <String, String>{};
  for (final line in part.substring(0, separator).split('\r\n')) {
    final colon = line.indexOf(':');
    headers[line.substring(0, colon).toLowerCase()] = line
        .substring(colon + 1)
        .trim();
  }
  return (
    headers: headers,
    content: latin1.encode(part.substring(separator + 4)),
  );
}

/// One entry per public request method: the endpoint it must hit, a valid
/// response body for it, and how to call it.
final _endpoints =
    <
      ({
        String name,
        String path,
        String method,
        String body,
        Future<Object?> Function(MozhiApiClient client) call,
      })
    >[
      (
        name: 'getEngines',
        path: 'api/engines',
        method: 'GET',
        body: enginesJson,
        call: (c) => c.getEngines(),
      ),
      (
        name: 'getSourceLanguages',
        path: 'api/source_languages',
        method: 'GET',
        body: googleSourceLanguagesJson,
        call: (c) => c.getSourceLanguages('google'),
      ),
      (
        name: 'getTargetLanguages',
        path: 'api/target_languages',
        method: 'GET',
        body: deeplTargetLanguagesJson,
        call: (c) => c.getTargetLanguages('deepl'),
      ),
      (
        name: 'translate',
        path: 'api/translate',
        method: 'POST',
        body: googleTranslationJson,
        call: (c) =>
            c.translate(engine: 'google', from: 'auto', to: 'en', text: '猫'),
      ),
      (
        name: 'translateWithEngines',
        path: 'api/translate',
        method: 'POST',
        body: allEnginesTranslationJson,
        call: (c) => c.translateWithEngines(
          engines: const [],
          from: 'de',
          to: 'en',
          text: 'Guten Morgen',
        ),
      ),
      (
        name: 'textToSpeech',
        path: 'api/tts',
        method: 'GET',
        body: 'ID3 mp3 frames',
        call: (c) =>
            c.textToSpeech(engine: 'google', language: 'en', text: 'cat'),
      ),
      (
        name: 'translateImage',
        path: 'api/image',
        method: 'POST',
        body: imageTranslationJson,
        call: (c) => c.translateImage(
          pngBytes: Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47]),
          from: 'fr',
          to: 'en',
        ),
      ),
      (
        name: 'getVersion',
        path: 'api/version',
        method: 'GET',
        body: versionJson,
        call: (c) => c.getVersion(),
      ),
      (
        name: 'ping',
        path: 'api/version',
        method: 'GET',
        body: versionJson,
        call: (c) => c.ping(),
      ),
    ];

void main() {
  group(MozhiApiClient, () {
    late List<http.Request> requests;

    MozhiApiClient clientReturning(
      http.Response response, {
      Uri? baseUrl,
      Duration timeout = const Duration(seconds: 30),
    }) => MozhiApiClient(
      baseUrl: baseUrl ?? _baseUrl,
      timeout: timeout,
      httpClient: MockClient((request) async {
        requests.add(request);
        return response;
      }),
    );

    setUp(() => requests = []);

    test('waits 30 s for a response by default', () {
      expect(MozhiApiClient.defaultTimeout, const Duration(seconds: 30));
      expect(
        MozhiApiClient(
          baseUrl: _baseUrl,
          httpClient: MockClient((_) async {
            throw UnimplementedError();
          }),
        ).timeout,
        MozhiApiClient.defaultTimeout,
      );
    });

    group('getEngines', () {
      test('GETs /api/engines without the all/some pseudo-engines, '
          'sorted by display name', () async {
        final engines = await clientReturning(_json(enginesJson)).getEngines();

        expect(requests.single.method, 'GET');
        expect(
          requests.single.url,
          Uri.parse('https://mozhi.example/api/engines'),
        );
        expect(engines, isA<LinkedHashMap<String, String>>());
        expect(engines.entries.map((e) => (e.key, e.value)), [
          ('deepl', 'DeepL'),
          ('duckduckgo', 'DuckDuckGo'),
          ('google', 'Google'),
          ('libre', 'LibreTranslate'),
          ('mymemory', 'MyMemory'),
          ('reverso', 'Reverso'),
          ('yandex', 'Yandex'),
        ]);
      });

      test('sorts case-insensitively, breaks ties by id and falls back to '
          'the id for missing names', () async {
        final engines = await clientReturning(
          _json('{"b":"same","a":"Same","z":null,"y":"","c":"apple"}'),
        ).getEngines();

        expect(engines.keys, ['c', 'a', 'b', 'y', 'z']);
        expect(engines['y'], 'y');
        expect(engines['z'], 'z');
      });

      test('throws when the body is not a JSON object', () async {
        await expectLater(
          clientReturning(_json('["google"]')).getEngines(),
          _throwsMozhiError(
            statusCode: null,
            message: 'Unexpected response: expected a JSON object',
            uri: Uri.parse('https://mozhi.example/api/engines'),
          ),
        );
      });
    });

    group('getSourceLanguages', () {
      test('GETs /api/source_languages for the engine', () async {
        final languages = await clientReturning(
          _json(googleSourceLanguagesJson),
        ).getSourceLanguages('google');

        expect(requests.single.method, 'GET');
        expect(
          requests.single.url,
          Uri.parse('https://mozhi.example/api/source_languages?engine=google'),
        );
        expect(languages, const [
          MozhiLanguage(id: 'auto', name: 'Detect Language'),
          MozhiLanguage(id: 'af', name: 'Afrikaans'),
          MozhiLanguage(id: 'zh-CN', name: 'Chinese (Simplified)'),
          MozhiLanguage(id: 'ja', name: 'Japanese'),
          MozhiLanguage(id: 'ta', name: 'Tamil'),
        ]);
      });

      test('returns an empty list for a Go nil slice (null)', () async {
        expect(
          await clientReturning(_json('null')).getSourceLanguages('google'),
          isEmpty,
        );
      });

      test('skips elements that are not objects', () async {
        expect(
          await clientReturning(
            _json('[{"Id":"en","Name":"English"}, "fr", null, 3]'),
          ).getSourceLanguages('google'),
          const [MozhiLanguage(id: 'en', name: 'English')],
        );
      });

      test('throws when the body is not a JSON array', () async {
        await expectLater(
          clientReturning(_json('{"Id":"en"}')).getSourceLanguages('google'),
          _throwsMozhiError(
            statusCode: null,
            message: 'Unexpected response: expected a JSON array',
          ),
        );
      });

      test('surfaces the plain-text error of a disabled engine', () async {
        await expectLater(
          clientReturning(
            _text('Engine does not exist or has been disabled.', 500),
          ).getSourceLanguages('bing'),
          _throwsMozhiError(
            statusCode: 500,
            message: 'Engine does not exist or has been disabled.',
            uri: Uri.parse(
              'https://mozhi.example/api/source_languages?engine=bing',
            ),
          ),
        );
      });
    });

    group('getTargetLanguages', () {
      test('GETs /api/target_languages for the engine', () async {
        final languages = await clientReturning(_json(deeplTargetLanguagesJson))
            .getTargetLanguages('deepl');

        expect(
          requests.single.url,
          Uri.parse('https://mozhi.example/api/target_languages?engine=deepl'),
        );
        expect(languages.map((l) => l.id), ['en-US', 'de', 'pt-BR']);
      });
    });

    group('translate', () {
      test('POSTs a url-encoded form instead of query parameters', () async {
        const text = 'a & b = c?\nLine two: 猫 100% + more';
        await clientReturning(_json(googleTranslationJson))
            .translate(engine: 'google', from: 'auto', to: 'en', text: text);

        final request = requests.single;
        expect(request.method, 'POST');
        expect(request.url, Uri.parse('https://mozhi.example/api/translate'));
        expect(
          request.headers['content-type'],
          startsWith('application/x-www-form-urlencoded'),
        );
        expect(request.bodyFields, {
          'engine': 'google',
          'from': 'auto',
          'to': 'en',
          'text': text,
        });
      });

      test('parses a Google response with dictionary data', () async {
        final translation = await clientReturning(_json(googleTranslationJson))
            .translate(engine: 'google', from: 'auto', to: 'en', text: '猫');

        expect(translation.engine, 'google');
        expect(translation.translatedText, 'cat');
        expect(translation.detectedLanguage, 'ja');
        expect(translation.sourceTransliteration, 'Neko');
        expect(translation.wordChoices, hasLength(2));
        expect(translation.targetSynonyms, contains('kitty'));
        expect(translation.targetEquivalentSourceLang, {
          'cat': ['猫', 'ネコ', 'にゃんこ'],
        });
      });

      test('parses a DeepL response full of nulls', () async {
        final translation = await clientReturning(_json(deeplTranslationJson))
            .translate(engine: 'deepl', from: 'de', to: 'en-US', text: 'x');

        expect(translation.translatedText, 'Good morning, how are you?');
        expect(translation.wordChoices, isEmpty);
        expect(translation.sourceEquivalentTargetLang, isEmpty);
      });

      test(
        'takes the first result if the instance answers with an array',
        () async {
          final translation = await clientReturning(
            _json(allEnginesTranslationJson),
          ).translate(engine: 'deepl', from: 'de', to: 'en', text: 'x');

          expect(translation.engine, 'deepl');
        },
      );

      for (final body in ['[]', 'null']) {
        test('throws when the body ($body) holds no translation', () async {
          await expectLater(
            clientReturning(_json(body))
                .translate(engine: 'google', from: 'auto', to: 'en', text: 'x'),
            _throwsMozhiError(
              statusCode: null,
              message: 'google returned no translation',
              uri: Uri.parse('https://mozhi.example/api/translate'),
            ),
          );
        });
      }

      test('surfaces the 400 for missing parameters', () async {
        await expectLater(
          clientReturning(
            _text('from, to, engine, text are required query strings.\n', 400),
          ).translate(engine: '', from: 'auto', to: 'en', text: 'x'),
          _throwsMozhiError(
            statusCode: 400,
            message: 'from, to, engine, text are required query strings.',
          ),
        );
      });
    });

    group('translateWithEngines', () {
      test(
        'sends engine=all for an empty list and keeps response order',
        () async {
          final translations =
              await clientReturning(_json(allEnginesTranslationJson))
                  .translateWithEngines(
                    engines: [],
                    from: 'auto',
                    to: 'en',
                    text: 'x',
                  );

          expect(requests.single.method, 'POST');
          expect(requests.single.bodyFields['engine'], 'all');
          expect(translations.map((t) => t.engine), [
            'deepl',
            'libre',
            'google',
          ]);
          expect(translations[1].detectedLanguage, isEmpty);
          expect(translations[2].detectedLanguage, 'de');
        },
      );

      test('joins engine ids with commas', () async {
        await clientReturning(_json(allEnginesTranslationJson))
            .translateWithEngines(
              engines: ['google', 'deepl', 'libre'],
              from: 'de',
              to: 'en',
              text: 'Guten Morgen',
            );

        expect(requests.single.bodyFields, {
          'engine': 'google,deepl,libre',
          'from': 'de',
          'to': 'en',
          'text': 'Guten Morgen',
        });
      });

      test('wraps a single-object response in a list', () async {
        final translations =
            await clientReturning(_json(reversoTranslationJson))
                .translateWithEngines(
                  engines: ['reverso'],
                  from: 'fr',
                  to: 'en',
                  text: 'maison',
                );

        expect(translations.single.engine, 'reverso');
        expect(translations.single.translatedText, 'house');
      });

      test('returns an empty list when every engine failed (null)', () async {
        expect(
          await clientReturning(_json('null')).translateWithEngines(
            engines: ['google', 'deepl'],
            from: 'auto',
            to: 'en',
            text: 'x',
          ),
          isEmpty,
        );
      });

      test('skips array elements that are not objects', () async {
        final translations = await clientReturning(
          _json('[null, {"engine":"libre","translated-text":"Hi"}, "x"]'),
        ).translateWithEngines(engines: [], from: 'auto', to: 'en', text: 'x');

        expect(translations.single.translatedText, 'Hi');
      });

      test('throws for a body that is neither object nor array', () async {
        await expectLater(
          clientReturning(_json('"Hello"')).translateWithEngines(
            engines: [],
            from: 'auto',
            to: 'en',
            text: 'x',
          ),
          _throwsMozhiError(
            statusCode: null,
            message: 'Unexpected response: expected a JSON array',
          ),
        );
      });
    });

    group('textToSpeech', () {
      final mp3 = Uint8List.fromList(const [0x49, 0x44, 0x33, 4, 0, 0, 1, 2]);

      test('GETs /api/tts with encoded query parameters and returns the '
          'audio bytes', () async {
        final audio =
            await clientReturning(
              http.Response.bytes(
                mp3,
                200,
                headers: {'content-type': 'audio/mpeg'},
              ),
            ).textToSpeech(
              engine: 'reverso',
              language: 'fr',
              text: 'Ça va & toi? 100% + oui',
            );

        expect(audio, mp3);
        final url = requests.single.url;
        expect(requests.single.method, 'GET');
        expect(url.path, '/api/tts');
        expect(url.queryParameters, {
          'engine': 'reverso',
          'lang': 'fr',
          'text': 'Ça va & toi? 100% + oui',
        });
        expect(
          url.query,
          'engine=reverso&lang=fr&text=%C3%87a+va+%26+toi%3F+100%25+%2B+oui',
        );
      });

      test('throws when the body is empty', () async {
        await expectLater(
          clientReturning(http.Response.bytes(const [], 200))
              .textToSpeech(engine: 'google', language: 'en', text: 'cat'),
          _throwsMozhiError(
            statusCode: null,
            message: 'google returned no audio',
            uri: Uri.parse(
              'https://mozhi.example/api/tts?engine=google&lang=en&text=cat',
            ),
          ),
        );
      });

      test('throws for engines without TTS', () async {
        await expectLater(
          clientReturning(_text('Engine does not support TTS', 500))
              .textToSpeech(engine: 'deepl', language: 'en', text: 'cat'),
          _throwsMozhiError(
            statusCode: 500,
            message: 'Engine does not support TTS',
          ),
        );
      });
    });

    group('translateImage', () {
      final png = Uint8List.fromList(const [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF, 0x0D, //
      ]);
      late http.BaseRequest sent;
      late List<int> sentBody;

      MozhiApiClient imageClient(String body, {int status = 200}) =>
          MozhiApiClient(
            baseUrl: _baseUrl,
            httpClient: MockClient.streaming((request, bodyStream) async {
              sent = request;
              sentBody = await bodyStream.toBytes();
              return http.StreamedResponse(
                Stream.value(utf8.encode(body)),
                status,
              );
            }),
          );

      test('POSTs a multipart form whose image part is image/png', () async {
        await imageClient(imageTranslationJson)
            .translateImage(pngBytes: png, from: 'fr', to: 'en', engine: 'x');

        expect(sent.method, 'POST');
        expect(sent.url, Uri.parse('https://mozhi.example/api/image'));
        final contentType = MediaType.parse(sent.headers['content-type']!);
        expect(contentType.mimeType, 'multipart/form-data');

        final request = sent as http.MultipartRequest;
        expect(request.fields, {'engine': 'x', 'from': 'fr', 'to': 'en'});
        final file = request.files.single;
        expect(file.field, 'image');
        expect(file.filename, 'image.png');
        expect(file.contentType.mimeType, 'image/png');

        final parts = _parseMultipart(
          sentBody,
          contentType.parameters['boundary']!,
        );
        final image = parts.singleWhere(
          (p) => p.headers['content-disposition']!.contains('name="image"'),
        );
        expect(
          image.headers['content-disposition'],
          'form-data; name="image"; filename="image.png"',
        );
        expect(image.headers['content-type'], 'image/png');
        expect(image.content, png);
        expect(
          {
            for (final part in parts.where((p) => p != image))
              part.headers['content-disposition']!: utf8.decode(part.content),
          },
          {
            'form-data; name="engine"': 'x',
            'form-data; name="from"': 'fr',
            'form-data; name="to"': 'en',
          },
        );
      });

      test('defaults to the google engine and parses ImgOut', () async {
        final result = await imageClient(imageTranslationJson)
            .translateImage(pngBytes: png, from: 'fr', to: 'en');

        expect((sent as http.MultipartRequest).fields['engine'], 'google');
        expect(result.translatedText, 'Emergency exit');
        expect(result.sourceText, 'Sortie de secours');
        expect(result.translatedImageBase64, startsWith('iVBORw0KGgo'));
      });

      test('surfaces server errors', () async {
        await expectLater(
          imageClient(
            'Image must be PNG',
            status: 400,
          ).translateImage(pngBytes: png, from: 'fr', to: 'en'),
          _throwsMozhiError(statusCode: 400, message: 'Image must be PNG'),
        );
      });

      test('throws when the body is not a JSON object', () async {
        await expectLater(
          imageClient('[]').translateImage(pngBytes: png, from: 'a', to: 'b'),
          _throwsMozhiError(
            statusCode: null,
            message: 'Unexpected response: expected a JSON object',
          ),
        );
      });

      group('timeout', () {
        MozhiApiClient slowClient(Duration delay) => MozhiApiClient(
          baseUrl: _baseUrl,
          timeout: const Duration(milliseconds: 20),
          httpClient: MockClient(
            (request) => Future.delayed(
              delay,
              () => http.Response(imageTranslationJson, 200),
            ),
          ),
        );

        test('can be longer than the client timeout', () async {
          final result = await slowClient(const Duration(milliseconds: 60))
              .translateImage(
                pngBytes: png,
                from: 'fr',
                to: 'en',
                timeout: const Duration(seconds: 5),
              );
          expect(result.translatedText, 'Emergency exit');
        });

        test('replaces the client timeout in the error', () async {
          await expectLater(
            slowClient(const Duration(milliseconds: 300)).translateImage(
              pngBytes: png,
              from: 'fr',
              to: 'en',
              timeout: const Duration(milliseconds: 30),
            ),
            _throwsMozhiError(
              statusCode: null,
              message: 'No response within 30 ms',
            ),
          );
        });

        test('defaults to the client timeout', () async {
          await expectLater(
            slowClient(const Duration(milliseconds: 300))
                .translateImage(pngBytes: png, from: 'fr', to: 'en'),
            _throwsMozhiError(
              statusCode: null,
              message: 'No response within 20 ms',
            ),
          );
        });
      });
    });

    group('getVersion', () {
      test('GETs /api/version', () async {
        final version = await clientReturning(_json(versionJson)).getVersion();

        expect(
          requests.single.url,
          Uri.parse('https://mozhi.example/api/version'),
        );
        expect(version.fiberVersion, 'v2.52.5');
        expect(version.goVersion, 'go1.23.1');
      });

      test('throws for a null body', () async {
        await expectLater(
          clientReturning(_json('null')).getVersion(),
          _throwsMozhiError(statusCode: null),
        );
      });
    });

    group('ping', () {
      test('measures a request to /api/version', () async {
        final latency = await clientReturning(_json(versionJson)).ping();

        expect(requests.single.url.path, '/api/version');
        expect(latency, greaterThanOrEqualTo(Duration.zero));
      });

      test('throws when the instance is unhealthy', () async {
        await expectLater(
          clientReturning(_text('', 503, reasonPhrase: 'Unavailable')).ping(),
          _throwsMozhiError(statusCode: 503, message: 'Unavailable'),
        );
      });
    });

    group('for every endpoint', () {
      for (final endpoint in _endpoints) {
        group(endpoint.name, () {
          MozhiApiClient client(
            Future<http.Response> Function() respond, {
            Uri? baseUrl,
            Duration timeout = const Duration(seconds: 30),
          }) => MozhiApiClient(
            baseUrl: baseUrl ?? _baseUrl,
            timeout: timeout,
            httpClient: MockClient((request) {
              requests.add(request);
              return respond();
            }),
          );

          for (final base in [
            'http://192.168.1.10:3000/mozhi',
            'http://192.168.1.10:3000/mozhi/',
            'http://192.168.1.10:3000/mozhi?unused=1#fragment',
          ]) {
            test('keeps the sub-path of $base', () async {
              await endpoint.call(
                client(
                  () async => _json(endpoint.body),
                  baseUrl: Uri.parse(base),
                ),
              );

              final url = requests.single.url;
              expect(requests.single.method, endpoint.method);
              expect(url.origin, 'http://192.168.1.10:3000');
              expect(url.path, '/mozhi/${endpoint.path}');
              expect(url.hasFragment, isFalse);
              expect(url.queryParameters, isNot(contains('unused')));
            });
          }

          test('keeps an IPv6 host and sends user info as a decoded basic '
              'Authorization header instead of in the URL', () async {
            await endpoint.call(
              client(
                () async => _json(endpoint.body),
                baseUrl: Uri.parse(
                  'http://me:p%40ss%20w%C3%B6rd@[fd00::5]:8080',
                ),
              ),
            );

            final request = requests.single;
            expect(request.url.userInfo, isEmpty);
            expect(request.url.host, 'fd00::5');
            expect(request.url.port, 8080);
            expect(request.url.path, '/${endpoint.path}');
            expect(request.headers['authorization'], _basic('me:p@ss wörd'));
          });

          test('sends no Authorization header without user info', () async {
            await endpoint.call(client(() async => _json(endpoint.body)));

            expect(requests.single.headers, isNot(contains('authorization')));
          });

          test('aborts the request when the timeout runs out', () async {
            final aborted = Completer<void>();
            final abortable = MozhiApiClient(
              baseUrl: _baseUrl,
              timeout: const Duration(milliseconds: 5),
              httpClient: MockClient.streaming((request, _) async {
                // Like IOClient/BrowserClient: fail once the trigger fires.
                await (request as http.Abortable).abortTrigger;
                aborted.complete();
                throw http.RequestAbortedException(request.url);
              }),
            );

            await expectLater(
              endpoint.call(abortable),
              _throwsMozhiError(
                statusCode: null,
                message: 'No response within 5 ms',
              ),
            );
            await aborted.future;
          });

          test('does not abort a request that succeeded', () async {
            var triggered = false;
            await endpoint.call(
              MozhiApiClient(
                baseUrl: _baseUrl,
                timeout: const Duration(milliseconds: 50),
                httpClient: MockClient.streaming((request, body) async {
                  final trigger = (request as http.Abortable).abortTrigger!;
                  unawaited(trigger.then((_) => triggered = true));
                  await body.drain<void>();
                  return http.StreamedResponse(
                    Stream.value(utf8.encode(endpoint.body)),
                    200,
                  );
                }),
              ),
            );

            await Future<void>.delayed(const Duration(milliseconds: 100));
            expect(triggered, isFalse);
          });

          test('times out after the configured timeout', () async {
            await expectLater(
              endpoint.call(
                client(
                  () => Future.delayed(
                    const Duration(milliseconds: 300),
                    () => _json(endpoint.body),
                  ),
                  timeout: const Duration(milliseconds: 5),
                ),
              ),
              _throwsMozhiError(
                statusCode: null,
                message: 'No response within 5 ms',
                uri: isA<Uri>().having(
                  (u) => u.path,
                  'path',
                  '/${endpoint.path}',
                ),
              ),
            );
          });

          test('maps transport failures to a retryable exception', () async {
            await expectLater(
              endpoint.call(
                client(
                  () => throw http.ClientException(
                    "Failed host lookup: 'mozhi.example'",
                  ),
                ),
              ),
              throwsA(
                isA<MozhiApiException>()
                    .having((e) => e.statusCode, 'statusCode', isNull)
                    .having(
                      (e) => e.message,
                      'message',
                      "Failed host lookup: 'mozhi.example'",
                    )
                    .having((e) => e.isRetryable, 'isRetryable', isTrue),
              ),
            );
          });

          test('maps HTTP errors with their status code', () async {
            await expectLater(
              endpoint.call(
                client(() async => _text('Too many requests', 429)),
              ),
              _throwsMozhiError(statusCode: 429, message: 'Too many requests'),
            );
          });
        });
      }
    });

    group('error handling', () {
      final versionUri = Uri.parse('https://mozhi.example/api/version');

      final httpErrors =
          <({String description, http.Response response, String message})>[
            (
              description: 'trimmed plain-text body',
              response: _text('  Engine does not exist.\n', 500),
              message: 'Engine does not exist.',
            ),
            (
              description: 'Fiber 404 for a missing route',
              response: _text('Cannot GET /api/version', 404),
              message: 'Cannot GET /api/version',
            ),
            (
              description: 'reason phrase for an empty body',
              response: _text('', 503, reasonPhrase: ' Service Unavailable '),
              message: 'Service Unavailable',
            ),
            (
              description: 'status code without body or reason phrase',
              response: _text('  ', 502),
              message: 'HTTP 502',
            ),
            (
              description: 'JSON "error" field',
              response: _json('{"error":"Rate limited"}', status: 429),
              message: 'Rate limited',
            ),
            (
              description: 'JSON "message" field',
              response: _json('{"message":" Text too long "}', status: 413),
              message: 'Text too long',
            ),
            (
              description: 'JSON "detail" field',
              response: _json('{"detail":"Nope"}', status: 403),
              message: 'Nope',
            ),
            (
              description: 'nested JSON error object',
              response: _json(
                '{"error":{"code":5,"message":"Upstream failed"}}',
                status: 500,
              ),
              message: 'Upstream failed',
            ),
            (
              description: 'JSON string body',
              response: _json('"Bad engine"', status: 400),
              message: 'Bad engine',
            ),
            (
              description: 'reason phrase for JSON without a message',
              response: _text(
                '{"code":5,"error":"   "}',
                500,
                reasonPhrase: 'Internal Server Error',
              ),
              message: 'Internal Server Error',
            ),
            (
              description: 'reason phrase instead of an HTML error page',
              response: _text(
                'Bad gateway<hr><center>nginx</center>',
                502,
                reasonPhrase: 'Bad Gateway',
                headers: {'content-type': 'text/html; charset=utf-8'},
              ),
              message: 'Bad Gateway',
            ),
            (
              description: 'status code instead of untyped markup',
              response: _text('<!DOCTYPE html><title>Oops</title>', 504),
              message: 'HTTP 504',
            ),
            (
              description:
                  'target of a redirect that is not followed '
                  '(https to http)',
              response: _text(
                '',
                303,
                headers: {'location': 'http://mozhi.example/other'},
              ),
              message: 'Redirected to http://mozhi.example/other',
            ),
            (
              description: 'body of a redirect without a location',
              response: _text('Found', 302),
              message: 'Found',
            ),
            (
              description: 'malformed UTF-8 without failing',
              response: http.Response.bytes(const [
                0x42,
                0x61,
                0xFF,
                0x64,
              ], 400),
              message: 'Ba�d',
            ),
          ];

      for (final (:description, :response, :message) in httpErrors) {
        test('uses the $description', () async {
          await expectLater(
            clientReturning(response).getVersion(),
            _throwsMozhiError(
              statusCode: response.statusCode,
              message: message,
              uri: versionUri,
            ),
          );
        });
      }

      test(
        'treats a 2xx body that is not JSON as a transport failure',
        () async {
          await expectLater(
            clientReturning(_text('<html>Captive portal</html>', 200))
                .getVersion(),
            throwsA(
              isA<MozhiApiException>()
                  .having((e) => e.statusCode, 'statusCode', isNull)
                  .having(
                    (e) => e.message,
                    'message',
                    startsWith('Invalid JSON response'),
                  )
                  .having((e) => e.uri, 'uri', versionUri)
                  .having((e) => e.isRetryable, 'isRetryable', isTrue),
            ),
          );
        },
      );

      test('accepts any 2xx status', () async {
        final version = await clientReturning(_json(versionJson, status: 203))
            .getVersion();

        expect(version.goVersion, 'go1.23.1');
      });

      test('decodes UTF-8 even without a charset', () async {
        final languages = await clientReturning(
          http.Response.bytes(
            utf8.encode('[{"Id":"ta","Name":"தமிழ்"}]'),
            200,
            headers: {'content-type': 'text/plain'},
          ),
        ).getSourceLanguages('google');

        expect(languages.single.name, 'தமிழ்');
      });

      test('describes a ClientException without a message', () async {
        final client = MozhiApiClient(
          baseUrl: _baseUrl,
          httpClient: MockClient((_) => throw http.ClientException('')),
        );

        await expectLater(
          client.getVersion(),
          _throwsMozhiError(
            statusCode: null,
            message: startsWith('ClientException'),
            uri: versionUri,
          ),
        );
      });

      test('maps other exceptions thrown by the client', () async {
        final client = MozhiApiClient(
          baseUrl: _baseUrl,
          httpClient: MockClient((_) => throw Exception('Connection reset')),
        );

        await expectLater(
          client.getVersion(),
          _throwsMozhiError(
            statusCode: null,
            message: 'Exception: Connection reset',
          ),
        );
      });

      test('keeps the original stack trace', () async {
        final client = MozhiApiClient(
          baseUrl: _baseUrl,
          httpClient: MockClient((_) => throw http.ClientException('down')),
        );

        try {
          await client.getVersion();
          fail('getVersion should throw');
        } on MozhiApiException catch (_, stackTrace) {
          expect(stackTrace.toString(), contains('mozhi_api_client_test.dart'));
        }
      });
    });

    group('credentials', () {
      const cases = {
        'https://token@mozhi.example': 'token:',
        'https://me:@mozhi.example': 'me:',
        'https://me:a%3Ab:c@mozhi.example': 'me:a:b:c',
        // Escapes that are not UTF-8 are sent as typed.
        'https://me:%FF%25@mozhi.example': 'me:%FF%25',
      };
      for (final MapEntry(key: base, value: credentials) in cases.entries) {
        test('sends "$credentials" for $base', () async {
          await clientReturning(
            _json(versionJson),
            baseUrl: Uri.parse(base),
          ).getVersion();

          expect(requests.single.headers['authorization'], _basic(credentials));
          expect(
            requests.single.url,
            Uri.parse('https://mozhi.example/api/version'),
          );
        });
      }
    });

    group('redirects', () {
      final httpTranslate = Uri.parse('http://mozhi.example/api/translate');
      final httpsTranslate = Uri.parse('https://mozhi.example/api/translate');
      const form = {
        'engine': 'google',
        'from': 'auto',
        'to': 'en',
        'text': 'a & b = c?',
      };

      http.Response redirect(int status, String location) =>
          _text('', status, headers: {'location': location});

      /// Answers the requests in order with [responses].
      MozhiApiClient clientAnswering(
        List<http.Response> responses, {
        Uri? baseUrl,
      }) {
        final queue = Queue.of(responses);
        return MozhiApiClient(
          baseUrl: baseUrl ?? _baseUrl,
          httpClient: MockClient((request) async {
            requests.add(request);
            return queue.removeFirst();
          }),
        );
      }

      Future<MozhiTranslation> translate(MozhiApiClient client) =>
          client.translate(
            engine: form['engine']!,
            from: form['from']!,
            to: form['to']!,
            text: form['text']!,
          );

      for (final status in [301, 302, 307, 308]) {
        test('re-POSTs the same form to the Location of a $status', () async {
          final translation = await translate(
            clientAnswering([
              redirect(status, httpsTranslate.toString()),
              _json(googleTranslationJson),
            ], baseUrl: Uri.parse('http://mozhi.example')),
          );

          expect(translation.translatedText, 'cat');
          expect(requests.map((r) => (r.method, r.url)), [
            ('POST', httpTranslate),
            ('POST', httpsTranslate),
          ]);
          for (final request in requests) {
            expect(request.followRedirects, isFalse);
            expect(
              request.headers['content-type'],
              startsWith('application/x-www-form-urlencoded'),
            );
            expect(request.bodyFields, form);
          }
        });
      }

      test('follows redirects for translateWithEngines', () async {
        final translations =
            await clientAnswering([
              redirect(308, 'https://mozhi.example/v2/api/translate'),
              _json(allEnginesTranslationJson),
            ]).translateWithEngines(
              engines: ['google', 'deepl'],
              from: 'de',
              to: 'en',
              text: 'Guten Morgen',
            );

        expect(translations, hasLength(3));
        expect(requests.last.url.path, '/v2/api/translate');
        expect(requests.last.bodyFields['engine'], 'google,deepl');
      });

      test('resolves relative Locations against the redirected URL and '
          'drops fragments', () async {
        await translate(
          clientAnswering([
            redirect(307, '/mozhi/api/translate'),
            redirect(308, '//mirror.example:8443/api/translate#top'),
            _json(googleTranslationJson),
          ]),
        );

        expect(requests.map((r) => r.url), [
          httpsTranslate,
          Uri.parse('https://mozhi.example/mozhi/api/translate'),
          Uri.parse('https://mirror.example:8443/api/translate'),
        ]);
      });

      test('re-sends the image and fields of translateImage', () async {
        final png = Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47, 0, 9]);
        final sent = <(http.BaseRequest, List<int>)>[];
        final client = MozhiApiClient(
          baseUrl: Uri.parse('http://mozhi.example'),
          httpClient: MockClient.streaming((request, body) async {
            sent.add((request, await body.toBytes()));
            return sent.length == 1
                ? http.StreamedResponse(
                    const Stream.empty(),
                    301,
                    headers: {'location': 'https://mozhi.example/api/image'},
                  )
                : http.StreamedResponse(
                    Stream.value(utf8.encode(imageTranslationJson)),
                    200,
                  );
          }),
        );

        final result = await client.translateImage(
          pngBytes: png,
          from: 'fr',
          to: 'en',
        );

        expect(result.translatedText, 'Emergency exit');
        expect(sent.map((s) => s.$1.url.toString()), [
          'http://mozhi.example/api/image',
          'https://mozhi.example/api/image',
        ]);
        for (final (request, body) in sent) {
          expect(request.method, 'POST');
          expect(request.followRedirects, isFalse);
          final multipart = request as http.MultipartRequest;
          expect(multipart.fields, {
            'engine': 'google',
            'from': 'fr',
            'to': 'en',
          });
          final boundary = MediaType.parse(request.headers['content-type']!)
              .parameters['boundary']!;
          final image = _parseMultipart(body, boundary).singleWhere(
            (p) => p.headers['content-disposition']!.contains('name="image"'),
          );
          expect(image.content, png);
          expect(image.headers['content-type'], 'image/png');
        }
      });

      test('follows a GET redirect that the client did not follow', () async {
        final version = await clientAnswering([
          redirect(301, 'https://mozhi.example/v2/api/version'),
          _json(versionJson),
        ]).getVersion();

        expect(version.goVersion, 'go1.23.1');
        // Followed here (not by dart:io), so every hop is checked.
        expect(requests.first.followRedirects, isFalse);
        expect(requests.last.url.path, '/v2/api/version');
      });

      test('never follows a redirect from https to http', () async {
        await expectLater(
          translate(clientAnswering([redirect(301, httpTranslate.toString())])),
          throwsA(
            isA<MozhiApiException>()
                .having((e) => e.statusCode, 'statusCode', 301)
                .having(
                  (e) => e.message,
                  'message',
                  'Redirected to $httpTranslate',
                )
                .having((e) => e.uri, 'uri', httpsTranslate)
                .having((e) => e.isRetryable, 'isRetryable', isTrue),
          ),
        );
        expect(requests, hasLength(1));
      });

      for (final location in [
        'ftp://mozhi.example/api/translate',
        'http://[::1',
      ]) {
        test('does not follow the Location $location', () async {
          await expectLater(
            translate(clientAnswering([redirect(308, location)])),
            _throwsMozhiError(
              statusCode: 308,
              message: 'Redirected to $location',
              uri: httpsTranslate,
            ),
          );
          expect(requests, hasLength(1));
        });
      }

      test('does not follow a redirect with a blank Location', () async {
        await expectLater(
          translate(
            clientAnswering([
              _text(
                '',
                307,
                reasonPhrase: 'Temporary Redirect',
                headers: {'location': '  '},
              ),
            ]),
          ),
          _throwsMozhiError(statusCode: 307, message: 'Temporary Redirect'),
        );
        expect(requests, hasLength(1));
      });

      test('does not turn a POST into a GET without the form on 303', () async {
        await expectLater(
          translate(
            clientAnswering([redirect(303, 'https://mozhi.example/result')]),
          ),
          _throwsMozhiError(
            statusCode: 303,
            message: 'Redirected to https://mozhi.example/result',
          ),
        );
        expect(requests, hasLength(1));
      });

      test('gives up after ${MozhiApiClient.maxRedirects} redirects', () async {
        const hops = MozhiApiClient.maxRedirects;
        await expectLater(
          translate(
            clientAnswering([
              for (var hop = 1; hop <= hops + 1; hop++)
                redirect(302, 'https://mozhi.example/hop$hop'),
            ]),
          ),
          _throwsMozhiError(
            statusCode: 302,
            message: 'Redirected to https://mozhi.example/hop${hops + 1}',
            uri: Uri.parse('https://mozhi.example/hop$hops'),
          ),
        );
        expect(requests, hasLength(hops + 1));
      });

      test('reports the final URL when the redirected request fails', () async {
        final target = Uri.parse('https://mozhi.example/v2/api/translate');

        await expectLater(
          translate(
            clientAnswering([
              redirect(308, target.toString()),
              _text('Engine does not exist or has been disabled.', 500),
            ]),
          ),
          _throwsMozhiError(statusCode: 500, uri: target),
        );
        requests.clear();
        await expectLater(
          translate(
            clientAnswering([redirect(308, target.toString()), _json('[]')]),
          ),
          _throwsMozhiError(
            statusCode: null,
            message: 'google returned no translation',
            uri: target,
          ),
        );
      });

      test('sends credentials only to the origin of the base URL and never '
          'puts them in a URL', () async {
        await translate(
          clientAnswering([
            redirect(307, '/moved/api/translate'),
            redirect(308, 'https://mozhi.example/api/translate'),
            redirect(308, 'https://evil:creds@cdn.example/api/translate'),
            _json(googleTranslationJson),
          ], baseUrl: Uri.parse('http://me:secret@mozhi.example')),
        );

        expect(requests.map((r) => r.headers['authorization']), [
          _basic('me:secret'),
          _basic('me:secret'),
          null,
          null,
        ]);
        expect(requests.map((r) => r.url.userInfo), everyElement(isEmpty));
        expect(requests.last.url.host, 'cdn.example');
      });

      test(
        'applies one timeout to every hop and reports the last URL',
        () async {
          final client = MozhiApiClient(
            baseUrl: _baseUrl,
            timeout: const Duration(milliseconds: 20),
            httpClient: MockClient((request) {
              requests.add(request);
              return requests.length == 1
                  ? Future.value(redirect(307, '/v2/api/translate'))
                  : Completer<http.Response>().future; // never answers
            }),
          );

          await expectLater(
            translate(client),
            _throwsMozhiError(
              statusCode: null,
              message: 'No response within 20 ms',
              uri: Uri.parse('https://mozhi.example/v2/api/translate'),
            ),
          );
          expect(requests, hasLength(2));
        },
      );

      test(
        'does not follow a redirect that arrives after the timeout',
        () async {
          final answer = Completer<http.Response>();
          final client = MozhiApiClient(
            baseUrl: _baseUrl,
            timeout: const Duration(milliseconds: 5),
            httpClient: MockClient((request) {
              requests.add(request);
              return answer.future;
            }),
          );

          await expectLater(
            translate(client),
            _throwsMozhiError(
              statusCode: null,
              message: 'No response within 5 ms',
            ),
          );
          answer.complete(redirect(308, '/v2/api/translate'));
          await pumpEventQueue();

          expect(requests, hasLength(1));
        },
      );
    });

    group('close', () {
      test('does not close an injected client', () {
        final httpClient = _MockHttpClient();

        MozhiApiClient(baseUrl: _baseUrl, httpClient: httpClient).close();

        verifyNever(httpClient.close);
      });

      test('closes the client it created', () async {
        final client = MozhiApiClient(baseUrl: _baseUrl)..close();

        // A closed IOClient refuses to send, without touching the network.
        await expectLater(
          client.getVersion(),
          _throwsMozhiError(
            statusCode: null,
            uri: Uri.parse('https://mozhi.example/api/version'),
          ),
        );
      });
    });
  });
}
