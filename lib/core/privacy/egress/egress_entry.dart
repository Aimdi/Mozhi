import 'package:equatable/equatable.dart';

/// Why the app made a request, derived from its address while it was sent
/// (`EgressClassifier`); the address itself is never kept.
enum EgressPurpose {
  /// Text to translate (or to detect the language of) for a Mozhi,
  /// LibreTranslate or DeepL server, or a DeepL glossary.
  translation,

  /// A request to an AI model: a translation, proofreading, a dictionary
  /// look-up or insights all look the same from the network.
  aiModel,

  /// Text read aloud by a server (Mozhi's text-to-speech).
  speech,

  /// A photo sent for translation.
  image,

  /// Engine, language and model lists, version and usage checks: no text.
  catalog,

  /// A download of an on-device model (offline translation, voice input,
  /// text recognition): no text.
  modelDownload,

  /// A web page the user asked the web page translator to fetch.
  webPage,

  /// Anything else.
  other;

  /// Whether requests of this purpose carry the user's text or photo to
  /// the destination.
  bool get carriesContent => switch (this) {
    translation || aiModel || speech || image => true,
    catalog || modelDownload || webPage || other => false,
  };
}

/// Who receives a request, in the terms the app uses everywhere else
/// (`DataDestination`): see `EgressClassifier.destinationOf`.
enum EgressDestinationKind {
  /// A server on this device (`localhost`), e.g. Ollama or LM Studio.
  thisDevice,

  /// A server on the local network the user runs.
  localNetwork,

  /// A Tor `.onion` or I2P `.i2p` service.
  hiddenService,

  /// A commercial cloud service such as OpenAI, Anthropic or DeepL.
  cloudProvider,

  /// A public server run by someone else (a public Mozhi or
  /// LibreTranslate instance, ...).
  publicServer,

  /// Where on-device models are downloaded from.
  modelHost,

  /// A website opened by the web page translator.
  website;

  /// Whether the receiver is someone other than the user (a cloud
  /// provider, a public server's operator, a model host or a website).
  bool get isThirdParty => switch (this) {
    thisDevice || localNetwork || hiddenService => false,
    cloudProvider || publicServer || modelHost || website => true,
  };
}

/// The receiver of a request: its kind, host and (non-default) port, plus
/// the name of a known service ("OpenAI", "Hugging Face").
class EgressDestination extends Equatable {
  const new({required this.kind, required this.host, this.port, this.name});

  final EgressDestinationKind kind;

  /// The host name or IP address, lower case (IPv6 without brackets).
  final String host;

  /// The port when it is not the scheme's default.
  final int? port;

  /// The name of a known service, if any.
  final String? name;

  /// `host` or `host:port` (`[::1]:8080` for IPv6).
  String get authority {
    final shown = host.contains(':') ? '[$host]' : host;
    return port == null ? shown : '$shown:$port';
  }

  @override
  List<Object?> get props => [kind, host, port, name];
}

/// How a request ended.
enum EgressOutcome {
  /// Sent; the answer has not finished yet.
  pending,

  /// The server answered (1xx to 3xx).
  succeeded,

  /// The server answered with an error (4xx or 5xx).
  httpError,

  /// No complete answer (no connection, an interrupted transfer, a
  /// timeout). The request may or may not have reached the server.
  failed,

  /// The app stopped the request or stopped reading the answer.
  cancelled,

  /// Refused before anything was sent (for example a broken proxy
  /// setting). Nothing left the device.
  notSent;

  /// Whether the request may have reached the destination.
  bool get mayHaveLeftDevice => this != notSent;
}

/// Why a request failed, as far as can be told without its details.
enum EgressFailure {
  /// It took too long.
  timeout,

  /// No connection to the server (or the proxy) could be made, or it broke.
  connection,

  /// The secure connection could not be set up (certificate, TLS).
  secureConnection,

  /// Anything else.
  other,
}

/// One request the app made: when, to whom, why, how much and how it
/// ended, but never what (no body, path, query or headers).
class EgressEntry extends Equatable {
  const new({
    required this.id,
    required this.startedAt,
    required this.method,
    required this.scheme,
    required this.destination,
    required this.purpose,
    this.viaProxy = false,
    this.bytesSent,
    this.bytesReceived = 0,
    this.statusCode,
    this.outcome = EgressOutcome.pending,
    this.failure,
    this.duration,
    this.redirectedTo,
  });

  /// Increasing within a ledger (0 for entries relayed from elsewhere
  /// until the ledger numbers them).
  final int id;
  final DateTime startedAt;

  /// `GET`, `POST`, ... (`OTHER` for anything unusual).
  final String method;

  /// `https` or `http` (unencrypted, only allowed for this device, the
  /// local network and Tor or I2P).
  final String scheme;
  final EgressDestination destination;
  final EgressPurpose purpose;

  /// Whether it went through the HTTP proxy of the settings.
  final bool viaProxy;

  /// Size of the body and of the address's path and query (headers and
  /// encryption not counted); null when the body's size was not known in
  /// advance.
  final int? bytesSent;

  /// Size of the answer's body received so far.
  final int bytesReceived;

  /// The HTTP status of the answer, once there is one.
  final int? statusCode;
  final EgressOutcome outcome;

  /// Why it [EgressOutcome.failed].
  final EgressFailure? failure;

  /// From sending to the end of the answer; null while [isPending].
  final Duration? duration;

  /// The host the request ended up at when the server redirected it to
  /// another one.
  final String? redirectedTo;

  /// Whether the user's text or photo may have reached [destination].
  bool get carriedContent =>
      outcome.mayHaveLeftDevice && purpose.carriesContent;

  bool get isPending => outcome == EgressOutcome.pending;

  EgressEntry copyWith({
    int? id,
    int? bytesReceived,
    int? statusCode,
    EgressOutcome? outcome,
    EgressFailure? failure,
    Duration? duration,
    String? redirectedTo,
  }) => EgressEntry(
    id: id ?? this.id,
    startedAt: startedAt,
    method: method,
    scheme: scheme,
    destination: destination,
    purpose: purpose,
    viaProxy: viaProxy,
    bytesSent: bytesSent,
    bytesReceived: bytesReceived ?? this.bytesReceived,
    statusCode: statusCode ?? this.statusCode,
    outcome: outcome ?? this.outcome,
    failure: failure ?? this.failure,
    duration: duration ?? this.duration,
    redirectedTo: redirectedTo ?? this.redirectedTo,
  );

  /// Plain values only, for handing the entry to another engine of this
  /// process ([EgressEntry.fromMap]).
  Map<String, Object?> toMap() => {
    'startedAt': startedAt.microsecondsSinceEpoch,
    'method': method,
    'scheme': scheme,
    'kind': destination.kind.name,
    'host': destination.host,
    'port': destination.port,
    'name': destination.name,
    'purpose': purpose.name,
    'viaProxy': viaProxy,
    'bytesSent': bytesSent,
    'bytesReceived': bytesReceived,
    'statusCode': statusCode,
    'outcome': outcome.name,
    'failure': failure?.name,
    'duration': duration?.inMicroseconds,
    'redirectedTo': redirectedTo,
  };

  /// The entry of [toMap], with id 0; null for anything malformed.
  static EgressEntry? fromMap(Object? value) {
    if (value is! Map) return null;
    T? pick<T extends Enum>(List<T> values, Object? name) {
      for (final candidate in values) {
        if (candidate.name == name) return candidate;
      }
      return null;
    }

    final kind = pick(EgressDestinationKind.values, value['kind']);
    final purpose = pick(EgressPurpose.values, value['purpose']);
    final outcome = pick(EgressOutcome.values, value['outcome']);
    final (startedAt, method, scheme, host) = (
      value['startedAt'],
      value['method'],
      value['scheme'],
      value['host'],
    );
    if (kind == null ||
        purpose == null ||
        outcome == null ||
        startedAt is! int ||
        method is! String ||
        scheme is! String ||
        host is! String) {
      return null;
    }
    final port = value['port'];
    final name = value['name'];
    final bytesSent = value['bytesSent'];
    final bytesReceived = value['bytesReceived'];
    final statusCode = value['statusCode'];
    final duration = value['duration'];
    final redirectedTo = value['redirectedTo'];
    return EgressEntry(
      id: 0,
      startedAt: DateTime.fromMicrosecondsSinceEpoch(startedAt),
      method: method,
      scheme: scheme,
      destination: EgressDestination(
        kind: kind,
        host: host,
        port: port is int ? port : null,
        name: name is String ? name : null,
      ),
      purpose: purpose,
      viaProxy: value['viaProxy'] == true,
      bytesSent: bytesSent is int ? bytesSent : null,
      bytesReceived: bytesReceived is int ? bytesReceived : 0,
      statusCode: statusCode is int ? statusCode : null,
      outcome: outcome,
      failure: pick(EgressFailure.values, value['failure']),
      duration: duration is int ? Duration(microseconds: duration) : null,
      redirectedTo: redirectedTo is String ? redirectedTo : null,
    );
  }

  @override
  List<Object?> get props => [
    id,
    startedAt,
    method,
    scheme,
    destination,
    purpose,
    viaProxy,
    bytesSent,
    bytesReceived,
    statusCode,
    outcome,
    failure,
    duration,
    redirectedTo,
  ];
}
