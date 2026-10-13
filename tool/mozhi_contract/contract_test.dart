/// Contract test for `package:mozhi_api` (and the Mozhi side of
/// `package:translation_repository`) against a live Mozhi server built from
/// the upstream Go source (`tool/mozhi_contract/server/`).
///
/// Run from the repository root (it uses the app's package config, so no
/// extra `pub get` is needed):
///
/// ```sh
/// # Against a server that is already running:
/// dart run tool/mozhi_contract/contract_test.dart --base http://127.0.0.1:3123
/// # Or let the script start (and stop) the server binary itself:
/// dart run tool/mozhi_contract/contract_test.dart --server /tmp/mozhi-server
/// # tool/mozhi_contract/run.sh builds the server and does the latter.
/// ```
///
/// Options:
/// * `--base <url>`: instance root (default `http://127.0.0.1:3123`).
/// * `--server <binary>`: start this Mozhi binary (`<binary> <host> <port>`)
///   before the checks and stop it afterwards.
/// * `--json <file>`: also write the results as JSON.
/// * `--destructive`: finally send a multi-engine request that includes
///   DuckDuckGo. When DuckDuckGo is unreachable this crashes the server
///   process (a Go panic in a goroutine), so it always runs last.
///
/// Every check asserts the behaviour observed against the real server. The
/// script exits with 1 when a check FAILs (client and server disagree in a
/// way the client cannot handle). Server behaviour the client handles
/// poorly is reported as GAP without failing the run. Translation upstreams
/// (Google, DeepL, ...) may be unreachable; checks that need them accept both
/// outcomes and say which one was seen.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:mozhi_api/mozhi_api.dart';
import 'package:translation_repository/translation_repository.dart';

Future<void> main(List<String> args) async {
  final _Options options;
  try {
    options = _Options.parse(args);
  } on FormatException catch (error) {
    stderr
      ..writeln(error.message)
      ..writeln(_Options.usage);
    exitCode = 64;
    return;
  }
  if (options.help) {
    stdout.writeln(_Options.usage);
    return;
  }

  final server = options.server == null
      ? null
      : await _ServerProcess.start(options.server!, options.base);
  final contract = _Contract(options.base, server: server);
  try {
    if (server == null) await _waitUntilUp(options.base);
    await contract.run(destructive: options.destructive);
  } on Object catch (error) {
    stderr.writeln('Contract run aborted: $error');
    exitCode = 2;
  } finally {
    contract.close();
    await server?.stop();
  }

  contract.printSummary();
  if (options.jsonPath case final path?) {
    File(path).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(contract.toJson()),
    );
    stdout.writeln('Wrote $path');
  }
  if (exitCode == 0 && contract.failures > 0) exitCode = 1;
}

// ---------------------------------------------------------------------------
// Command line and server process
// ---------------------------------------------------------------------------

final class _Options {
  new({
    required this.base,
    this.server,
    this.jsonPath,
    this.destructive = false,
    this.help = false,
  });

  factory parse(List<String> args) {
    var base = Uri.parse('http://127.0.0.1:3123');
    String? server;
    String? jsonPath;
    var destructive = false;
    var help = false;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      String value() {
        if (i + 1 >= args.length) {
          throw FormatException('Missing value for $arg');
        }
        return args[++i];
      }

      switch (arg) {
        case '--base':
          base = MozhiApiClient.normalizeBaseUrl(value());
        case '--server':
          server = value();
        case '--json':
          jsonPath = value();
        case '--destructive':
          destructive = true;
        case '-h' || '--help':
          help = true;
        default:
          throw FormatException('Unknown argument: $arg');
      }
    }
    return _Options(
      base: base,
      server: server,
      jsonPath: jsonPath,
      destructive: destructive,
      help: help,
    );
  }

  static const usage =
      'Usage: dart run tool/mozhi_contract/contract_test.dart '
      '[--base <url>] [--server <binary>] [--json <file>] [--destructive]';

  final Uri base;
  final String? server;
  final String? jsonPath;
  final bool destructive;
  final bool help;
}

/// A Mozhi server started by this script (`<binary> <host> <port>`).
final class _ServerProcess {
  new _(this._process) {
    _process.stdout.transform(utf8.decoder).listen(_log.write);
    _process.stderr.transform(utf8.decoder).listen(_log.write);
    unawaited(_process.exitCode.then((code) => exitCodeOrNull = code));
  }

  static Future<_ServerProcess> start(String binary, Uri base) async {
    final server = _ServerProcess._(
      await Process.start(binary, [base.host, '${base.port}']),
    );
    await _waitUntilUp(base);
    return server;
  }

  final Process _process;
  final _log = StringBuffer();

  /// Set once the process has exited.
  int? exitCodeOrNull;

  String get log => _log.toString();

  Future<void> stop() async {
    if (exitCodeOrNull != null) return;
    _process.kill();
    await _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return -9;
      },
    );
  }
}

Future<void> _waitUntilUp(Uri base) async {
  final client = MozhiApiClient(
    baseUrl: base,
    timeout: const Duration(seconds: 2),
  );
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  try {
    while (true) {
      try {
        await client.getVersion();
        return;
      } on MozhiApiException {
        if (DateTime.now().isAfter(deadline)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  } finally {
    client.close();
  }
}

// ---------------------------------------------------------------------------
// Check bookkeeping
// ---------------------------------------------------------------------------

enum _Outcome { pass, gap, fail }

/// What a check returns: [_Pass] or [_Gap]. Failures are thrown.
sealed class _Verdict {
  const new(this.detail);
  final String detail;
}

final class _Pass extends _Verdict {
  const new(super.detail);
}

final class _Gap extends _Verdict {
  const new(super.detail);
}

final class _ContractFailure implements Exception {
  new(this.message);
  final String message;

  @override
  String toString() => message;
}

final class _Result {
  new(this.name, this.outcome, this.detail);
  final String name;
  final _Outcome outcome;
  final String detail;

  Map<String, Object?> toJson() => {
    'name': name,
    'outcome': outcome.name,
    'detail': detail,
  };
}

final class _LanguageRow {
  new(this.engine);
  final String engine;
  int source = 0;
  int target = 0;
  bool sourceAuto = false;
  bool targetAuto = false;
  int sourceDuplicates = 0;
  int targetDuplicates = 0;
  int repoSource = 0;
  int repoTarget = 0;
  bool advertised = true;

  Map<String, Object?> toJson() => {
    'engine': engine,
    'advertised': advertised,
    'source': source,
    'target': target,
    'sourceAuto': sourceAuto,
    'targetAuto': targetAuto,
    'sourceDuplicates': sourceDuplicates,
    'targetDuplicates': targetDuplicates,
    'repositorySource': repoSource,
    'repositoryTarget': repoTarget,
  };
}

void _expect(bool condition, String message) {
  if (!condition) throw _ContractFailure(message);
}

/// Runs [call] and returns the [MozhiApiException] it must throw, after
/// checking [status], [message] (exact) or [startsWith].
Future<MozhiApiException> _expectApiError(
  Future<Object?> Function() call, {
  int? status,
  String? message,
  String? startsWith,
}) async {
  final Object? value;
  try {
    value = await call();
  } on MozhiApiException catch (error) {
    if (status != null) {
      _expect(
        error.statusCode == status,
        'expected HTTP $status, got ${error.statusCode}: ${error.message}',
      );
    }
    if (message != null) {
      _expect(
        error.message == message,
        'expected message "$message", got "${error.message}"',
      );
    }
    if (startsWith != null) {
      _expect(
        error.message.startsWith(startsWith),
        'expected message starting with "$startsWith", got '
        '"${error.message}"',
      );
    }
    return error;
  }
  throw _ContractFailure('expected MozhiApiException, got $value');
}

String _quote(String text, [int max = 90]) {
  final flat = text.replaceAll('\n', r'\n');
  return '"${flat.length > max ? '${flat.substring(0, max)}...' : flat}"';
}

// ---------------------------------------------------------------------------
// The contract
// ---------------------------------------------------------------------------

/// A 1x1 transparent PNG.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

/// The first bytes of a JPEG file.
final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 74, 70, 73]);

const _pseudoEngines = {'all', 'some'};

const _yesNo = {true: 'yes', false: 'no'};

final class _Contract {
  new(this.base, {this.server})
    : client = MozhiApiClient(baseUrl: base),
      raw = http.Client();

  final Uri base;
  final _ServerProcess? server;
  final MozhiApiClient client;
  final http.Client raw;
  final results = <_Result>[];
  final languages = <_LanguageRow>[];
  final facts = <String, Object?>{};

  /// Engine ids from the client's `getEngines()`.
  List<String> engines = const [];

  int get failures => results.where((r) => r.outcome == _Outcome.fail).length;

  void close() {
    client.close();
    raw.close();
  }

  Uri _api(String name, [Map<String, String>? query]) => base.replace(
    pathSegments: [
      ...base.pathSegments.where((s) => s.isNotEmpty),
      'api',
      name,
    ],
    queryParameters: query,
  );

  Future<void> check(String name, FutureOr<_Verdict> Function() body) async {
    _Result result;
    try {
      final verdict = await body();
      result = _Result(
        name,
        verdict is _Gap ? _Outcome.gap : _Outcome.pass,
        verdict.detail,
      );
    } on _ContractFailure catch (error) {
      result = _Result(name, _Outcome.fail, error.message);
    } on Object catch (error) {
      result = _Result(name, _Outcome.fail, 'unexpected error: $error');
    }
    results.add(result);
    stdout.writeln(
      '${result.outcome.name.toUpperCase().padRight(4)}  $name\n'
      '      ${result.detail}',
    );
  }

  Future<void> run({required bool destructive}) async {
    await _discovery();
    await _languageLists();
    await _translateErrors();
    await _translateUpstream();
    await _transportAndLimits();
    await _tts();
    await _image();
    await _repository();
    if (destructive) await _destructive();
  }

  // -- Discovery --------------------------------------------------------------

  Future<void> _discovery() async {
    await check('GET /api/version parses', () async {
      final response = await raw.get(_api('version'));
      _expect(response.statusCode == 200, 'HTTP ${response.statusCode}');
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      _expect(
        json.keys.toSet().containsAll({'fiberversion', 'goversion'}),
        'keys ${json.keys}',
      );
      final version = await client.getVersion();
      _expect(
        version.fiberVersion == json['fiberversion'] &&
            version.goVersion == json['goversion'],
        'client parsed $version differently from $json',
      );
      _expect(version.goVersion.startsWith('go'), 'goversion');
      facts['version'] = json;
      facts['versionContentType'] = response.headers['content-type'];
      return _Pass(
        'fiberversion=${version.fiberVersion} goversion=${version.goVersion} '
        '(content-type ${response.headers['content-type']}; no "v" prefix)',
      );
    });

    await check('ping()', () async {
      final elapsed = await client.ping();
      return _Pass('${elapsed.inMilliseconds} ms');
    });

    await check(
      'normalizeBaseUrl("<host:port>/api/") reaches the API',
      () async {
        final input = '${base.host}:${base.port}/api/';
        final url = MozhiApiClient.normalizeBaseUrl(input);
        _expect(url.scheme == 'http', 'scheme ${url.scheme} for $input');
        final other = MozhiApiClient(baseUrl: url);
        try {
          await other.getVersion();
        } finally {
          other.close();
        }
        return _Pass('$input -> $url');
      },
    );

    await check('GET /api/engines parses (pseudo-engines dropped)', () async {
      final response = await raw.get(_api('engines'));
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      _expect(
        json.containsKey('all') && json.containsKey('some'),
        'raw engines lack all/some: $json',
      );
      final parsed = await client.getEngines();
      final expected = json.keys.toSet().difference(_pseudoEngines);
      _expect(
        parsed.keys.toSet().containsAll(expected) &&
            expected.containsAll(parsed.keys),
        'client ids ${parsed.keys} vs raw $expected',
      );
      for (final MapEntry(:key, :value) in parsed.entries) {
        _expect(value == json[key], 'name of $key: $value vs ${json[key]}');
      }
      final names = parsed.values.map((n) => n.toLowerCase()).toList();
      _expect(
        names.join('\n') == ([...names]..sort()).join('\n'),
        'not sorted by name: $names',
      );
      engines = parsed.keys.toList();
      facts['engines'] = json;
      return _Pass(
        '${parsed.length} engines: ${parsed.entries.map((e) => '${e.key}'
            '=${e.value}').join(', ')} (libre is only advertised when '
        'MOZHI_LIBRETRANSLATE_URL is set)',
      );
    });

    await check('CORS header on API responses (success and errors)', () async {
      final probes = <String, Future<http.Response>>{
        'version': raw.get(_api('version')),
        'engines': raw.get(_api('engines')),
        'source_languages': raw.get(_api('source_languages', {'engine': 'x'})),
        'translate 400': raw.post(_api('translate')),
        'tts 400': raw.get(_api('tts')),
        'image 400': _multipart(fields: {}, imageType: 'image/png'),
        'unknown route 404': raw.get(_api('nope')),
      };
      final missing = <String>[];
      for (final MapEntry(:key, :value) in probes.entries) {
        final response = await value;
        if (response.headers['access-control-allow-origin'] != '*') {
          missing.add('$key (${response.statusCode})');
        }
      }
      _expect(missing.isEmpty, 'no Access-Control-Allow-Origin: $missing');
      // Preflight: Mozhi has no OPTIONS handling.
      final request = http.Request('OPTIONS', _api('engines'))
        ..headers.addAll({
          'Origin': 'http://example.test',
          'Access-Control-Request-Method': 'GET',
        });
      final preflight = await http.Response.fromStream(await raw.send(request));
      final allowMethods = preflight.headers['access-control-allow-methods'];
      return _Pass(
        'Access-Control-Allow-Origin: * on ${probes.length} probes. '
        'OPTIONS preflight -> ${preflight.statusCode} '
        '(Allow-Methods: ${allowMethods ?? 'none'}), so the web client must '
        'stay on CORS-simple requests (no custom headers, no JSON bodies).',
      );
    });

    await check('gzip responses are decoded', () async {
      // dart:io negotiates gzip; prove the server compresses.
      final io = HttpClient()..autoUncompress = false;
      try {
        final request = await io.getUrl(
          _api('source_languages', {'engine': 'google'}),
        );
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip');
        final response = await request.close();
        await response.drain<void>();
        final encoding = response.headers.value('content-encoding');
        _expect(encoding == 'gzip', 'content-encoding: $encoding');
      } finally {
        io.close();
      }
      return const _Pass(
        'server gzips JSON (Fiber compress middleware); every client call in '
        'this run decoded it',
      );
    });
  }

  // -- Language lists ---------------------------------------------------------

  Future<void> _languageLists() async {
    final repository = TranslationRepository()
      ..updateConfiguration(
        instances: [MozhiInstance(url: base.toString())],
        providers: const [],
      );
    final repoEngines = {
      for (final engine in await repository.getEngines())
        ?engine.mozhiEngine: engine,
    };
    final all = [...engines, if (!engines.contains('libre')) 'libre'];
    for (final engine in all) {
      final row = _LanguageRow(engine)..advertised = engines.contains(engine);
      languages.add(row);
      for (final source in [true, false]) {
        final endpoint = source ? 'source_languages' : 'target_languages';
        await check('GET /api/$endpoint?engine=$engine parses', () async {
          final response = await raw.get(_api(endpoint, {'engine': engine}));
          _expect(response.statusCode == 200, 'HTTP ${response.statusCode}');
          final rawList = (jsonDecode(utf8.decode(response.bodyBytes)) as List)
              .cast<Map<String, dynamic>>();
          for (final item in rawList) {
            _expect(
              item.keys.toSet().containsAll({'Name', 'Id'}) && item.length == 2,
              'unexpected item shape $item',
            );
          }
          final parsed = source
              ? await client.getSourceLanguages(engine)
              : await client.getTargetLanguages(engine);
          _expect(
            parsed.length == rawList.length,
            'client kept ${parsed.length} of ${rawList.length}',
          );
          for (var i = 0; i < parsed.length; i++) {
            _expect(
              parsed[i].id == rawList[i]['Id'] &&
                  parsed[i].name == rawList[i]['Name'],
              'item $i: ${parsed[i]} vs ${rawList[i]}',
            );
          }
          final ids = parsed.map((l) => l.id).toList();
          _expect(ids.every((id) => id.trim().isNotEmpty), 'empty id');
          final autos = ids.where((id) => id.toLowerCase() == 'auto').length;
          final duplicates = ids.length - ids.toSet().length;
          final nonAscii = parsed
              .where((l) => l.name.runes.any((r) => r > 0x7F))
              .length;
          if (source) {
            row
              ..source = ids.length
              ..sourceAuto = autos > 0
              ..sourceDuplicates = duplicates;
          } else {
            row
              ..target = ids.length
              ..targetAuto = autos > 0
              ..targetDuplicates = duplicates;
          }
          _expect(autos <= 1, '"auto" listed $autos times');
          if (!source) _expect(autos == 0, '"auto" in a target list');

          // Repository mapping: auto first (only for source lists),
          // duplicates dropped.
          var repoNote = 'engine not advertised, repository not asked';
          if (repoEngines[engine] case final translationEngine?) {
            final mapped = source
                ? await repository.getSourceLanguages(translationEngine)
                : await repository.getTargetLanguages(translationEngine);
            final expectedCount =
                ids.where((id) => id.toLowerCase() != 'auto').toSet().length +
                autos;
            _expect(
              mapped.length == expectedCount,
              'repository has ${mapped.length}, expected $expectedCount',
            );
            _expect(
              mapped.where((l) => l.isAuto).length == autos &&
                  (autos == 0 || mapped.first.isAuto),
              'repository auto handling: ${mapped.take(3).toList()}',
            );
            if (source) {
              row.repoSource = mapped.length;
            } else {
              row.repoTarget = mapped.length;
            }
            repoNote = 'repository ${mapped.length}';
          }
          final detail =
              '${ids.length} languages, auto: ${autos > 0 ? 'yes' : 'no'}, '
              'duplicate ids: $duplicates, non-ASCII names: $nonAscii, '
              '$repoNote';
          return duplicates > 0
              ? _Gap(
                  '$detail. Duplicate ids ('
                  '${_duplicates(ids).join(', ')}) are dropped by '
                  'mapMozhiLanguages; MozhiApiClient keeps them.',
                )
              : _Pass(detail);
        });
      }
    }
    repository.updateConfiguration(instances: const [], providers: const []);

    await check('source lists without "auto" reject from=auto', () async {
      final noAuto = languages
          .where((r) => r.advertised && !r.sourceAuto)
          .map((r) => r.engine)
          .toList();
      final notes = <String>[];
      for (final engine in noAuto) {
        final target = (await client.getTargetLanguages(engine))
            .map((l) => l.id)
            .firstWhere((id) => id.startsWith('fr'));
        try {
          await client.translate(
            engine: engine,
            from: 'auto',
            to: target,
            text: 'Hello',
          );
          notes.add('$engine: accepted');
        } on MozhiApiException catch (error) {
          notes.add('$engine: ${error.statusCode} ${_quote(error.message)}');
        }
      }
      final rejected = notes.where((n) => n.contains('code invalid')).length;
      final detail =
          'engines without auto in their source list: '
          '${noAuto.isEmpty ? 'none' : notes.join('; ')}';
      return rejected > 0
          ? _Gap(
              '$detail. The UI must not keep "Detect language" selected when '
              'switching to such an engine (the server answers 500, which '
              'the pool treats as retryable).',
            )
          : _Pass(detail);
    });

    await check(
      'every advertised target id passes translate validation',
      () async {
        // libmozhi validates `to` against the engine's *source* list, so ids
        // that only appear in the target list are rejected before any
        // upstream request is made.
        final rejected = <String>[];
        var tried = 0;
        for (final engine in engines) {
          final sourceIds = {
            for (final l in await client.getSourceLanguages(engine)) l.id,
          };
          final targetOnly = [
            for (final l in await client.getTargetLanguages(engine))
              if (!sourceIds.contains(l.id)) l.id,
          ];
          final from = sourceIds.firstWhere((id) => id != 'auto');
          for (final to in targetOnly) {
            tried++;
            try {
              await client.translate(
                engine: engine,
                from: from,
                to: to,
                text: 'Hello',
              );
            } on MozhiApiException catch (error) {
              if (error.message.toLowerCase().contains(
                'target language code',
              )) {
                rejected.add('$engine:$to');
              }
            }
          }
        }
        if (rejected.isEmpty) {
          return _Pass('$tried target-only ids tried, none rejected');
        }
        return _Gap(
          '${rejected.length} advertised target ids are rejected with 500 '
          '"Target language code invalid": ${rejected.join(', ')}. The app '
          'offers them (from /api/target_languages) but they can never work.',
        );
      },
    );
  }

  static List<String> _duplicates(List<String> ids) {
    final seen = <String>{};
    return {
      for (final id in ids)
        if (!seen.add(id)) id,
    }.toList();
  }

  // -- /api/translate errors --------------------------------------------------

  Future<void> _translateErrors() async {
    const required = 'from, to, engine, text are required query strings.';
    await check('translate: missing text -> 400 plain text', () async {
      final error = await _expectApiError(
        () =>
            client.translate(engine: 'google', from: 'en', to: 'fr', text: ''),
        status: 400,
        message: required,
      );
      _expect(!error.isRetryable, '400 must not be retryable');
      final response = await raw.get(_api('translate'));
      _expect(
        response.statusCode == 400 &&
            response.body == required &&
            (response.headers['content-type'] ?? '').startsWith('text/plain'),
        'GET without params: ${response.statusCode} '
        '${response.headers['content-type']} ${response.body}',
      );
      return _Pass(
        '${error.statusCode} ${_quote(error.message)} '
        '(GET and POST form; content-type text/plain; charset=utf-8)',
      );
    });

    await check('translate: unknown engine -> 500', () async {
      final error = await _expectApiError(
        () => client.translate(
          engine: 'nope',
          from: 'en',
          to: 'fr',
          text: 'Hello',
        ),
        status: 500,
        message: 'Engine does not exist or has been disabled.',
      );
      return _Gap(
        '500 ${_quote(error.message)}; isRetryable=${error.isRetryable}, so '
        'MozhiPool fails over to every instance for a deterministic error',
      );
    });

    await check(
      'translate: "some" pseudo-engine is not translatable',
      () async {
        final error = await _expectApiError(
          () => client.translate(
            engine: 'some',
            from: 'en',
            to: 'fr',
            text: 'Hello',
          ),
          status: 500,
        );
        return _Pass(
          '500 ${_quote(error.message)} (client hides all/some, good)',
        );
      },
    );

    await check('translate: invalid language codes -> 500', () async {
      final target = await _expectApiError(
        () => client.translate(
          engine: 'google',
          from: 'en',
          to: 'xx',
          text: 'Hello',
        ),
        status: 500,
        message: 'Target Language Code invalid',
      );
      final source = await _expectApiError(
        () => client.translate(
          engine: 'reverso',
          from: 'xx',
          to: 'fr',
          text: 'Hello',
        ),
        status: 500,
        message: 'Source language code invalid',
      );
      return _Gap(
        'google ${_quote(target.message)}, reverso ${_quote(source.message)} '
        '(capitalisation differs per engine). Validation errors are 500, '
        'not 4xx, so they count as retryable.',
      );
    });

    await check('translate: engine id is sanitised server-side', () async {
      final error = await _expectApiError(
        () => client.translate(
          engine: 'goo-gle!',
          from: 'en',
          to: 'xx',
          text: 'Hello',
        ),
        status: 500,
        message: 'Target Language Code invalid',
      );
      return _Pass(
        '"goo-gle!" is treated as "google" (non [a-zA-Z0-9,] stripped): '
        '${_quote(error.message)}',
      );
    });

    await check(
      'translate: comma list with an unknown engine -> 500',
      () async {
        final error = await _expectApiError(
          () => client.translateWithEngines(
            engines: ['google', 'nope'],
            from: 'en',
            to: 'fr',
            text: 'Hello',
          ),
          status: 500,
          message: 'Engine nopenot supported or implemented',
        );
        return _Pass('${_quote(error.message)} (sic, missing space upstream)');
      },
    );

    await check('translate: POST form fields are parsed', () async {
      // DeepL echoes source/target languages even when its upstream fails
      // (it answers 200 with an empty translation).
      final Object outcome;
      try {
        outcome = await client.translate(
          engine: 'deepl',
          from: 'en',
          to: 'fr',
          text: 'a&to=de b=c+d %20 ü 日本\n"quoted"',
        );
      } on MozhiApiException catch (error) {
        return _Pass(
          'deepl answered ${error.statusCode} ${_quote(error.message)}; '
          'fields were accepted (no 400)',
        );
      }
      final translation = outcome as MozhiTranslation;
      _expect(
        translation.sourceLanguage == 'en' &&
            translation.targetLanguage == 'fr' &&
            translation.engine == 'deepl',
        'echo ${translation.toJson()}',
      );
      return const _Pass(
        'deepl echoed source_language=en target_language=fr for a text '
        'containing &, =, +, %, newline, quotes and non-ASCII characters',
      );
    });
  }

  // -- Upstream (needs egress) ------------------------------------------------

  Future<void> _translateUpstream() async {
    final pairs = <String, (String, String)>{};
    for (final engine in engines) {
      final source = (await client.getSourceLanguages(engine))
          .map((l) => l.id)
          .toList();
      final target = (await client.getTargetLanguages(engine))
          .map((l) => l.id)
          .toList();
      String pick(List<String> ids, String code) => ids.contains(code)
          ? code
          : ids.firstWhere((id) => id.startsWith(code));
      pairs[engine] = (pick(source, 'en'), pick(target, 'fr'));
    }
    final outcomes = <String, String>{};
    for (final MapEntry(key: engine, value: (from, to)) in pairs.entries) {
      await check('translate: $engine $from->$to (upstream)', () async {
        try {
          final translation = await client.translate(
            engine: engine,
            from: from,
            to: to,
            text: 'Hello world',
          );
          _expect(translation.engine == engine, 'engine ${translation.engine}');
          if (translation.translatedText.trim().isEmpty) {
            outcomes[engine] = '200, empty translated-text';
            return const _Gap(
              '200 OK with "translated-text": "" (the upstream failed). '
              'MozhiApiClient.translate returns an empty MozhiTranslation '
              'instead of throwing; the UI shows a blank result.',
            );
          }
          outcomes[engine] = '200 ${_quote(translation.translatedText, 40)}';
          return _Pass(
            'upstream reachable: ${_quote(translation.translatedText)}',
          );
        } on MozhiApiException catch (error) {
          _expect(
            error.statusCode == 500 && error.message.isNotEmpty,
            'expected 500 with a message, got $error',
          );
          outcomes[engine] = '500 ${_quote(error.message, 60)}';
          if (error.message.startsWith('runtime error')) {
            return _Gap(
              'upstream unreachable -> 500 ${_quote(error.message)}: a Go '
              'panic recovered by Fiber leaks to the user as the message',
            );
          }
          return _Pass(
            'upstream unreachable -> 500 ${_quote(error.message)} (raw Go '
            'error incl. upstream URL and query)',
          );
        }
      });
    }
    facts['upstreamTranslate'] = outcomes;

    await check(
      'translateWithEngines: failures are dropped silently',
      () async {
        final results = await client.translateWithEngines(
          engines: ['google', 'reverso'],
          from: 'en',
          to: 'fr',
          text: 'Hello world',
        );
        final names = results.map((r) => r.engine).toList();
        final failed = ['google', 'reverso'].where((e) => !names.contains(e));
        if (failed.isEmpty) return _Pass('both engines answered: $names');
        return _Gap(
          'HTTP 200 with ${results.length} result(s) ($names); '
          '${failed.join(', ')} dropped without any error text',
        );
      },
    );
  }

  // -- Transport, routing and size limits -------------------------------------

  Future<void> _transportAndLimits() async {
    await check('wrong sub-path -> 404 plain text', () async {
      final other = MozhiApiClient(
        baseUrl: base.replace(pathSegments: ['sub']),
      );
      try {
        final error = await _expectApiError(
          other.getVersion,
          status: 404,
          message: 'Cannot GET /sub/api/version',
        );
        return _Pass('${error.statusCode} ${_quote(error.message)}');
      } finally {
        other.close();
      }
    });

    await check('connection refused -> network MozhiApiException', () async {
      final dead = MozhiApiClient(baseUrl: Uri.parse('http://127.0.0.1:1'));
      try {
        final error = await _expectApiError(dead.getVersion);
        _expect(error.statusCode == null, 'status ${error.statusCode}');
        _expect(error.isRetryable, 'network errors must be retryable');
        return _Pass(_quote(error.message));
      } finally {
        dead.close();
      }
    });

    await check('translate: body over 4 MiB -> 413 or reset', () async {
      final text = 'a' * (4 * 1024 * 1024 + 1);
      final seen = <String>[];
      var resets = 0;
      for (var i = 0; i < 3; i++) {
        final error = await _expectApiError(
          () => client.translate(
            engine: 'google',
            from: 'en',
            to: 'fr',
            text: text,
          ),
        );
        _expect(
          error.statusCode == 413 || error.statusCode == null,
          'unexpected $error',
        );
        if (error.statusCode == null) resets++;
        seen.add('${error.statusCode ?? 'network'} ${_quote(error.message)}');
      }
      final detail =
          'over the 4 MiB Fiber BodyLimit, 3 attempts gave: '
          '${seen.toSet().join(' | ')}. The 413 carries no CORS header.';
      return resets == 0
          ? _Pass(detail)
          : _Gap(
              '$detail Fasthttp answers before reading the body and closes '
              'the socket, so dart:io often sees a broken pipe/reset: a '
              'retryable network error instead of a 413.',
            );
    });
  }

  // -- /api/tts ---------------------------------------------------------------

  Future<void> _tts() async {
    await check('tts: missing text -> 400', () async {
      final error = await _expectApiError(
        () => client.textToSpeech(engine: 'google', language: 'en', text: ''),
        status: 400,
        message: 'engine, lang, text are required query strings.',
      );
      return _Pass(_quote(error.message));
    });

    await check('tts: engine without TTS -> 500', () async {
      final error = await _expectApiError(
        () =>
            client.textToSpeech(engine: 'deepl', language: 'en', text: 'Hello'),
        status: 500,
        message:
            "Engine does not exist and/or doesn't support TTS and/or has been "
            'disabled.',
      );
      return _Pass(_quote(error.message));
    });

    for (final engine in ['google', 'reverso']) {
      await check('tts: $engine (upstream)', () async {
        try {
          final bytes = await client.textToSpeech(
            engine: engine,
            language: 'en',
            text: 'Hello',
          );
          return _Pass('upstream reachable: ${bytes.length} bytes of audio');
        } on MozhiApiException catch (error) {
          _expect(error.statusCode == 500, 'status ${error.statusCode}');
          return _Pass('upstream unreachable -> 500 ${_quote(error.message)}');
        }
      });
    }

    await check('tts: POST is rejected (client uses GET)', () async {
      final response = await raw.post(
        _api('tts', {'engine': 'google', 'lang': 'en', 'text': 'Hello'}),
      );
      _expect(response.statusCode == 405, 'HTTP ${response.statusCode}');
      return const _Pass('405 Method Not Allowed; GET is the only method');
    });

    await check('tts: long text hits the 4 KiB request-line limit', () async {
      Future<MozhiApiException?> attempt(String text) async {
        try {
          await client.textToSpeech(
            engine: 'google',
            language: 'en',
            text: text,
          );
          return null;
        } on MozhiApiException catch (error) {
          return error;
        }
      }

      /// 431, or a reset because fasthttp closes the socket right away.
      bool tooLong(MozhiApiException? error) =>
          error != null && (error.statusCode ?? 431) == 431;

      Future<int> maxLength(String unit) async {
        var low = 1;
        var high = 8000;
        while (low < high) {
          final mid = (low + high + 1) ~/ 2;
          if (tooLong(await attempt(unit * mid))) {
            high = mid - 1;
          } else {
            low = mid;
          }
        }
        return low;
      }

      final seen = <String>{};
      for (var i = 0; i < 3; i++) {
        final error = await attempt('a' * 5000);
        _expect(tooLong(error), '5000 characters: $error');
        seen.add('${error!.statusCode ?? 'network'} ${_quote(error.message)}');
      }
      final ascii = await maxLength('a');
      final cjk = await maxLength('日');
      facts['ttsMaxAscii'] = ascii;
      facts['ttsMaxCjk'] = cjk;
      return _Gap(
        'texts longer than ~$ascii ASCII / ~$cjk CJK characters are refused '
        'before the handler runs; 5000 characters gave: ${seen.join(' | ')} '
        '(no CORS header on the 431). A reset is a retryable network error, '
        'so the pool tries every instance and the Google->Reverso fallback '
        'repeats it. Long texts need chunking client-side.',
      );
    });
  }

  // -- /api/image -------------------------------------------------------------

  /// Posts a hand-built multipart body to `/api/image` (with an `image`
  /// part of [imageType] when given).
  Future<http.Response> _multipart({
    required Map<String, String> fields,
    String? imageType,
    List<int>? bytes,
  }) {
    const boundary = 'mozhi-contract-boundary';
    final body = BytesBuilder();
    void add(String text) => body.add(utf8.encode(text));
    for (final MapEntry(:key, :value) in fields.entries) {
      add(
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="$key"\r\n\r\n'
        '$value\r\n',
      );
    }
    if (imageType != null) {
      add(
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="image"; filename="image"\r\n'
        'Content-Type: $imageType\r\n\r\n',
      );
      body.add(bytes ?? _png);
      add('\r\n');
    }
    add('--$boundary--\r\n');
    return raw.post(
      _api('image'),
      headers: {'content-type': 'multipart/form-data; boundary=$boundary'},
      body: body.takeBytes(),
    );
  }

  Future<void> _image() async {
    const fields = {'engine': 'google', 'from': 'en', 'to': 'fr'};
    const invalid = 'Invalid image, only png images are accepted';

    await check('image: non-PNG part content type -> 400', () async {
      for (final type in ['image/jpeg', 'text/plain']) {
        final response = await _multipart(
          fields: fields,
          imageType: type,
          bytes: _jpeg,
        );
        _expect(
          response.statusCode == 400 && response.body == invalid,
          '$type: ${response.statusCode} ${response.body}',
        );
      }
      return const _Pass(
        '400 "$invalid" for image/jpeg and text/plain parts (raw multipart; '
        'MozhiApiClient always sends image/png)',
      );
    });

    await check('image: validation is by declared type only', () async {
      try {
        await client.translateImage(pngBytes: _jpeg, from: 'en', to: 'xx');
      } on MozhiApiException catch (error) {
        _expect(
          error.statusCode == 500 &&
              error.message == 'Target Language Code invalid',
          'JPEG bytes labelled image/png: $error',
        );
        return _Gap(
          'JPEG bytes sent as image/png pass the PNG check and reach '
          'language validation (${_quote(error.message)}); the repository '
          'must keep converting to PNG itself',
        );
      }
      throw _ContractFailure('expected an error');
    });

    await check('image: missing fields / file / multipart', () async {
      final noFields = await _expectApiError(
        () => client.translateImage(pngBytes: _png, from: '', to: ''),
        status: 400,
        message: 'from, to, engine are required arguments.',
      );
      final noFile = await _multipart(fields: fields);
      final notMultipart = await raw.post(_api('image'), body: fields);
      _expect(
        noFile.statusCode == 500 &&
            noFile.body ==
                'there is no uploaded file associated with the given key',
        'no file: ${noFile.statusCode} ${noFile.body}',
      );
      _expect(
        notMultipart.statusCode == 500 &&
            notMultipart.body.contains('multipart/form-data'),
        'urlencoded: ${notMultipart.statusCode} ${notMultipart.body}',
      );
      return _Pass(
        'no from/to: 400 ${_quote(noFields.message)}; no file part: 500 '
        '${_quote(noFile.body)}; urlencoded body: 500 '
        '${_quote(notMultipart.body)}',
      );
    });

    await check('image: language validation and upstream', () async {
      final invalidTarget = await _expectApiError(
        () => client.translateImage(pngBytes: _png, from: 'en', to: 'xx'),
        status: 500,
        message: 'Target Language Code invalid',
      );
      String upstream;
      try {
        final result = await client.translateImage(
          pngBytes: _png,
          from: 'en',
          to: 'fr',
          engine: 'deepl',
        );
        _expect(result.targetLanguage == 'fr', 'TargetLang');
        upstream = 'upstream reachable (SourceLang ${result.sourceLanguage})';
      } on MozhiApiException catch (error) {
        _expect(error.statusCode == 500, 'status ${error.statusCode}');
        _expect(
          error.message.contains('translate.google.com'),
          'engine=deepl should still use Google: ${error.message}',
        );
        upstream = 'upstream unreachable -> 500 ${_quote(error.message)}';
      }
      return _Pass(
        'to=xx: ${_quote(invalidTarget.message)}; engine=deepl is ignored '
        '(always Google): $upstream',
      );
    });
  }

  // -- TranslationRepository on top of the client -----------------------------

  Future<void> _repository() async {
    final counter = _CountingClient();
    final mirror = Uri.parse('http://mirror.invalid');
    final repository = TranslationRepository(
      mozhiClientFactory: (url) => MozhiApiClient(
        baseUrl: url.host == mirror.host ? base : url,
        httpClient: counter,
      ),
    );

    TranslationEngine? google;
    TranslationEngine? reverso;
    await check('repository: failover past a dead instance', () async {
      repository.updateConfiguration(
        instances: [
          const MozhiInstance(url: 'http://127.0.0.1:1'),
          MozhiInstance(url: base.toString()),
        ],
        providers: const [],
      );
      final found = await repository.getEngines();
      _expect(
        repository.activeInstance?.url == base.toString(),
        'active ${repository.activeInstance?.url}',
      );
      google = found.firstWhere((e) => e.mozhiEngine == 'google');
      reverso = found.firstWhere((e) => e.mozhiEngine == 'reverso');
      return _Pass(
        '${found.length} engines via ${repository.activeInstance?.url}: '
        '${found.map((e) => e.id).join(', ')}',
      );
    });
    if (google == null || reverso == null) return;

    await check(
      'repository: deterministic 500 is retried on every instance',
      () async {
        repository.updateConfiguration(
          instances: [
            MozhiInstance(url: base.toString()),
            MozhiInstance(url: mirror.toString()),
          ],
          providers: const [],
        );
        counter.paths.clear();
        const request = TranslationRequest(
          text: 'Hello',
          source: Language(code: 'en', name: 'English'),
          target: Language(code: 'xx', name: 'Invalid'),
        );
        try {
          await repository.translate(google!, request).drain<void>();
          throw _ContractFailure('expected an error');
        } on MozhiApiException catch (error) {
          _expect(error.statusCode == 500, 'status ${error.statusCode}');
          final calls = counter.paths.where((p) => p.endsWith('/translate'));
          return _Gap(
            '${_quote(error.message)} after ${calls.length} /api/translate '
            'calls for 2 instances: invalid languages and unknown engines fail '
            'over like outages',
          );
        }
      },
    );

    await check('repository: compare() batches Mozhi engines', () async {
      repository.updateConfiguration(
        instances: [MozhiInstance(url: base.toString())],
        providers: const [],
      );
      final entries = await repository.compare(
        [google!, reverso!],
        const TranslationRequest(
          text: 'Hello world',
          source: Language(code: 'en', name: 'English'),
          target: Language(code: 'fr', name: 'French'),
        ),
      ).toList();
      _expect(entries.length == 2, '${entries.length} entries');
      final failures = [
        for (final entry in entries)
          if (!entry.isSuccess) '${entry.name}: ${entry.error}',
      ];
      if (failures.isEmpty) return const _Pass('both engines translated');
      return _Gap(
        'with the upstreams down the batch answers 200 [] and every '
        'engine becomes ${failures.join('; ')} (the real upstream error is '
        'lost; single-engine requests would say why)',
      );
    });

    await check('repository: TTS falls back from Google to Reverso', () async {
      counter.paths.clear();
      try {
        final bytes = await repository.textToSpeech(
          text: 'Hello',
          languageCode: 'en',
        );
        return _Pass('audio: ${bytes.length} bytes');
      } on MozhiApiException catch (error) {
        final calls = counter.paths.where((p) => p.endsWith('/tts')).length;
        _expect(calls == 2, '$calls /api/tts calls');
        _expect(
          error.message.contains('translate.google.com'),
          'the Google error should be rethrown: ${error.message}',
        );
        return _Pass(
          'google then reverso tried ($calls calls), Google error rethrown',
        );
      }
    });

    repository.updateConfiguration(instances: const [], providers: const []);
    counter.close();
  }

  // -- Destructive: multi-engine request with DuckDuckGo ----------------------

  Future<void> _destructive() async {
    await check(
      'translateWithEngines incl. duckduckgo (destructive)',
      () async {
        try {
          final results = await client.translateWithEngines(
            engines: ['google', 'duckduckgo'],
            from: 'en',
            to: 'fr',
            text: 'Hello world',
          );
          return _Pass(
            'server survived (DuckDuckGo reachable): ${results.length} results',
          );
        } on MozhiApiException catch (error) {
          var alive = true;
          try {
            await Future<void>.delayed(const Duration(milliseconds: 500));
            await client.getVersion();
          } on MozhiApiException {
            alive = false;
          }
          _expect(!alive, 'request failed but the server is alive: $error');
          final serverExit = server?.exitCodeOrNull;
          final panic = server?.log.contains('panic: runtime error') ?? false;
          facts['duckduckgoBatchCrash'] = true;
          return _Gap(
            'the Mozhi process died (${error.statusCode ?? 'network'}: '
            '${_quote(error.message)}; exit code ${serverExit ?? 'n/a'}'
            '${panic ? ', Go panic in libmozhi.ddgVqdUpdate' : ''}). '
            'engine=all and any comma list containing duckduckgo take the '
            'whole instance down when DuckDuckGo is unreachable.',
          );
        }
      },
    );
  }

  // -- Output -----------------------------------------------------------------

  void printSummary() {
    stdout
      ..writeln()
      ..writeln(
        'Language lists (client counts; repository counts after '
        'dedup/auto mapping):',
      )
      ..writeln(
        '  engine       advertised  source  target  auto(src/tgt)  dupes  '
        'repo(src/tgt)',
      );
    for (final row in languages) {
      final auto = '${_yesNo[row.sourceAuto]}/${_yesNo[row.targetAuto]}';
      final dupes = '${row.sourceDuplicates}/${row.targetDuplicates}';
      stdout.writeln(
        '  ${row.engine.padRight(12)} ${_yesNo[row.advertised]!.padRight(11)} '
        '${'${row.source}'.padLeft(6)}  ${'${row.target}'.padLeft(6)}  '
        '${auto.padRight(13)}  ${dupes.padRight(5)}  '
        '${row.repoSource}/${row.repoTarget}',
      );
    }
    final counts = {
      for (final outcome in _Outcome.values)
        outcome: results.where((r) => r.outcome == outcome).length,
    };
    stdout
      ..writeln()
      ..writeln(
        '${results.length} checks: ${counts[_Outcome.pass]} pass, '
        '${counts[_Outcome.gap]} gap, ${counts[_Outcome.fail]} fail',
      );
  }

  Map<String, Object?> toJson() => {
    'base': base.toString(),
    'facts': facts,
    'languages': [for (final row in languages) row.toJson()],
    'results': [for (final result in results) result.toJson()],
  };
}

/// Records the path of every request (to count failover attempts).
final class _CountingClient extends http.BaseClient {
  final http.Client _inner = http.Client();
  final paths = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    paths.add(request.url.path);
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
