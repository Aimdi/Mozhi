import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mt_api/mt_api.dart';
import 'package:test/test.dart';

import '../helpers.dart';

class _MockHttpClient extends Mock implements http.Client;

const _proKey = '279a2e9d-83b3-c416-7e2d-f721593e42a0';
const _freeKey = '279a2e9d-83b3-c416-7e2d-f721593e42a0:fx';

const _translateResponse = '''
{"translations":[
  {"detected_source_language":"EN","text":"Hallo, Welt!"},
  {"detected_source_language":"EN","text":"Grüße 🌍","billed_characters":7,
   "model_type_used":"quality_optimized"}
]}''';

const _targetLanguagesResponse = '''
[{"language":"DE","name":"German","supports_formality":true},
 {"language":"EN-GB","name":"English (British)","supports_formality":false},
 {"language":"ZH-HANS","name":"Chinese (simplified)",
  "supports_formality":false},
 "garbage"]''';

const _glossaryJson = '''
{"glossary_id":"def3a26b-3e84-45b3-84ae-0c0aaf3525f7","name":"My Glossary",
 "ready":true,"source_lang":"en","target_lang":"de",
 "creation_time":"2021-08-03T14:16:18.329Z","entry_count":2}''';

void main() {
  group(DeeplClient, () {
    late RecordingClient http_;
    late DeeplClient client;
    late http.Response Function(http.Request) respond;

    setUp(() {
      respond = (_) => jsonResponse(_translateResponse);
      http_ = RecordingClient((request) => respond(request));
      client = DeeplClient(authKey: _freeKey, httpClient: http_);
    });

    group('base URL', () {
      test('uses the free endpoint for :fx keys', () {
        expect(client.baseUrl, DeeplClient.freeBaseUrl);
        expect(DeeplClient.isFreeKey(' $_freeKey\n'), isTrue);
      });

      test('uses the pro endpoint for other keys', () {
        final pro = DeeplClient(authKey: _proKey, httpClient: http_);
        expect(pro.baseUrl, DeeplClient.proBaseUrl);
        expect(DeeplClient.isFreeKey(_proKey), isFalse);
        expect(DeeplClient.defaultBaseUrl(_proKey).host, 'api.deepl.com');
        expect(DeeplClient.defaultBaseUrl(_freeKey).host, 'api-free.deepl.com');
      });

      test('exposes the key page', () {
        expect(DeeplClient.apiKeyUrl, startsWith('https://www.deepl.com/'));
      });

      test('trims the key', () async {
        final trimmed = DeeplClient(
          authKey: '  $_freeKey \n',
          httpClient: http_,
        );
        expect(trimmed.authKey, _freeKey);
        expect(trimmed.baseUrl, DeeplClient.freeBaseUrl);
        await trimmed.translate(texts: const ['a', 'b'], targetLang: 'DE');
        expect(
          http_.single.headers['authorization'],
          'DeepL-Auth-Key $_freeKey',
        );
      });

      test('keeps a custom base URL with a sub-path', () async {
        final proxied = DeeplClient(
          authKey: _proKey,
          baseUrl: Uri.parse('https://user:pw@proxy.example:8443/deepl/'),
          httpClient: http_,
        );
        respond = (_) => jsonResponse(
          '{"character_count":1,'
          '"character_limit":2}',
        );
        await proxied.usage();
        expect(
          http_.single.url.toString(),
          'https://user:pw@proxy.example:8443/deepl/v2/usage',
        );
      });
    });

    group('translate', () {
      test('posts JSON with every option and parses the result', () async {
        final result = await client.translate(
          texts: const ['Hello, world!', 'Greetings 🌍'],
          targetLang: 'DE',
          sourceLang: 'EN',
          formality: DeeplFormality.preferMore,
          context: 'A greeting card',
          glossaryId: 'g-1',
          preserveFormatting: true,
          tagHandling: DeeplTagHandling.html,
          modelType: DeeplModelType.qualityOptimized,
        );

        final request = http_.single;
        expect(request.method, 'POST');
        expect(
          request.url.toString(),
          'https://api-free.deepl.com/v2/translate',
        );
        expect(request.headers['authorization'], 'DeepL-Auth-Key $_freeKey');
        expect(request.headers['content-type'], startsWith('application/json'));
        expect(request.headers['accept'], 'application/json');
        expect(http_.singleJsonBody, {
          'text': ['Hello, world!', 'Greetings 🌍'],
          'target_lang': 'DE',
          'source_lang': 'EN',
          'formality': 'prefer_more',
          'context': 'A greeting card',
          'glossary_id': 'g-1',
          'preserve_formatting': true,
          'tag_handling': 'html',
          'model_type': 'quality_optimized',
        });
        expect(result, const [
          DeeplTranslation(text: 'Hallo, Welt!', detectedSourceLanguage: 'EN'),
          DeeplTranslation(
            text: 'Grüße 🌍',
            detectedSourceLanguage: 'EN',
            billedCharacters: 7,
            modelTypeUsed: 'quality_optimized',
          ),
        ]);
        expect(() => result.add(result.first), throwsUnsupportedError);
      });

      test('omits unset, empty and auto options', () async {
        for (final source in [null, '', '  ', 'auto', 'AUTO']) {
          http_.requests.clear();
          await client.translate(
            texts: const ['a', 'b'],
            targetLang: ' EN-US ',
            sourceLang: source,
            formality: '',
            context: '  ',
            glossaryId: '',
            tagHandling: '',
            modelType: '',
          );
          expect(http_.singleJsonBody, {
            'text': ['a', 'b'],
            'target_lang': 'EN-US',
          }, reason: 'source: $source');
        }
      });

      test('returns [] for no texts without a request', () async {
        expect(
          await client.translate(texts: const [], targetLang: 'DE'),
          isEmpty,
        );
        expect(http_.requests, isEmpty);
      });

      test('splits more than 50 texts into several requests', () async {
        respond = (request) {
          final texts =
              (jsonDecode(request.body) as Map<String, dynamic>)['text']
                  as List<dynamic>;
          return jsonResponse({
            'translations': [
              for (final text in texts)
                {'detected_source_language': 'EN', 'text': '$text!'},
            ],
          });
        };
        final texts = [for (var i = 0; i < 120; i++) 't$i'];
        final result = await client.translate(texts: texts, targetLang: 'DE');
        expect(result.map((t) => t.text), [for (final t in texts) '$t!']);
        expect(
          http_.requests.map((r) {
            final body = jsonDecode(r.body) as Map<String, dynamic>;
            return (body['text'] as List<dynamic>).length;
          }),
          [50, 50, 20],
        );
      });

      test('translateText returns the single translation', () async {
        respond = (_) => jsonResponse(
          '{"translations":[{"detected_source_language":"JA","text":"cat"}]}',
        );
        final result = await client.translateText(
          text: '猫',
          targetLang: 'EN-US',
          sourceLang: 'JA',
          formality: DeeplFormality.less,
          context: 'pets',
          glossaryId: 'g',
          preserveFormatting: true,
          tagHandling: DeeplTagHandling.xml,
          modelType: DeeplModelType.latencyOptimized,
        );
        expect(result.text, 'cat');
        expect(result.detectedSourceLanguage, 'JA');
        expect(http_.singleJsonBody, {
          'text': ['猫'],
          'target_lang': 'EN-US',
          'source_lang': 'JA',
          'formality': 'less',
          'context': 'pets',
          'glossary_id': 'g',
          'preserve_formatting': true,
          'tag_handling': 'xml',
          'model_type': 'latency_optimized',
        });
      });

      group('rejects malformed responses', () {
        final cases = <String, String>{
          'wrong count':
              '{"translations":[{"detected_source_language":"EN","text":"x"}]}',
          'translations not a list': '{"translations":{"text":"x"}}',
          'missing translations': '{}',
          'body not an object': '[]',
          'item not an object': '{"translations":["x","y"]}',
          'not JSON': 'Hallo',
        };
        for (final MapEntry(key: name, value: body) in cases.entries) {
          test(name, () {
            respond = (_) => jsonResponse(body);
            expect(
              client.translate(texts: const ['a', 'b'], targetLang: 'DE'),
              throwsMtError<DeeplApiException>(
                kind: MtErrorKind.invalidResponse,
                statusCode: isNull,
                message: 'Unexpected response from DeepL.',
                detail: isNotEmpty,
                uri: Uri.parse('https://api-free.deepl.com/v2/translate'),
              ),
            );
          });
        }
      });
    });

    group('languages', () {
      test('requests target languages by default', () async {
        respond = (_) => jsonResponse(_targetLanguagesResponse);
        final languages = await client.languages();
        final request = http_.single;
        expect(request.method, 'GET');
        expect(
          request.url.toString(),
          'https://api-free.deepl.com/v2/languages?type=target',
        );
        expect(request.headers['authorization'], 'DeepL-Auth-Key $_freeKey');
        expect(languages, const [
          DeeplLanguage(code: 'DE', name: 'German', supportsFormality: true),
          DeeplLanguage(code: 'EN-GB', name: 'English (British)'),
          DeeplLanguage(code: 'ZH-HANS', name: 'Chinese (simplified)'),
        ]);
      });

      test('requests source languages', () async {
        respond = (_) => jsonResponse('[{"language":"EN","name":"English"}]');
        final languages = await client.languages(
          type: DeeplLanguageType.source,
        );
        expect(http_.single.url.queryParameters, {'type': 'source'});
        expect(languages.single.code, 'EN');
        expect(languages.single.supportsFormality, isFalse);
      });

      test('rejects a non-list body', () {
        respond = (_) => jsonResponse('{}');
        expect(
          client.languages(),
          throwsMtError<DeeplApiException>(
            kind: MtErrorKind.invalidResponse,
            detail: 'expected a JSON array',
          ),
        );
      });
    });

    test('usage', () async {
      respond = (_) =>
          jsonResponse('{"character_count":180118,"character_limit":500000}');
      final usage = await client.usage();
      expect(http_.single.method, 'GET');
      expect(http_.single.url.path, '/v2/usage');
      expect(
        usage,
        const DeeplUsage(characterCount: 180118, characterLimit: 500000),
      );
    });

    group('glossaries', () {
      test('createGlossary posts TSV entries with base languages', () async {
        respond = (_) => jsonResponse(_glossaryJson, status: 201);
        final glossary = await client.createGlossary(
          name: 'My Glossary',
          sourceLang: 'EN-US',
          targetLang: 'de',
          entries: const {' Hello ': 'Hallo', 'world': ' Welt'},
        );
        final request = http_.single;
        expect(request.method, 'POST');
        expect(request.url.path, '/v2/glossaries');
        expect(request.headers['authorization'], 'DeepL-Auth-Key $_freeKey');
        expect(http_.singleJsonBody, {
          'name': 'My Glossary',
          'source_lang': 'en',
          'target_lang': 'de',
          'entries': 'Hello\tHallo\nworld\tWelt',
          'entries_format': 'tsv',
        });
        expect(glossary.id, 'def3a26b-3e84-45b3-84ae-0c0aaf3525f7');
        expect(glossary.entryCount, 2);
      });

      test('createGlossary validates entries before sending', () {
        for (final entries in <Map<String, String>>[
          {},
          {'': 'x'},
          {'a': '  '},
          {'a\tb': 'x'},
          {'a': 'line\nbreak'},
          {'a': 'x y'},
          {'a\u0007': 'x'},
        ]) {
          expect(
            () => client.createGlossary(
              name: 'n',
              sourceLang: 'en',
              targetLang: 'de',
              entries: entries,
            ),
            throwsArgumentError,
            reason: '$entries',
          );
        }
        expect(http_.requests, isEmpty);
      });

      test('listGlossaries', () async {
        respond = (_) => jsonResponse('{"glossaries":[$_glossaryJson, 1]}');
        final glossaries = await client.listGlossaries();
        expect(http_.single.method, 'GET');
        expect(http_.single.url.path, '/v2/glossaries');
        expect(glossaries.single.name, 'My Glossary');
      });

      test('getGlossary', () async {
        respond = (_) => jsonResponse(_glossaryJson);
        final glossary = await client.getGlossary('def3a26b');
        expect(http_.single.method, 'GET');
        expect(http_.single.url.path, '/v2/glossaries/def3a26b');
        expect(glossary.sourceLang, 'en');
        expect(glossary.targetLang, 'de');
        expect(
          glossary.creationTime,
          DateTime.utc(2021, 8, 3, 14, 16, 18, 329),
        );
      });

      test('glossaryEntries requests and parses TSV', () async {
        respond = (_) => textResponse(
          'Hello\tHallo\r\nworld\tWelt\n\nno tab\n',
          200,
          headers: {'content-type': 'text/tab-separated-values'},
        );
        final entries = await client.glossaryEntries('g 1');
        final request = http_.single;
        expect(request.method, 'GET');
        expect(request.url.path, '/v2/glossaries/g%201/entries');
        expect(request.headers['accept'], 'text/tab-separated-values');
        expect(request.headers['authorization'], 'DeepL-Auth-Key $_freeKey');
        expect(entries, {'Hello': 'Hallo', 'world': 'Welt'});
      });

      test('deleteGlossary sends DELETE and accepts 204', () async {
        respond = (_) => textResponse('', 204);
        await client.deleteGlossary('def3a26b');
        expect(http_.single.method, 'DELETE');
        expect(http_.single.url.path, '/v2/glossaries/def3a26b');
        expect(
          http_.single.headers['authorization'],
          'DeepL-Auth-Key $_freeKey',
        );
      });

      test('glossaryLanguagePairs', () async {
        respond = (_) => jsonResponse(
          '{"supported_languages":[{"source_lang":"de","target_lang":"en"},'
          '{"source_lang":"en","target_lang":"ja"}, null]}',
        );
        final pairs = await client.glossaryLanguagePairs();
        expect(http_.single.url.path, '/v2/glossary-language-pairs');
        expect(pairs, const [
          DeeplGlossaryLanguagePair(sourceLang: 'de', targetLang: 'en'),
          DeeplGlossaryLanguagePair(sourceLang: 'en', targetLang: 'ja'),
        ]);
      });

      test('glossaryLanguage', () {
        expect(DeeplClient.glossaryLanguage('EN-US'), 'en');
        expect(DeeplClient.glossaryLanguage(' zh_TW '), 'zh');
        expect(DeeplClient.glossaryLanguage('no'), 'nb');
        expect(DeeplClient.glossaryLanguage('iw'), 'he');
        expect(DeeplClient.glossaryLanguage('PT-BR'), 'pt');
      });
    });

    group('HTTP errors', () {
      final cases =
          <({int status, MtErrorKind kind, String message, bool retryable})>[
            (
              status: 400,
              kind: MtErrorKind.badRequest,
              message: 'DeepL rejected the request.',
              retryable: false,
            ),
            (
              status: 401,
              kind: MtErrorKind.unauthorized,
              message: 'Authorization failed. Check your DeepL API key.',
              retryable: false,
            ),
            (
              status: 403,
              kind: MtErrorKind.unauthorized,
              message: 'Authorization failed. Check your DeepL API key.',
              retryable: false,
            ),
            (
              status: 404,
              kind: MtErrorKind.notFound,
              message: 'Not found. The glossary may have been deleted.',
              retryable: false,
            ),
            (
              status: 413,
              kind: MtErrorKind.payloadTooLarge,
              message: 'The request is too large. Translate a shorter text.',
              retryable: false,
            ),
            (
              status: 414,
              kind: MtErrorKind.payloadTooLarge,
              message: 'The request is too large. Translate a shorter text.',
              retryable: false,
            ),
            (
              status: 429,
              kind: MtErrorKind.rateLimited,
              message:
                  'Too many requests to DeepL. Wait a moment and try again.',
              retryable: true,
            ),
            (
              status: 456,
              kind: MtErrorKind.quotaExceeded,
              message:
                  'DeepL quota exceeded: the character limit for this '
                  'billing period has been reached.',
              retryable: false,
            ),
            (
              status: 500,
              kind: MtErrorKind.server,
              message: 'DeepL is temporarily unavailable. Try again later.',
              retryable: true,
            ),
            (
              status: 503,
              kind: MtErrorKind.server,
              message: 'DeepL is temporarily unavailable. Try again later.',
              retryable: true,
            ),
            (
              status: 529,
              kind: MtErrorKind.rateLimited,
              message:
                  'Too many requests to DeepL. Wait a moment and try again.',
              retryable: true,
            ),
            (
              status: 418,
              kind: MtErrorKind.unknown,
              message: 'DeepL request failed (HTTP 418).',
              retryable: false,
            ),
            (
              status: 302,
              kind: MtErrorKind.unknown,
              message: 'DeepL request failed (HTTP 302).',
              retryable: false,
            ),
          ];
      for (final c in cases) {
        test('${c.status} -> ${c.kind.name}', () async {
          respond = (_) => jsonResponse(
            '{"message":"server says ${c.status}"}',
            status: c.status,
          );
          await expectLater(
            client.translate(texts: const ['a'], targetLang: 'DE'),
            throwsMtError<DeeplApiException>(
              kind: c.kind,
              statusCode: c.status,
              message: c.message,
              detail: 'server says ${c.status}',
              uri: Uri.parse('https://api-free.deepl.com/v2/translate'),
            ),
          );
          try {
            await client.usage();
          } on DeeplApiException catch (e) {
            expect(e.isRetryable, c.retryable);
            expect(e.fullMessage, '${c.message} (server says ${c.status})');
            expect(e.toString(), startsWith('DeeplApiException(${c.status})'));
          }
        });
      }

      test('403 keeps the wrong-endpoint hint as detail', () {
        respond = (_) => jsonResponse(
          '{"message":"Wrong endpoint. Use https://api.deepl.com"}',
          status: 403,
        );
        expect(
          client.usage(),
          throwsMtError<DeeplApiException>(
            kind: MtErrorKind.unauthorized,
            detail: 'Wrong endpoint. Use https://api.deepl.com',
          ),
        );
      });

      test('combines message and detail of the error body', () {
        respond = (_) => jsonResponse(
          '{"message":"Bad request", '
          '"detail":"Value for \'target_lang\' not supported."}',
          status: 400,
        );
        expect(
          client.translate(texts: const ['a'], targetLang: 'XX'),
          throwsMtError<DeeplApiException>(
            kind: MtErrorKind.badRequest,
            detail: "Bad request: Value for 'target_lang' not supported.",
          ),
        );
      });

      test('ignores HTML error pages', () {
        respond = (_) => textResponse(
          '<html><body>502 Bad Gateway</body></html>',
          502,
          headers: {'content-type': 'text/html'},
        );
        expect(
          client.usage(),
          throwsMtError<DeeplApiException>(
            kind: MtErrorKind.server,
            statusCode: 502,
            detail: isNull,
          ),
        );
      });
    });

    group('transport', () {
      test('maps client exceptions to network errors', () {
        final failing = DeeplClient(
          authKey: _freeKey,
          httpClient: MockClient(
            (_) => throw http.ClientException('Connection refused'),
          ),
        );
        expect(
          failing.usage(),
          throwsMtError<DeeplApiException>(
            kind: MtErrorKind.network,
            statusCode: isNull,
            message: 'Could not reach DeepL at api-free.deepl.com.',
            detail: 'Connection refused',
          ),
        );
      });

      test('times out', () async {
        final hanging = HangingClient();
        final slow = DeeplClient(
          authKey: _freeKey,
          httpClient: hanging,
          timeout: const Duration(milliseconds: 20),
        );
        await expectLater(
          slow.usage(),
          throwsMtError<DeeplApiException>(
            kind: MtErrorKind.timeout,
            message: 'No response from api-free.deepl.com within 20 ms.',
          ),
        );
        // The timed-out request is aborted.
        await pumpEventQueue();
        expect(hanging.sawAbort, isTrue);
      });

      test('cancels when the abort trigger completes', () async {
        final hanging = HangingClient();
        final cancellable = DeeplClient(authKey: _freeKey, httpClient: hanging);
        final abort = Completer<void>();
        final future = cancellable.translate(
          texts: const ['a'],
          targetLang: 'DE',
          abortTrigger: abort.future,
        );
        abort.complete();
        await expectLater(
          future,
          throwsMtError<DeeplApiException>(
            kind: MtErrorKind.cancelled,
            message: 'The request was cancelled.',
          ),
        );
        expect(hanging.sawAbort, isTrue);
      });
    });

    group('close', () {
      test('does not close an injected client', () {
        final mock = _MockHttpClient();
        DeeplClient(authKey: _freeKey, httpClient: mock).close();
        verifyNever(mock.close);
      });

      test('closes its own client', () {
        expect(DeeplClient(authKey: _freeKey).close, returnsNormally);
      });
    });

    group('TSV helpers', () {
      test('glossaryTsv joins trimmed pairs', () {
        expect(
          DeeplClient.glossaryTsv(const {'a ': ' b', 'c': 'd'}),
          'a\tb\nc\td',
        );
      });

      test('parseGlossaryTsv skips lines without a source term', () {
        expect(DeeplClient.parseGlossaryTsv('\tx\na\tb\tc\n'), {'a': 'b\tc'});
      });
    });
  });
}
