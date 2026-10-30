@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

/// [TranslationRepository.pingInstance] over real HTTP (the default Mozhi
/// client) against a local server that answers like a Mozhi instance.
void main() {
  late HttpServer server;
  late List<(String, String, Map<String, String>)> requests;
  late Map<String, (int, String, ContentType)> answers;
  late TranslationRepository repository;
  late MozhiInstance instance;

  const version = '{"fiberversion":"v2","goversion":"go1"}';
  const bonjour = '{"engine":"google","translated-text":"Bonjour"}';

  setUp(() async {
    requests = [];
    answers = {
      '/api/version': (200, version, ContentType.json),
      '/api/translate': (200, bonjour, ContentType.json),
    };
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
      ..listen((request) async {
        final body = await utf8.decodeStream(request);
        requests.add((
          request.method,
          request.uri.path,
          body.isEmpty ? const {} : Uri.splitQueryString(body),
        ));
        final (status, text, type) =
            answers[request.uri.path] ?? (404, 'Not Found', ContentType.text);
        request.response
          ..statusCode = status
          ..headers.contentType = type
          ..write(text);
        await request.response.close();
      });
    instance = MozhiInstance(url: 'http://127.0.0.1:${server.port}');
    repository = TranslationRepository();
  });

  tearDown(() async {
    repository.dispose();
    await server.close(force: true);
  });

  test('times one translation of the fixed word, nothing else', () async {
    final latency = await repository.pingInstance(instance);
    expect(latency, greaterThan(Duration.zero));
    final (method, path, form) = requests.single;
    expect((method, path), ('POST', '/api/translate'));
    expect(form, {
      'engine': 'google',
      'from': 'en',
      'to': 'fr',
      'text': 'Hello',
    });
  });

  test('tests the given engine', () async {
    await repository.pingInstance(instance, engine: 'duckduckgo');
    expect(requests.single.$3['engine'], 'duckduckgo');
  });

  test('a 500 from translate fails although the version answers', () async {
    answers['/api/translate'] = (
      500,
      'Post "https://translate.google.com/translate_a/single?q=Hello": 429',
      ContentType.text,
    );
    await expectLater(
      repository.pingInstance(instance),
      throwsA(
        isA<InstanceDoesNotTranslateException>()
            .having((e) => e.statusCode, 'statusCode', 500)
            .having((e) => e.engine, 'engine', 'google')
            .having((e) => e.message, 'message', isNot(contains('q=Hello'))),
      ),
    );
    expect(requests.map((r) => r.$2), ['/api/translate']);
  });

  test('a bot wall page is not a translation', () async {
    answers['/api/translate'] = (
      200,
      '<!doctype html><title>Checking your browser</title>',
      ContentType.html,
    );
    await expectLater(
      repository.pingInstance(instance),
      throwsA(
        isA<MozhiApiException>().having(
          (e) => e is InstanceDoesNotTranslateException,
          'does not translate',
          isFalse,
        ),
      ),
    );
  });

  test('an answer without a translation fails', () async {
    answers['/api/translate'] = (
      200,
      '{"engine":"google","translated-text":"Hello"}',
      ContentType.json,
    );
    await expectLater(
      repository.pingInstance(instance),
      throwsA(isA<InstanceDoesNotTranslateException>()),
    );
  });

  test('a refused request fails as before', () async {
    answers['/api/translate'] = (403, 'Forbidden', ContentType.text);
    await expectLater(
      repository.pingInstance(instance),
      throwsA(
        isA<MozhiApiException>()
            .having((e) => e.statusCode, 'statusCode', 403)
            .having(
              (e) => e is InstanceDoesNotTranslateException,
              'does not translate',
              isFalse,
            ),
      ),
    );
  });
}
