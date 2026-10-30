import 'dart:async';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mozhi_cli/src/cli_context.dart';
import 'package:mozhi_cli/src/commands/mozhi_command.dart';
import 'package:mozhi_cli/src/errors.dart';
import 'package:mozhi_cli/src/output/format.dart';
import 'package:mozhi_cli/src/output/table.dart';
import 'package:mozhi_cli/src/resolvers.dart';
import 'package:translation_repository/translation_repository.dart';

/// `mozhi instances`: public and configured Mozhi instances.
class InstancesCommand extends Command<int> {
  new(CliContext context) {
    addSubcommand(InstancesListCommand(context));
    addSubcommand(InstancesPingCommand(context));
  }

  @override
  String get name => 'instances';

  @override
  String get description => 'List Mozhi instances and measure their latency.';
}

/// The configured instance (if any) followed by the public instances.
List<MozhiInstance> _knownInstances(String? configured) => [
  if (configured != null)
    MozhiInstance(url: MozhiCommand.normalizeInstanceUrl(configured)),
  for (final instance in MozhiInstance.publicInstances)
    if (configured == null ||
        instance.url != MozhiCommand.normalizeInstanceUrl(configured))
      instance,
];

/// `mozhi instances list`.
class InstancesListCommand extends MozhiCommand {
  new(super.context) {
    addJsonFlag();
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List the public instances and the configured one.';

  @override
  Future<int> run() async {
    final configured = config.instance;
    final instances = _knownInstances(configured);
    final configuredUrl = configured == null
        ? null
        : MozhiCommand.normalizeInstanceUrl(configured);
    if (jsonOutput) {
      printJson([
        for (final instance in instances)
          {
            'url': instance.url,
            'label': ?instance.label,
            'configured': instance.url == configuredUrl,
          },
      ]);
      return ExitCode.success.code;
    }
    logger.info(
      renderTable(
        ['URL', 'LABEL'],
        [
          for (final instance in instances)
            [
              '${instance.url}${instance.url == configuredUrl ? ' *' : ''}',
              instance.label ?? '',
            ],
        ],
        styleHeader: bold,
      ),
    );
    if (interactive) {
      note(
        configuredUrl == null
            ? 'No instance configured: translations use the public instances '
                  'in this order, with failover.'
            : '* configured instance',
      );
    }
    return ExitCode.success.code;
  }
}

/// `mozhi instances ping [url...]`: times one translation of a fixed word
/// on each instance (`TranslationRepository.pingInstance`), so a server
/// that answers but doesn't translate counts as failed.
class InstancesPingCommand extends MozhiCommand {
  new(super.context) {
    argParser.addOption(
      'timeout',
      valueHelp: 'seconds',
      defaultsTo: '10',
      help: 'Give up on an instance after this many seconds.',
    );
    addEngineOption(
      help:
          'Mozhi engine to translate the test word with (google, deepl, '
          'yandex, reverso, libre, mymemory, duckduckgo or mozhi:<id>). '
          'Default: the configured engine when it is a Mozhi engine, else '
          'google.',
    );
    addJsonFlag();
  }

  @override
  String get name => 'ping';

  @override
  String get description =>
      'Measure how fast Mozhi instances translate a test word (default: the '
      'configured one and all public instances). Only the word "Hello" is '
      'sent.';

  /// The Mozhi engine to test: `--engine` (which must be a Mozhi engine),
  /// else the configured engine when it is one, else `google`.
  String _engine() {
    final option = this.option('engine');
    if (option != null) {
      final engine = resolveEngine(option, providers);
      if (engine.mozhiEngine case final id? when engine.isMozhi) return id;
      throw const CliException.usage(
        '--engine must be a Mozhi engine: instances are tested with one.',
      );
    }
    final configured = config.engine;
    if (configured != null) {
      try {
        final engine = resolveEngine(configured, providers);
        if (engine.mozhiEngine case final id? when engine.isMozhi) return id;
      } on CliException {
        // An AI engine without its provider: test the default.
      }
    }
    return defaultPingEngine;
  }

  /// The engine tested when no Mozhi engine is given or configured.
  static const defaultPingEngine = 'google';

  @override
  String get invocation => 'mozhi instances ping [arguments] [url...]';

  @override
  Future<int> run() async {
    final seconds = num.tryParse(option('timeout') ?? '');
    if (seconds == null || seconds <= 0) {
      throw const CliException.usage(
        '--timeout must be a positive number of seconds.',
      );
    }
    final timeout = Duration(milliseconds: (seconds * 1000).round());
    final engine = _engine();
    final instances = args.rest.isEmpty
        ? _knownInstances(config.instance)
        : [
            for (final url in args.rest)
              MozhiInstance(url: MozhiCommand.normalizeInstanceUrl(url)),
          ];

    final repository = context.repositoryFactory();
    final progress = jsonOutput || !interactive
        ? null
        : logger.progress(
            'Translating a test word on ${instances.length} instances',
          );
    final List<_Ping> pings;
    try {
      pings = await Future.wait([
        for (final (index, instance) in instances.indexed)
          _ping(repository, index, instance, timeout, engine),
      ]);
    } finally {
      repository.dispose();
    }
    progress?.cancel();

    pings.sort(_Ping.compare);
    final reachable = pings.where((ping) => ping.latency != null).toList();
    if (jsonOutput) {
      printJson([for (final ping in pings) ping.toJson()]);
    } else {
      logger.info(
        renderTable(
          ['INSTANCE', 'LATENCY', 'STATUS'],
          [
            for (final ping in pings)
              [
                ping.instance.label ?? ping.instance.url,
                if (ping.latency case final latency?)
                  formatDuration(latency)
                else
                  '-',
                if (ping.latency != null)
                  green.wrap('ok')!
                else
                  red.wrap(ping.error ?? 'unreachable')!,
              ],
          ],
          styleHeader: bold,
        ),
      );
      if (interactive && reachable.isNotEmpty) {
        final fastest = reachable.first.instance;
        note(
          '${reachable.length} of ${pings.length} translate with $engine. '
          'Use the fastest with: mozhi config set instance ${fastest.url}',
        );
      }
    }
    if (reachable.isEmpty) {
      if (!jsonOutput) logger.err('No instance translates with $engine.');
      return ExitCode.unavailable.code;
    }
    return ExitCode.success.code;
  }

  static Future<_Ping> _ping(
    TranslationRepository repository,
    int order,
    MozhiInstance instance,
    Duration timeout,
    String engine,
  ) async {
    try {
      final latency = await repository
          .pingInstance(instance, engine: engine)
          .timeout(timeout);
      return _Ping(order, instance, latency: latency);
    } on TimeoutException {
      return _Ping(order, instance, error: 'timed out');
    } on InstanceDoesNotTranslateException catch (error) {
      return _Ping(
        order,
        instance,
        error: error.statusCode == null
            ? "doesn't translate"
            : "doesn't translate (HTTP ${error.statusCode})",
      );
    } on MozhiApiException catch (error) {
      return _Ping(
        order,
        instance,
        error: error.statusCode == null
            ? _firstLine(error.message)
            : 'HTTP ${error.statusCode}',
      );
    } on Object catch (error) {
      return _Ping(
        order,
        instance,
        error: _firstLine(describeError(error).message),
      );
    }
  }

  static String _firstLine(String text) {
    final line = text.split('\n').first.trim();
    return line.length > 60 ? '${line.substring(0, 57)}...' : line;
  }
}

class _Ping {
  const new(this.order, this.instance, {this.latency, this.error});

  /// Position in the requested list (keeps the sort stable).
  final int order;
  final MozhiInstance instance;
  final Duration? latency;
  final String? error;

  /// Fastest first, unreachable last (in their original order).
  static int compare(_Ping a, _Ping b) => switch ((a.latency, b.latency)) {
    (final x?, final y?) =>
      x == y ? a.order.compareTo(b.order) : x.compareTo(y),
    (_?, null) => -1,
    (null, _?) => 1,
    (null, null) => a.order.compareTo(b.order),
  };

  Map<String, dynamic> toJson() => {
    'url': instance.url,
    'label': ?instance.label,
    'ok': latency != null,
    'latencyMs': ?latency?.inMilliseconds,
    'error': ?error,
  };
}
