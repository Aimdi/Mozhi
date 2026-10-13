import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mt_api/mt_api.dart';
import 'package:test/test.dart';

import '../helpers.dart';

class _MockHttpClient extends Mock implements http.Client {}

final Uri _base = Uri.parse('https://translate.example.org');

const _translation = '''
{"alternatives":["Hi there!","Hey!"],
 "detectedLanguage":{"confidence":90.0,"language":"fr"},
 "translatedText":"Hello!"}''';

const _languages = '''
[{"code":"en","name":"English","targets":["en","fr","zh-Hans","zh-Hant"]},
 {"code":"zh-Hans","name":"Chinese (Simplified)","targets":["en"]},
 {"code":"pb","name":"Portuguese (Brazil)"},
 42]''';

void main() {
  group(LibreTranslateClient, () {
    late RecordingClient http_;
    late LibreTranslateClient client;
    late http.Response Function(http.Request) respond;

    setUp(() {
      respond = (_) => jsonResponse(_translation);
      http_ = RecordingClient((request) => respond(request));
      client = LibreTranslateClient(
        baseUrl: _base,
        apiKey: ' secret ',
        httpClient: http_,
      );
    });

    test('trims the key and treats a blank key as none', () {
      expect(client.apiKey, 'secret');
      expect(LibreTranslateClient(baseUrl: _base, apiKey: '  ').apiKey, isNull);
      expect(LibreTranslateClient(baseUrl: _base).apiKey, isNull);
    });

    group('translate', () {
      test('posts JSON and parses the result', () async {
        final result = await client.translate(
          text: 'Bonjour !',
          target: 'en',
          alternatives: 2,
        );
        final request = http_.single;
        expect(request.method, 'POST');
        expect(
          request.url.toString(),
          'https://translate.example.org/translate',
        );
        expect(
          request.headers['content-type'],
          'application/json; charset=utf-8',
        );
        expect(request.headers['accept'], 'application/json');
        expect(request.headers.containsKey('authorization'), isFalse);
        expect(http_.singleJsonBody, {
          'q': 'Bonjour !',
          'source': 'auto',
          'target': 'en',
          'format': 'text',
          'alternatives': 2,
          'api_key': 'secret',
        });
        expect(
          result,
          const LibreTranslation(
            text: 'Hello!',
            detectedLanguage: LibreDetectedLanguage(code: 'fr', confidence: 90),
            alternatives: ['Hi there!', 'Hey!'],
          ),
        );
      });

      test('sends an explicit source and format, no key', () async {
        respond = (_) => jsonResponse('{"translatedText":"<b>Hallo</b>"}');
        final keyless = LibreTranslateClient(baseUrl: _base, httpClient: http_);
        final result = await keyless.translate(
          text: '<b>Hello</b>',
          source: ' en ',
          target: ' de ',
          format: LibreFormat.html,
        );
        expect(http_.singleJsonBody, {
          'q': '<b>Hello</b>',
          'source': 'en',
          'target': 'de',
          'format': 'html',
        });
        expect(result.text, '<b>Hallo</b>');
        expect(result.detectedLanguage, isNull);
        expect(result.alternatives, isEmpty);
      });

      test('an empty source means auto', () async {
        await client.translate(text: 'x', source: ' ', target: 'en');
        expect((http_.singleJsonBody! as Map)['source'], 'auto');
      });

      test('rejects a response without translatedText', () {
        respond = (_) => jsonResponse('{"translatedText":["a"]}');
        expect(
          client.translate(text: 'x', target: 'en'),
          throwsMtError<LibreTranslateException>(
            kind: MtErrorKind.invalidResponse,
            message: 'Unexpected response from LibreTranslate.',
            detail: 'missing translatedText',
          ),
        );
      });

      test('cancels when the abort trigger completes', () async {
        final hanging = HangingClient();
        final cancellable = LibreTranslateClient(
          baseUrl: _base,
          httpClient: hanging,
        );
        final abort = Completer<void>();
        final future = cancellable.translate(
          text: 'x',
          target: 'en',
          abortTrigger: abort.future,
        );
        abort.complete();
        await expectLater(
          future,
          throwsMtError<LibreTranslateException>(kind: MtErrorKind.cancelled),
        );
      });
    });

    group('translateBatch', () {
      test('posts a list q and zips the parallel lists', () async {
        respond = (_) => jsonResponse('''
{"translatedText":["Hello","World"],
 "detectedLanguage":[{"confidence":80,"language":"fr"},
                     {"confidence":70,"language":"fr"}],
 "alternatives":[["Hi"],[]]}''');
        final results = await client.translateBatch(
          texts: const ['Bonjour', 'Monde'],
          target: 'en',
          alternatives: 1,
        );
        expect(http_.singleJsonBody, {
          'q': ['Bonjour', 'Monde'],
          'source': 'auto',
          'target': 'en',
          'format': 'text',
          'alternatives': 1,
          'api_key': 'secret',
        });
        expect(results, const [
          LibreTranslation(
            text: 'Hello',
            detectedLanguage: LibreDetectedLanguage(code: 'fr', confidence: 80),
            alternatives: ['Hi'],
          ),
          LibreTranslation(
            text: 'World',
            detectedLanguage: LibreDetectedLanguage(code: 'fr', confidence: 70),
          ),
        ]);
      });

      test('works without detection and alternatives', () async {
        respond = (_) => jsonResponse('{"translatedText":["a","b"]}');
        final results = await client.translateBatch(
          texts: const ['x', 'y'],
          source: 'de',
          target: 'en',
          format: LibreFormat.html,
        );
        expect(results.map((r) => r.text), ['a', 'b']);
        expect(results.every((r) => r.detectedLanguage == null), isTrue);
        expect((http_.singleJsonBody! as Map)['format'], 'html');
      });

      test('tolerates short parallel lists', () async {
        respond = (_) => jsonResponse(
          '{"translatedText":["a","b"],"detectedLanguage":'
          '[{"confidence":1,"language":"de"}],"alternatives":"x"}',
        );
        final results = await client.translateBatch(
          texts: const ['x', 'y'],
          target: 'en',
        );
        expect(results.first.detectedLanguage?.code, 'de');
        expect(results.last.detectedLanguage, isNull);
      });

      test('returns [] for no texts without a request', () async {
        expect(
          await client.translateBatch(texts: const [], target: 'en'),
          isEmpty,
        );
        expect(http_.requests, isEmpty);
      });

      test('rejects a wrong number of translations', () {
        respond = (_) => jsonResponse('{"translatedText":["a"]}');
        expect(
          client.translateBatch(texts: const ['x', 'y'], target: 'en'),
          throwsMtError<LibreTranslateException>(
            kind: MtErrorKind.invalidResponse,
            detail: 'expected 2 translations, got 1',
          ),
        );
      });

      test('rejects a non-list translatedText', () {
        respond = (_) => jsonResponse('{"translatedText":"a"}');
        expect(
          client.translateBatch(texts: const ['x'], target: 'en'),
          throwsMtError<LibreTranslateException>(
            kind: MtErrorKind.invalidResponse,
            detail: 'expected a JSON array',
          ),
        );
      });
    });

    test('languages', () async {
      respond = (_) => jsonResponse(_languages);
      final languages = await client.languages();
      expect(http_.single.method, 'GET');
      expect(
        http_.single.url.toString(),
        'https://translate.example.org/languages',
      );
      expect(languages, const [
        LibreLanguage(
          code: 'en',
          name: 'English',
          targets: ['en', 'fr', 'zh-Hans', 'zh-Hant'],
        ),
        LibreLanguage(
          code: 'zh-Hans',
          name: 'Chinese (Simplified)',
          targets: ['en'],
        ),
        LibreLanguage(code: 'pb', name: 'Portuguese (Brazil)'),
      ]);
    });

    test('detect', () async {
      respond = (_) => jsonResponse(
        '[{"confidence":90.0,"language":"fr"},{"confidence":5,"language":"it"},'
        '"x"]',
      );
      final detected = await client.detect('Bonjour');
      expect(http_.single.method, 'POST');
      expect(http_.single.url.path, '/detect');
      expect(http_.singleJsonBody, {'q': 'Bonjour', 'api_key': 'secret'});
      expect(detected, const [
        LibreDetectedLanguage(code: 'fr', confidence: 90),
        LibreDetectedLanguage(code: 'it', confidence: 5),
      ]);
    });

    test('detect without a key', () async {
      respond = (_) => jsonResponse('[]');
      final keyless = LibreTranslateClient(baseUrl: _base, httpClient: http_);
      expect(await keyless.detect('x'), isEmpty);
      expect(http_.singleJsonBody, {'q': 'x'});
    });

    test('settings', () async {
      respond = (_) => jsonResponse(
        '{"apiKeys":true,"charLimit":5000,"filesTranslation":true,'
        '"frontendTimeout":500,"keyRequired":true,"suggestions":false,'
        '"supportedFilesFormat":[".txt",".odt"],'
        '"language":{"source":{"code":"auto","name":"Auto Detect"}}}',
      );
      final settings = await client.settings();
      expect(http_.single.method, 'GET');
      expect(
        http_.single.url.toString(),
        'https://translate.example.org/frontend/settings',
      );
      expect(
        settings,
        const LibreSettings(
          apiKeys: true,
          keyRequired: true,
          charLimit: 5000,
          filesTranslation: true,
          supportedFilesFormat: ['.txt', '.odt'],
        ),
      );
    });

    test('keeps a sub-path base URL', () async {
      respond = (_) => jsonResponse('[]');
      final sub = LibreTranslateClient(
        baseUrl: Uri.parse('http://me:pw@192.168.1.5:5000/libre/'),
        httpClient: http_,
      );
      await sub.languages();
      expect(
        http_.single.url.toString(),
        'http://me:pw@192.168.1.5:5000/libre/languages',
      );
    });

    group('HTTP errors', () {
      final cases =
          <
            ({
              int status,
              String body,
              MtErrorKind kind,
              String message,
              String? detail,
            })
          >[
            (
              status: 400,
              body: '{"error":"zz is not supported"}',
              kind: MtErrorKind.badRequest,
              message: 'The LibreTranslate server rejected the request.',
              detail: 'zz is not supported',
            ),
            (
              status: 400,
              body:
                  '{"error":"Visit https://portal.libretranslate.com to get '
                  'an API key"}',
              kind: MtErrorKind.unauthorized,
              message: 'This LibreTranslate server requires an API key.',
              detail:
                  'Visit https://portal.libretranslate.com to get an API key',
            ),
            (
              status: 400,
              body:
                  '{"error":"Invalid request: request (6000) exceeds text '
                  'limit (5000)"}',
              kind: MtErrorKind.payloadTooLarge,
              message:
                  'The text is longer than this LibreTranslate server allows.',
              detail:
                  'Invalid request: request (6000) exceeds text limit (5000)',
            ),
            (
              status: 400,
              body: '',
              kind: MtErrorKind.badRequest,
              message: 'The LibreTranslate server rejected the request.',
              detail: null,
            ),
            (
              status: 403,
              body: '{"error":"Invalid API key"}',
              kind: MtErrorKind.unauthorized,
              message: 'Invalid API key for this LibreTranslate server.',
              detail: 'Invalid API key',
            ),
            (
              status: 404,
              body: 'Not Found',
              kind: MtErrorKind.notFound,
              message: 'Not found. Check the LibreTranslate server URL.',
              detail: 'Not Found',
            ),
            (
              status: 413,
              body: '',
              kind: MtErrorKind.payloadTooLarge,
              message:
                  'The text is longer than this LibreTranslate server allows.',
              detail: null,
            ),
            (
              status: 429,
              body: '{"error":"Slowdown: 20 per 1 minute"}',
              kind: MtErrorKind.rateLimited,
              message:
                  'Too many requests to the LibreTranslate server. Wait a '
                  'moment and try again.',
              detail: 'Slowdown: 20 per 1 minute',
            ),
            (
              status: 500,
              body: '{"error":"Cannot translate text: boom"}',
              kind: MtErrorKind.server,
              message: 'The LibreTranslate server failed to translate.',
              detail: 'Cannot translate text: boom',
            ),
            (
              status: 405,
              body: '{"error":{"message":"Method Not Allowed"}}',
              kind: MtErrorKind.unknown,
              message: 'LibreTranslate request failed (HTTP 405).',
              detail: 'Method Not Allowed',
            ),
          ];
      for (final c in cases) {
        test('${c.status} ${c.kind.name}', () {
          respond = (_) => textResponse(c.body, c.status);
          expect(
            client.translate(text: 'x', target: 'en'),
            throwsMtError<LibreTranslateException>(
              kind: c.kind,
              statusCode: c.status,
              message: c.message,
              detail: c.detail,
              uri: Uri.parse('https://translate.example.org/translate'),
            ),
          );
        });
      }

      test('toString names the type', () async {
        respond = (_) => textResponse('{"error":"Invalid API key"}', 403);
        try {
          await client.languages();
          fail('should throw');
        } on LibreTranslateException catch (e) {
          expect(
            e.toString(),
            'LibreTranslateException(403): Invalid API key for this '
            'LibreTranslate server. (Invalid API key) '
            '[https://translate.example.org/languages]',
          );
        }
      });
    });

    test('maps transport failures', () {
      final failing = LibreTranslateClient(
        baseUrl: _base,
        httpClient: MockClient((_) => throw http.ClientException('')),
      );
      expect(
        failing.languages(),
        throwsMtError<LibreTranslateException>(
          kind: MtErrorKind.network,
          message: 'Could not reach LibreTranslate at translate.example.org.',
          detail: isNull,
        ),
      );
    });

    group('close', () {
      test('does not close an injected client', () {
        final mock = _MockHttpClient();
        LibreTranslateClient(baseUrl: _base, httpClient: mock).close();
        verifyNever(mock.close);
      });

      test('closes its own client', () {
        expect(LibreTranslateClient(baseUrl: _base).close, returnsNormally);
      });
    });
  });

  group('LibreTranslateClient.normalizeBaseUrl', () {
    const table = {
      'translate.example.org': 'https://translate.example.org',
      ' https://translate.example.org/ ': 'https://translate.example.org',
      'HTTPS://Translate.Example.org': 'https://translate.example.org',
      'https://example.org/libre/translate?x=1#f': 'https://example.org/libre',
      'example.org//libre//languages/': 'https://example.org/libre',
      'example.org/docs': 'https://example.org',
      'localhost:5000': 'http://localhost:5000',
      'libretranslate:5000': 'http://libretranslate:5000',
      '127.0.0.1:5000': 'http://127.0.0.1:5000',
      '10.0.0.2': 'http://10.0.0.2',
      '192.168.1.20:5000/': 'http://192.168.1.20:5000',
      '172.20.0.3': 'http://172.20.0.3',
      '172.40.0.3': 'https://172.40.0.3',
      '169.254.1.1': 'http://169.254.1.1',
      '100.100.1.1': 'http://100.100.1.1',
      '8.8.8.8': 'https://8.8.8.8',
      'nas.local:5000': 'http://nas.local:5000',
      'pi.lan': 'http://pi.lan',
      'box.home.arpa': 'http://box.home.arpa',
      'svc.internal': 'http://svc.internal',
      '[::1]:5000': 'http://[::1]:5000',
      '[fd7a:115c::1]': 'http://[fd7a:115c::1]',
      '[2001:db8::1]': 'https://[2001:db8::1]',
      'http://translate.example.org': 'http://translate.example.org',
      'user:pw@example.org': 'https://user:pw@example.org',
    };
    for (final MapEntry(key: input, value: expected) in table.entries) {
      test('"$input" -> $expected', () {
        expect(
          LibreTranslateClient.normalizeBaseUrl(input).toString(),
          expected,
        );
      });
    }

    for (final input in [
      '',
      '   ',
      'ftp://example.org',
      'exa mple.org',
      'http://',
      'https://[::1',
    ]) {
      test('rejects "$input"', () {
        expect(
          () => LibreTranslateClient.normalizeBaseUrl(input),
          throwsFormatException,
        );
      });
    }
  });
}
