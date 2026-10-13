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
          ).translate(engine: 'google', from: 'auto', to: 'en', text: ''),
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

          test('keeps user info and an IPv6 host', () async {
            await endpoint.call(
              client(
                () async => _json(endpoint.body),
                baseUrl: Uri.parse('http://me:secret@[fd00::5]:8080'),
              ),
            );

            final url = requests.single.url;
            expect(url.userInfo, 'me:secret');
            expect(url.host, 'fd00::5');
            expect(url.port, 8080);
            expect(url.path, '/${endpoint.path}');
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
              description: 'redirect target (POST redirects are not followed)',
              response: _text(
                '',
                301,
                headers: {'location': 'https://mozhi.example/api/version'},
              ),
              message: 'Redirected to https://mozhi.example/api/version',
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
