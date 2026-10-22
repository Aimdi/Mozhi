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
/// bodies of [maxBodyBytes], one update stream per guest.
class IoShareServer implements ShareServer {
  new _(
    this._server,
    this._room,
    this._strings,
    this._address,
    this._allowPeer,
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
  /// update streams open through idle timeouts.
  static Future<IoShareServer> bind({
    required String address,
    required ShareRoom room,
    required ShareStrings strings,
    bool Function(InternetAddress peer)? allowPeer,
    Duration pingInterval = const Duration(seconds: 15),
    DateTime Function()? clock,
  }) async {
    final server = await HttpServer.bind(
      InternetAddress(address, type: InternetAddressType.IPv4),
      0,
    );
    server
      ..idleTimeout = const Duration(seconds: 30)
      ..autoCompress = false
      ..serverHeader = null
      ..defaultResponseHeaders.clear();
    final result = IoShareServer._(
      server,
      room,
      strings,
      address,
      allowPeer ?? _privatePeer,
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

  /// How often a guest's page gets at most one new snapshot.
  static const snapshotInterval = Duration(milliseconds: 150);

  static const _headerGuest = 'x-mozhi-guest';
  static const _headerKey = 'x-mozhi-key';

  final HttpServer _server;
  final ShareRoom _room;
  final ShareStrings _strings;
  final String _address;
  final bool Function(InternetAddress peer) _allowPeer;
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
    await for (final chunk in request.timeout(const Duration(seconds: 10))) {
      bytes.add(chunk);
      if (bytes.length > maxBodyBytes) return null;
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
    final result = _room.join(languageCode: language, pin: pin as String?);
    switch (result) {
      case ShareJoined(:final guest, :final key):
        return _json(response, HttpStatus.ok, {
          'guest': guest.id,
          'key': key,
          'language': guest.language.code,
          'strings': _stringsFor(guest, request),
        });
      case ShareJoinRefused(:final error):
        if (error == ShareJoinError.wrongPin) _wrongPins.allow(peer);
        return _status(response, switch (error) {
          ShareJoinError.wrongPin => HttpStatus.forbidden,
          ShareJoinError.locked => HttpStatus.locked,
          ShareJoinError.full => HttpStatus.conflict,
          ShareJoinError.unknownLanguage => HttpStatus.badRequest,
          // An ended room answers 404 before this.
          ShareJoinError.ended => HttpStatus.gone, // coverage:ignore-line
        });
    }
  }

  Map<String, String> _stringsFor(ShareGuest guest, HttpRequest request) =>
      guestPageStrings(_strings([guest.language.code, ..._accepted(request)]));

  Future<void> _language(HttpRequest request, Map<String, Object?> body) {
    final response = request.response;
    final guest = _guestOf(request);
    if (guest == null) return _status(response, HttpStatus.unauthorized);
    final language = body['language'];
    if (language is! String) return _status(response, HttpStatus.badRequest);
    if (_room.languageOf(language) == null) {
      return _status(response, HttpStatus.badRequest);
    }
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

/// One guest page's Server-Sent Events stream.
class _EventStream {
  new(
    this._response,
    this.guestId, {
    required this._snapshot,
    required this._pingInterval,
    required this._onDone,
  });

  final HttpResponse _response;
  final String guestId;
  final Map<String, Object?>? Function() _snapshot;
  final Duration _pingInterval;
  final void Function(_EventStream stream) _onDone;
  Timer? _ping;
  Timer? _pending;
  bool _done = false;

  void start() {
    _write('retry: 3000\n\n');
    _send();
    _ping = Timer.periodic(_pingInterval, (_) => _write(': ping\n\n'));
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

  void _send() {
    final snapshot = _snapshot();
    if (snapshot == null) {
      unawaited(end());
      return;
    }
    _write('event: snapshot\ndata: ${jsonEncode(snapshot)}\n\n');
  }

  void _write(String text) {
    if (_done) return;
    try {
      _response.write(text);
    } on Object {
      _finish(); // coverage:ignore-line
    }
  }

  /// Tells the page the conversation ended (unless another page of the
  /// guest [replaced] it) and closes the stream.
  Future<void> end({bool replaced = false}) async {
    if (_done) return;
    if (!replaced) _write('event: ended\ndata: {}\n\n');
    _finish();
    try {
      await _response.close();
    } on Object {
      // The page is gone already.
    }
  }

  void _finish() {
    if (_done) return;
    _done = true;
    _ping?.cancel();
    _pending?.cancel();
    _onDone(this);
  }
}
