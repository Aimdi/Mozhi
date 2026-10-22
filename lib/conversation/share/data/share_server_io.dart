import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mozhi/conversation/share/data/guest_page.dart';
import 'package:mozhi/conversation/share/data/share_room.dart';
import 'package:mozhi/conversation/share/data/share_secrets.dart';
import 'package:mozhi/conversation/share/data/share_server.dart';
import 'package:mozhi/platform/lan_address.dart';

/// See `startShareServer` in `share_server.dart`.
Future<ShareServer> startShareServer({
  required String address,
  required ShareRoom room,
  required ShareStrings strings,
}) => IoShareServer.bind(address: address, room: room, strings: strings);

/// See `shareServerSupported` in `share_server.dart`.
bool get shareServerSupported => true;

/// The guests' side of a shared conversation: a plain `dart:io`
/// [HttpServer] bound to the phone's private address on a random port,
/// serving [ShareRoom] at `/s/<token>`:
///
/// * `GET /s/<token>`: the guest page (`guest_page.dart`, with `app.js`
///   and `app.css` next to it; nothing from anywhere else).
/// * `GET …/api/hello`: whether a PIN is needed and the languages.
/// * `POST …/api/join` (`{"language", "pin"}`): a guest id and key, which
///   later requests carry in `X-Mozhi-Guest` and `X-Mozhi-Key`.
/// * `GET …/api/events?guest=…&key=…`: Server-Sent Events, a `snapshot`
///   (the guest's view, [ShareRoom.snapshotFor]) after every change and
///   `ended` when the host stops.
/// * `POST …/api/language`, `…/api/reply`, `…/api/leave`.
///
/// Protections (the link is plain http on the local network): peers that
/// are not private IPv4 addresses are refused (`allowPeer` of [bind]);
/// the `Host` header must be the server's own address (no DNS
/// rebinding); POSTs must be JSON from the page's own origin (no
/// cross-site requests); a wrong token is a plain 404; every response
/// carries a strict Content-Security-Policy, `no-store` and
/// `no-referrer`, and no cookies.
/// Limits: [maxRequestsPerMinute] requests and [maxJoinsPerMinute] joins
/// (of which [maxWrongPinsPerMinute] wrong PINs) per address, request
/// bodies of [maxBodyBytes] arriving within [bodyTimeout], one update
/// stream per guest, and at most `maxConnections` connections at a time
/// (`maxConnectionsPerAddress` per address; more are closed as soon as
/// they open). Idle connections close after [idleTimeout]. An update
/// stream sends one snapshot at a time: while the page has not taken in
/// the last one, newer changes wait and are sent as one, and a page that
/// takes in nothing for `maxFlushTime` is disconnected (so a guest that
/// stops reading can't make the phone hold more and more data).
class IoShareServer implements ShareServer {
  new _(
    this._server,
    this._sockets,
    this._room,
    this._strings,
    this._address,
    this._allowPeer,
    this._maxFlushTime,
    DateTime Function()? clock,
  ) : port = _server.port,
      _requests = ShareRateLimiter(
        max: maxRequestsPerMinute,
        per: const Duration(minutes: 1),
        clock: clock,
      ),
      _joins = ShareRateLimiter(
        max: maxJoinsPerMinute,
        per: const Duration(minutes: 1),
        clock: clock,
      ),
      _wrongPins = ShareRateLimiter(
        max: maxWrongPinsPerMinute,
        per: const Duration(minutes: 1),
        clock: clock,
      );

  /// Binds to [address] (a private IPv4 address of the phone) on a random
  /// free port. [allowPeer] decides which clients may connect (default:
  /// private IPv4 addresses, [isPrivateIPv4]); [pingInterval] keeps the
  /// update streams open through idle timeouts. At most [maxConnections]
  /// connections are open at a time, [maxConnectionsPerAddress] from one
  /// address; an update stream whose page takes in nothing for
  /// [maxFlushTime] is closed.
  static Future<IoShareServer> bind({
    required String address,
    required ShareRoom room,
    required ShareStrings strings,
    bool Function(InternetAddress peer)? allowPeer,
    Duration pingInterval = const Duration(seconds: 15),
    int maxConnections = defaultMaxConnections,
    int maxConnectionsPerAddress = defaultMaxConnectionsPerAddress,
    Duration maxFlushTime = defaultMaxFlushTime,
    DateTime Function()? clock,
  }) async {
    final sockets = _ConnectionGate(
      await ServerSocket.bind(
        InternetAddress(address, type: InternetAddressType.IPv4),
        0,
      ),
      maxConnections: maxConnections,
      maxPerAddress: maxConnectionsPerAddress,
    );
    final server = HttpServer.listenOn(sockets)
      ..idleTimeout = idleTimeout
      ..autoCompress = false
      ..serverHeader = null
      ..defaultResponseHeaders.clear();
    final result = IoShareServer._(
      server,
      sockets,
      room,
      strings,
      address,
      allowPeer ?? _privatePeer,
      maxFlushTime,
      clock,
    ).._pingInterval = pingInterval;
    result
      .._requestsSubscription = server.listen(
        (request) => unawaited(result._handle(request)),
        onError: (Object _) {}, // coverage:ignore-line
      )
      .._roomChanges = room.changes.listen((_) => result._onRoomChanged());
    return result;
  }

  /// Requests per client address and minute (the update streams'
  /// reconnections included).
  static const maxRequestsPerMinute = 120;

  /// Join attempts per client address and minute.
  static const maxJoinsPerMinute = 10;

  /// Wrong PINs per client address and minute.
  static const maxWrongPinsPerMinute = 5;

  /// The largest request body.
  static const maxBodyBytes = 4096;

  /// How long a request body may take to arrive.
  static const bodyTimeout = Duration(seconds: 10);

  /// After how long without a request a connection is closed (one that
  /// stays idle is closed between one and two times this).
  static const idleTimeout = Duration(seconds: 10);

  /// Connections open at a time (guests' pages use a few each).
  static const defaultMaxConnections = 64;

  /// Connections open at a time from one address.
  static const defaultMaxConnectionsPerAddress = 16;

  /// How long an update stream may wait for its page to take in what it
  /// was sent before it is closed (the page then connects again).
  static const defaultMaxFlushTime = Duration(seconds: 20);

  /// How often a guest's page gets at most one new snapshot.
  static const snapshotInterval = Duration(milliseconds: 150);

  static const _headerGuest = 'x-mozhi-guest';
  static const _headerKey = 'x-mozhi-key';

  final HttpServer _server;
  final _ConnectionGate _sockets;
  final ShareRoom _room;
  final ShareStrings _strings;
  final String _address;
  final bool Function(InternetAddress peer) _allowPeer;
  final Duration _maxFlushTime;
  final ShareRateLimiter _requests;
  final ShareRateLimiter _joins;
  final ShareRateLimiter _wrongPins;
  late Duration _pingInterval;
  late final StreamSubscription<HttpRequest> _requestsSubscription;
  late final StreamSubscription<void> _roomChanges;
  final Map<String, _EventStream> _streams = {};
  bool _closed = false;

  @override
  Uri get url => Uri(
    scheme: 'http',
    host: _address,
    port: port,
    path: '/s/${_room.token}',
  );

  /// The port the server listens (or listened) on.
  final int port;

  String get _base => '/s/${_room.token}';

  String get _origin => 'http://$_address:$port';

  static bool _privatePeer(InternetAddress peer) =>
      peer.type == InternetAddressType.IPv4 && isPrivateIPv4(peer.address);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _roomChanges.cancel();
    final streams = _streams.values.toList();
    _streams.clear();
    await Future.wait([for (final stream in streams) stream.end()]);
    await _requestsSubscription.cancel();
    await _server.close(force: true);
    // A server listening on a socket of its own does not close it.
    await _sockets.close();
  }

  void _onRoomChanged() {
    if (_room.ended) {
      unawaited(close());
      return;
    }
    for (final stream in _streams.values) {
      stream.schedule();
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      _secure(response.headers);
      final peer = request.connectionInfo?.remoteAddress;
      if (peer == null || !_allowPeer(peer)) {
        return await _status(response, HttpStatus.forbidden);
      }
      if (request.headers.host != _address || request.headers.port != port) {
        return await _status(response, HttpStatus.misdirectedRequest);
      }
      if (!_requests.allow(peer.address)) {
        return await _status(response, HttpStatus.tooManyRequests);
      }
      final segments = request.uri.pathSegments;
      if (_closed ||
          _room.ended ||
          segments.length < 2 ||
          segments[0] != 's' ||
          !constantTimeEquals(segments[1], _room.token)) {
        return await _status(response, HttpStatus.notFound);
      }
      final path = segments.skip(2).where((s) => s.isNotEmpty).join('/');
      if (request.method == 'GET') {
        return await switch (path) {
          '' => _page(request),
          'app.js' => _text(
            response,
            guestPageScript,
            ContentType('text', 'javascript', charset: 'utf-8'),
          ),
          'app.css' => _text(
            response,
            guestPageCss,
            ContentType('text', 'css', charset: 'utf-8'),
          ),
          'api/hello' => _json(response, HttpStatus.ok, _hello()),
          'api/events' => _events(request),
          _ => _status(response, HttpStatus.notFound),
        };
      }
      if (request.method != 'POST') {
        return await _status(response, HttpStatus.methodNotAllowed);
      }
      final origin = request.headers.value('origin');
      if (origin != null && origin != _origin) {
        return await _status(response, HttpStatus.forbidden);
      }
      final body = await _readJson(request);
      if (body == null) return await _status(response, HttpStatus.badRequest);
      return await switch (path) {
        'api/join' => _join(request, peer.address, body),
        'api/language' => _language(request, body),
        'api/reply' => _reply(request, body),
        'api/leave' => _leave(request),
        _ => _status(response, HttpStatus.notFound),
      };
    } on Object {
      // A broken connection or a request that cannot be answered.
      // coverage:ignore-start
      try {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      } on Object {
        // Already gone.
      }
      // coverage:ignore-end
    }
  }

  /// The headers of every response.
  static void _secure(HttpHeaders headers) {
    headers
      ..set(
        'Content-Security-Policy',
        "default-src 'none'; script-src 'self'; style-src 'self'; "
            "connect-src 'self'; img-src 'self' data:; base-uri 'none'; "
            "form-action 'none'; frame-ancestors 'none'",
      )
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('Referrer-Policy', 'no-referrer')
      ..set('Cache-Control', 'no-store')
      ..set('X-Frame-Options', 'DENY')
      ..set('Cross-Origin-Opener-Policy', 'same-origin')
      ..set('Cross-Origin-Resource-Policy', 'same-origin')
      ..set(
        'Permissions-Policy',
        'camera=(), microphone=(), geolocation=(), interest-cohort=()',
      )
      ..set('X-Robots-Tag', 'noindex, nofollow');
  }

  Future<void> _status(HttpResponse response, int status) async {
    response.statusCode = status;
    await response.close();
  }

  Future<void> _text(
    HttpResponse response,
    String text,
    ContentType type,
  ) async {
    response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = type
      ..write(text);
    await response.close();
  }

  Future<void> _json(
    HttpResponse response,
    int status,
    Map<String, Object?> body,
  ) async {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await response.close();
  }

  /// The JSON object of a POST, or null when it is not JSON or too large.
  Future<Map<String, Object?>?> _readJson(HttpRequest request) async {
    if (request.headers.contentType?.mimeType != ContentType.json.mimeType) {
      return null;
    }
    if (request.contentLength > maxBodyBytes) return null;
    final bytes = BytesBuilder(copy: false);
    final elapsed = Stopwatch()..start();
    try {
      await for (final chunk in request.timeout(bodyTimeout)) {
        bytes.add(chunk);
        if (bytes.length > maxBodyBytes || elapsed.elapsed > bodyTimeout) {
          return null;
        }
      }
    } on TimeoutException {
      return null;
    }
    try {
      final json = jsonDecode(utf8.decode(bytes.takeBytes()));
      return json is Map<String, Object?> ? json : null;
    } on FormatException {
      return null;
    }
  }

  /// The browser's languages, best first (`Accept-Language`).
  static List<String> _accepted(HttpRequest request) {
    final header = request.headers.value('accept-language') ?? '';
    final weighted = <(String, double)>[];
    for (final part in header.split(',')) {
      final pieces = part.trim().split(';');
      final code = pieces.first.trim();
      if (code.isEmpty || code == '*') continue;
      var quality = 1.0;
      for (final piece in pieces.skip(1)) {
        final value = piece.trim();
        if (value.startsWith('q=')) {
          quality = double.tryParse(value.substring(2)) ?? 0;
        }
      }
      if (quality > 0) weighted.add((code, quality));
    }
    // A stable sort: equal weights keep the browser's order.
    final indexed = weighted.indexed.toList()
      ..sort((a, b) {
        final byQuality = b.$2.$2.compareTo(a.$2.$2);
        return byQuality != 0 ? byQuality : a.$1.compareTo(b.$1);
      });
    return [for (final (_, (code, _)) in indexed) code];
  }

  Map<String, Object?> _hello() => {
    'pin': _room.pin != null,
    'languages': _room.languageList(),
  };

  Future<void> _page(HttpRequest request) => _text(
    request.response,
    renderGuestPage(
      base: _base,
      config: {..._hello(), 'maxReply': ShareRoom.maxReplyLength},
      l10n: _strings(_accepted(request)),
    ),
    ContentType.html,
  );

  ShareGuest? _guestOf(HttpRequest request) => _room.authenticate(
    request.headers.value(_headerGuest),
    request.headers.value(_headerKey),
  );

  Future<void> _join(
    HttpRequest request,
    String peer,
    Map<String, Object?> body,
  ) {
    final response = request.response;
    if (!_wrongPins.allows(peer) || !_joins.allow(peer)) {
      return _status(response, HttpStatus.tooManyRequests);
    }
    final language = body['language'];
    final pin = body['pin'];
    if (language is! String || (pin != null && pin is! String)) {
      return _status(response, HttpStatus.badRequest);
    }
    final result = _room.join(
      languageCode: language,
      pin: pin as String?,
      client: peer,
    );
    switch (result) {
      case ShareJoined(:final guest, :final key):
        return _json(response, HttpStatus.ok, {
          'guest': guest.id,
          'key': key,
          'language': guest.language.code,
          'strings': _stringsFor(guest, request),
        });
      case ShareJoinRefused(error: ShareJoinError.languageLimit):
        return _languageLimit(response);
      case ShareJoinRefused(:final error):
        if (error == ShareJoinError.wrongPin) _wrongPins.allow(peer);
        return _status(response, switch (error) {
          ShareJoinError.wrongPin => HttpStatus.forbidden,
          ShareJoinError.locked => HttpStatus.locked,
          // (The language limit is answered above.)
          ShareJoinError.full ||
          ShareJoinError.languageLimit => HttpStatus.conflict,
          ShareJoinError.tooMany => HttpStatus.tooManyRequests,
          ShareJoinError.unknownLanguage => HttpStatus.badRequest,
          // An ended room answers 404 before this.
          ShareJoinError.ended => HttpStatus.gone, // coverage:ignore-line
        });
    }
  }

  Map<String, String> _stringsFor(ShareGuest guest, HttpRequest request) =>
      guestPageStrings(_strings([guest.language.code, ..._accepted(request)]));

  /// No other language can be added ([ShareRoom.canRead]): which ones the
  /// guest may pick instead.
  Future<void> _languageLimit(HttpResponse response) =>
      _json(response, HttpStatus.conflict, {
        'error': 'languageLimit',
        'languages': [
          for (final language in _room.readableLanguages) language.code,
        ],
      });

  Future<void> _language(HttpRequest request, Map<String, Object?> body) {
    final response = request.response;
    final guest = _guestOf(request);
    if (guest == null) return _status(response, HttpStatus.unauthorized);
    final language = body['language'];
    if (language is! String) return _status(response, HttpStatus.badRequest);
    final wanted = _room.languageOf(language);
    if (wanted == null) return _status(response, HttpStatus.badRequest);
    if (!_room.canRead(wanted)) return _languageLimit(response);
    if (!_room.setLanguage(guest, language)) {
      return _status(response, HttpStatus.tooManyRequests);
    }
    final updated = _room.authenticate(
      request.headers.value(_headerGuest),
      request.headers.value(_headerKey),
    );
    return _json(response, HttpStatus.ok, {
      'strings': _stringsFor(updated ?? guest, request),
    });
  }

  Future<void> _reply(HttpRequest request, Map<String, Object?> body) {
    final response = request.response;
    final guest = _guestOf(request);
    if (guest == null) return _status(response, HttpStatus.unauthorized);
    final text = body['text'];
    if (text is! String) return _status(response, HttpStatus.badRequest);
    return _status(response, switch (_room.reply(guest, text)) {
      ShareReplyResult.sent => HttpStatus.noContent,
      ShareReplyResult.empty => HttpStatus.badRequest,
      ShareReplyResult.tooLong => HttpStatus.requestEntityTooLarge,
      ShareReplyResult.tooFast => HttpStatus.tooManyRequests,
      ShareReplyResult.disabled => HttpStatus.forbidden,
      // A guest that is gone is unauthorized before this.
      ShareReplyResult.ended => HttpStatus.gone, // coverage:ignore-line
    });
  }

  Future<void> _leave(HttpRequest request) {
    final guest = _guestOf(request);
    if (guest == null) {
      return _status(request.response, HttpStatus.unauthorized);
    }
    _streams.remove(guest.id)?.end().ignore();
    _room.leave(guest);
    return _status(request.response, HttpStatus.noContent);
  }

  Future<void> _events(HttpRequest request) async {
    final response = request.response;
    final query = request.uri.queryParameters;
    final guest = _room.authenticate(query['guest'], query['key']);
    if (guest == null) return await _status(response, HttpStatus.unauthorized);
    // A newer page of the same guest (a reload) replaces the old stream.
    await _streams.remove(guest.id)?.end(replaced: true);
    response
      ..statusCode = HttpStatus.ok
      ..bufferOutput = false
      ..headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      )
      ..headers.set('X-Accel-Buffering', 'no');
    final stream = _EventStream(
      response,
      guest.id,
      snapshot: () =>
          switch (_room.authenticate(query['guest'], query['key'])) {
            final current? => _room.snapshotFor(current),
            null => null,
          },
      pingInterval: _pingInterval,
      maxFlushTime: _maxFlushTime,
      onDone: (stream) {
        if (identical(_streams[guest.id], stream)) {
          _streams.remove(guest.id);
        }
        _room.disconnected(guest);
      },
    );
    _streams[guest.id] = stream;
    _room.connected(guest);
    stream.start();
  }
}

/// One guest page's Server-Sent Events stream. One write is in flight at
/// a time: changes while the page has not taken in the last write wait
/// (and are sent as one snapshot), and a page that takes in nothing for
/// `maxFlushTime` is disconnected.
class _EventStream {
  new(
    this._response,
    this.guestId, {
    required this._snapshot,
    required this._pingInterval,
    required this._maxFlushTime,
    required this._onDone,
  });

  /// How long [end] waits for the last event to go out.
  static const _endTimeout = Duration(seconds: 2);

  final HttpResponse _response;
  final String guestId;
  final Map<String, Object?>? Function() _snapshot;
  final Duration _pingInterval;
  final Duration _maxFlushTime;
  final void Function(_EventStream stream) _onDone;
  Timer? _ping;
  Timer? _pending;

  /// The page has not taken in the last write yet.
  bool _flushing = false;

  /// A snapshot is due once it has.
  bool _behind = false;
  Timer? _stuck;
  bool _done = false;

  void start() {
    _send(prefix: 'retry: 3000\n\n');
    _ping = Timer.periodic(_pingInterval, (_) {
      if (!_flushing) _write(': ping\n\n');
    });
    unawaited(
      _response.done
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(_finish),
    );
  }

  /// Sends a snapshot soon (several changes in a row make one).
  void schedule() {
    if (_done || _pending != null) return;
    _pending = Timer(IoShareServer.snapshotInterval, () {
      _pending = null;
      _send();
    });
  }

  void _send({String prefix = ''}) {
    if (_done) return;
    if (_flushing) {
      // Skipped: the page gets the latest snapshot once it caught up.
      _behind = true;
      return;
    }
    final snapshot = _snapshot();
    if (snapshot == null) {
      unawaited(end());
      return;
    }
    _write('${prefix}event: snapshot\ndata: ${jsonEncode(snapshot)}\n\n');
  }

  void _write(String text) {
    if (_done || _flushing) return;
    try {
      _response.write(text);
      _flushing = true;
      _stuck = Timer(_maxFlushTime, _drop);
      unawaited(
        _response.flush().then<void>((_) {
          _flushing = false;
          _stuck?.cancel();
          _stuck = null;
          if (_behind) {
            _behind = false;
            _send();
          }
        }, onError: (Object _) => _drop()),
      );
    } on Object {
      _drop(); // coverage:ignore-line
    }
  }

  /// Disconnects a page that takes in nothing (or whose connection
  /// broke): what waits for it is dropped with the connection.
  void _drop() {
    if (_done) return;
    _finish();
    // Closes the connection at once, whatever it still holds.
    _response.deadline = Duration.zero;
  }

  /// Tells the page the conversation ended (unless another page of the
  /// guest [replaced] it) and closes the stream.
  Future<void> end({bool replaced = false}) async {
    if (_done) return;
    if (_flushing) return _drop();
    _finish();
    try {
      if (!replaced) _response.write('event: ended\ndata: {}\n\n');
      // A page that does not take it in is disconnected.
      _response.deadline = _maxFlushTime;
      await _response.close().timeout(_endTimeout);
    } on Object {
      // The page is gone already, or does not read.
    }
  }

  void _finish() {
    if (_done) return;
    _done = true;
    _ping?.cancel();
    _pending?.cancel();
    _stuck?.cancel();
    _onDone(this);
  }
}

/// The server's listening socket, which closes a new connection at once
/// when [maxConnections] are open, or [maxPerAddress] from its address.
class _ConnectionGate extends Stream<Socket> implements ServerSocket {
  new(
    this._socket, {
    required this.maxConnections,
    required this.maxPerAddress,
  });

  final ServerSocket _socket;
  final int maxConnections;
  final int maxPerAddress;
  final Map<String, int> _open = {};
  int _total = 0;

  @override
  StreamSubscription<Socket> listen(
    void Function(Socket socket)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _socket
      .map(_admit)
      .where((socket) => socket != null)
      .cast<Socket>()
      .listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  Socket? _admit(Socket socket) {
    final String address;
    try {
      address = socket.remoteAddress.address;
    } on Object {
      // Closed already. coverage:ignore-start
      socket.destroy();
      return null;
      // coverage:ignore-end
    }
    final open = _open[address] ?? 0;
    if (_total >= maxConnections || open >= maxPerAddress) {
      socket.destroy();
      return null;
    }
    _total++;
    _open[address] = open + 1;
    return _CountedSocket(socket, () {
      _total--;
      final left = (_open[address] ?? 1) - 1;
      if (left > 0) {
        _open[address] = left;
      } else {
        _open.remove(address);
      }
    });
  }

  @override
  int get port => _socket.port;

  @override
  InternetAddress get address => _socket.address;

  @override
  Future<ServerSocket> close() async {
    await _socket.close();
    return this;
  }
}

/// A connection that tells [_onClosed] (once) when it closes: the HTTP
/// server destroys every connection it is done with, and the stream ends
/// when the client closes it.
class _CountedSocket extends Stream<Uint8List> implements Socket {
  new(this._socket, this._onClosed);

  final Socket _socket;
  final void Function() _onClosed;
  bool _closed = false;

  void _close() {
    if (_closed) return;
    _closed = true;
    _onClosed();
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List data)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _socket.listen(
    onData,
    onError: onError,
    onDone: () {
      _close();
      onDone?.call();
    },
    cancelOnError: cancelOnError,
  );

  @override
  void destroy() {
    _close();
    _socket.destroy();
  }

  @override
  Future<void> close() {
    _close();
    return _socket.close();
  }

  @override
  void add(List<int> data) => _socket.add(data);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _socket.addStream(stream);

  @override
  Future<void> flush() => _socket.flush();

  @override
  Future<void> get done => _socket.done;

  @override
  InternetAddress get address => _socket.address;

  @override
  int get port => _socket.port;

  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;

  @override
  int get remotePort => _socket.remotePort;

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _socket.setOption(option, enabled);

  // The HTTP server uses none of these. coverage:ignore-start
  @override
  Encoding get encoding => _socket.encoding;

  @override
  set encoding(Encoding value) => _socket.encoding = value;

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _socket.addError(error, stackTrace);

  @override
  void write(Object? object) => _socket.write(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _socket.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _socket.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _socket.writeln(object);

  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _socket.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _socket.setRawOption(option);
  // coverage:ignore-end
}
