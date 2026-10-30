import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/core/network/mozhi_instance_checker.dart';
import 'package:mozhi_api/mozhi_api.dart';

const _url = 'https://mozhi.example';

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  late List<http.Request> requests;
  late List<Duration> timeouts;
  late FutureOr<http.Response> Function(http.Request) respond;
  late MozhiInstanceChecker checker;

  setUp(() {
    requests = [];
    timeouts = [];
    respond = (request) => switch (request.url.path) {
      '/api/engines' => _json({
        'all': 'All Engines',
        'deepl': 'DeepL',
        'google': 'Google',
      }),
      '/api/translate' => _json({
        'engine': request.bodyFields['engine'],
        'translated-text': 'Hallo',
      }),
      _ => http.Response('not found', 404),
    };
    checker = MozhiInstanceChecker((baseUrl, timeout) {
      timeouts.add(timeout);
      return MozhiApiClient(
        baseUrl: baseUrl,
        timeout: timeout,
        httpClient: MockClient((request) async {
          requests.add(request);
          return await respond(request);
        }),
      );
    });
  });

  tearDown(() => checker.dispose());

  test('knows nothing before a check', () {
    expect(checker.results, isEmpty);
    expect(checker.resultFor(_url), isNull);
  });

  group('check', () {
    test('lists the engines with the short timeout', () async {
      final changes = <void>[];
      final subscription = checker.changes.listen(changes.add);
      addTearDown(subscription.cancel);

      final health = await checker.check(_url);

      expect(health, isA<InstanceOnline>());
      final online = health as InstanceOnline;
      expect(online.engines, {'deepl': 'DeepL', 'google': 'Google'});
      expect(online.latency, greaterThanOrEqualTo(Duration.zero));
      expect(checker.resultFor(_url), online);
      expect(requests.single.url.toString(), '$_url/api/engines');
      expect(timeouts, [checker.checkTimeout]);
      await pumpEventQueue();
      expect(changes, hasLength(2));
    });

    test('reports checking while the request runs', () async {
      final answer = Completer<http.Response>();
      respond = (_) => answer.future;

      final checking = checker.check(_url);

      expect(checker.resultFor(_url), const InstanceChecking());
      answer.complete(_json({'google': 'Google'}));
      await checking;
      expect(checker.resultFor(_url), isA<InstanceOnline>());
    });

    test('stores a failure', () async {
      respond = (_) => http.Response('Bad gateway', 502);

      final health = await checker.check(_url);

      expect(
        health,
        isA<InstanceOffline>().having(
          (h) => h.error,
          'error',
          isA<MozhiApiException>(),
        ),
      );
      expect(checker.results, {_url: health});
    });

    test('checkAll checks each instance once', () async {
      await checker.checkAll([_url, 'https://b.example', _url]);

      expect(
        checker.results.keys,
        unorderedEquals([_url, 'https://b.example']),
      );
      expect(requests, hasLength(2));
    });
  });

  group('test', () {
    test('translates hello to German with the preferred engine', () async {
      final result = await checker.test(_url);

      expect(result.engineId, 'google');
      expect(result.engineName, 'Google');
      expect(result.text, 'Hallo');
      expect(result.latency, greaterThanOrEqualTo(Duration.zero));
      expect(requests.last.bodyFields, {
        'engine': 'google',
        'from': 'en',
        'to': 'de',
        'text': 'hello',
      });
      expect(timeouts, [checker.testTimeout]);
      expect(checker.resultFor(_url), isA<InstanceOnline>());
    });

    test('reuses the engines of an earlier check', () async {
      await checker.check(_url);
      requests.clear();

      await checker.test(_url);

      expect(requests.map((r) => r.url.path), ['/api/translate']);
    });

    test('stores and rethrows a failing engine list', () async {
      respond = (_) => http.Response('down', 503);

      await expectLater(checker.test(_url), throwsA(isA<MozhiApiException>()));
      expect(checker.resultFor(_url), isA<InstanceOffline>());
    });

    test('fails when no engine is enabled', () async {
      respond = (_) => _json({'all': 'All Engines'});

      await expectLater(
        checker.test(_url),
        throwsA(isA<InstanceHasNoEnginesException>()),
      );
      expect(
        const InstanceHasNoEnginesException().toString(),
        'InstanceHasNoEnginesException',
      );
    });

    test('tests the engine the app uses when the instance has it', () async {
      final result = await checker.test(_url, engine: 'deepl');

      expect(result.engineId, 'deepl');
      expect(result.engineName, 'DeepL');
      expect(requests.last.bodyFields['engine'], 'deepl');
    });

    test('picks another engine when the instance lacks it', () async {
      final result = await checker.test(_url, engine: 'yandex');

      expect(result.engineId, 'google');
      expect(requests.last.bodyFields['engine'], 'google');
    });

    test('a server whose engine fails does not pass', () async {
      respond = (request) => request.url.path == '/api/engines'
          ? _json({'google': 'Google'})
          : http.Response('Post "https://translate.google.com": 429', 500);

      await expectLater(
        checker.test(_url, engine: 'google'),
        throwsA(
          isA<MozhiApiException>().having((e) => e.statusCode, 'status', 500),
        ),
      );
    });

    test('rethrows a failing translation', () async {
      respond = (request) => request.url.path == '/api/engines'
          ? _json({'yandex': 'Yandex'})
          : http.Response('Engine does not exist', 500);

      await expectLater(checker.test(_url), throwsA(isA<MozhiApiException>()));
      expect(requests.last.bodyFields['engine'], 'yandex');
    });
  });

  test('mozhiEngineOf reads the Mozhi engine of an engine id', () {
    expect(mozhiEngineOf('mozhi:google'), 'google');
    expect(mozhiEngineOf('mozhi:deepl'), 'deepl');
    expect(mozhiEngineOf('mozhi:'), isNull);
    expect(mozhiEngineOf('ai:claude'), isNull);
    expect(mozhiEngineOf('offline'), isNull);
    expect(mozhiEngineOf(null), isNull);
  });

  test('pickTestEngine prefers Google, then the listed order', () {
    expect(
      MozhiInstanceChecker.pickTestEngine({'deepl': 'D', 'google': 'G'}),
      'google',
    );
    expect(
      MozhiInstanceChecker.pickTestEngine({'deepl': 'D', 'reverso': 'R'}),
      'reverso',
    );
    expect(MozhiInstanceChecker.pickTestEngine({'x': 'X', 'y': 'Y'}), 'x');
    expect(MozhiInstanceChecker.pickTestEngine({}), isNull);
  });

  test('clear forgets the results once', () async {
    await checker.check(_url);
    final changes = <void>[];
    final subscription = checker.changes.listen(changes.add);
    addTearDown(subscription.cancel);

    checker
      ..clear()
      ..clear();
    await pumpEventQueue();

    expect(checker.results, isEmpty);
    expect(changes, hasLength(1));
  });

  test('keeps working without notifications after dispose', () async {
    await checker.dispose();

    expect(await checker.check(_url), isA<InstanceOnline>());
  });

  test('results compare by value', () {
    // Built at run time, so == compares the props.
    final latency = Duration(milliseconds: DateTime(2026).year);
    final engines = {'g': 'G'};
    expect(const InstanceChecking().props, isEmpty);
    expect(
      InstanceOnline(latency: latency, engines: engines),
      InstanceOnline(latency: latency, engines: {...engines}),
    );
    expect(
      InstanceOffline(latency.toString()),
      InstanceOffline(latency.toString()),
    );
    InstanceTestResult result() => InstanceTestResult(
      engineId: 'g',
      engineName: engines['g']!,
      text: 't',
      latency: latency,
    );
    expect(result(), result());
  });
}
