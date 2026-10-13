import 'dart:convert';
import 'dart:io' as io;

/// Process-level IO the commands need besides the `Logger`: standard input,
/// terminal capabilities and the environment.
///
/// Everything goes through this class so that tests can replace it.
class Console {
  /// Uses the real [io.stdin], [io.stdout] and [io.Platform.environment]
  /// unless replacements are given.
  new({io.Stdin? stdin, io.Stdout? stdout, Map<String, String>? environment})
    : _stdin = stdin,
      _stdout = stdout,
      _environment = environment;

  final io.Stdin? _stdin;
  final io.Stdout? _stdout;
  final Map<String, String>? _environment;

  io.Stdin get _in => _stdin ?? io.stdin;
  io.Stdout get _out => _stdout ?? io.stdout;

  /// The process environment.
  Map<String, String> get environment =>
      _environment ?? io.Platform.environment;

  /// Whether the host is Windows (no POSIX file modes).
  bool get isWindows => io.Platform.isWindows;

  /// Whether standard input is an interactive terminal (nothing piped in).
  bool get stdinHasTerminal => _in.hasTerminal;

  /// Whether standard output is an interactive terminal (not piped).
  bool get stdoutHasTerminal => _out.hasTerminal;

  /// Whether standard output understands ANSI escape sequences (cursor
  /// movement is used to redraw streamed AI output).
  bool get supportsAnsiEscapes =>
      stdoutHasTerminal &&
      _out.supportsAnsiEscapes &&
      !environment.containsKey('NO_COLOR') &&
      environment['TERM'] != 'dumb';

  /// Width of the terminal in columns (80 when not a terminal).
  int get terminalColumns => stdoutHasTerminal ? _out.terminalColumns : 80;

  /// Height of the terminal in rows (24 when not a terminal).
  int get terminalLines => stdoutHasTerminal ? _out.terminalLines : 24;

  /// Reads standard input to the end as UTF-8 (malformed bytes are
  /// replaced).
  Future<String> readStdin() =>
      const Utf8Decoder(allowMalformed: true).bind(_in).join();
}
