import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:mozhi/conversation/share/data/share_room.dart';
import 'package:mozhi/conversation/share/data/share_secrets.dart';
import 'package:mozhi/conversation/share/data/share_server.dart';
import 'package:mozhi/conversation/share/data/share_server_io.dart' as io;
import 'package:mozhi/conversation/share/data/share_translations.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers.dart';

class MockShareTranslations extends Mock implements ShareTranslations;

typedef _Response = ({int status, HttpHeaders headers, String body});

void main() {
  setUpAll(() {
    registerConversationFallbacks();
    registerFallbackValue(<ConversationTurn>[]);
    registerFallbackValue(<Language>[]);
    registerFallbackValue(turnOf());
  });

  late MockShareTranslations translations;
  late List<(ShareGuest, String)> replies;
  late ShareRoom room;
  late io.IoShareServer server;
  late HttpClient client;

  setUp(() async {
    translations = MockShareTranslations();
    when(() => translations.changes).thenAnswer((_) => const Stream.empty());
    when(() => translations.ensure(any(), any())).thenReturn(null);
    when(translations.dispose).thenAnswer((_) async {});
    when(() => translations.textOf(any(), any())).thenAnswer(
      (invocation) => (
        text: (invocation.positionalArguments[0] as ConversationTurn).original,
        status: ShareTextStatus.original,
      ),
    );
    replies = [];
    room = ShareRoom(
      token: 'abcdefghijklmnopqrstuv',
      languages: const [english, spanish, french],
      translations: translations,
      onReply: (guest, text) => replies.add((guest, text)),
      pin: '1234',
      secrets: ShareSecrets(Random(3)),
    );
    server = await io.IoShareServer.bind(
      address: '127.0.0.1',
      room: room,
      strings: shareStrings,
      allowPeer: (_) => true,
      pingInterval: const Duration(milliseconds: 50),
    );
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.close();
    await room.end();
  });

  String path(String rest) => '/s/abcdefghijklmnopqrstuv$rest';

  Future<_Response> send(
    String method,
    String location, {
    Map<String, String> headers = const {},
    Object? json,
    String? body,
    String contentType = 'application/json',
    int? port,
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${port ?? server.port}$location'),
    );
    headers.forEach(request.headers.set);
    final payload = body ?? (json == null ? null : jsonEncode(json));
    if (payload != null) {
      request.headers.set('content-type', contentType);
      request.write(payload);
    }
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    return (status: response.statusCode, headers: response.headers, body: text);
  }

  Future<ShareJoined> join({String language = 'fr'}) async {
    final response = await send(
      'POST',
      path('/api/join'),
      json: {'language': language, 'pin': '1234'},
    );
    expect(response.status, HttpStatus.ok);
    final body = jsonDecode(response.body) as Map<String, Object?>;
    final guest = room.authenticate(
      body['guest']! as String,
      body['key']! as String,
    )!;
    return ShareJoined(guest, body['key']! as String);
  }

  Map<String, String> auth(ShareJoined joined) => {
    'X-Mozhi-Guest': joined.guest.id,
    'X-Mozhi-Key': joined.key,
  };

  test('has the guests link', () {
    expect(
      server.url.toString(),
      'http://127.0.0.1:${server.port}/s/abcdefghijklmnopqrstuv',
    );
  });

  group('the page', () {
    test('is served with strict headers and no cookies', () async {
      final response = await send('GET', path(''));

      expect(response.status, HttpStatus.ok);
      expect(response.headers.contentType?.mimeType, 'text/html');
      expect(
        response.headers.value('content-security-policy'),
        allOf(
          contains("default-src 'none'"),
          contains("script-src 'self'"),
          contains("connect-src 'self'"),
          contains("frame-ancestors 'none'"),
        ),
      );
      expect(response.headers.value('x-content-type-options'), 'nosniff');
      expect(response.headers.value('referrer-policy'), 'no-referrer');
      expect(response.headers.value('cache-control'), 'no-store');
      expect(response.headers.value('x-frame-options'), 'DENY');
      expect(response.headers.value('set-cookie'), isNull);
      expect(response.headers.value('server'), isNull);
      expect(
        response.body,
        contains('<script src="/s/abcdefghijklmnopqrstuv/app.js"'),
      );
      expect(response.body, isNot(contains('http://')));
      expect(response.body, isNot(contains('https://')));
      final config = RegExp(
        '<script type="application/json" id="config">(.*?)</script>',
      ).firstMatch(response.body)!.group(1)!;
      final json = jsonDecode(config) as Map<String, Object?>;
      expect(json['pin'], isTrue);
      expect(json['base'], '/s/abcdefghijklmnopqrstuv');
      expect(json['languages'], hasLength(3));
      expect((json['strings']! as Map)['_locale'], 'en');
    });

    test('speaks the browser language', () async {
      final response = await send(
        'GET',
        path('/'),
        headers: {'Accept-Language': 'xx, fr-CH;q=0.9, en;q=0.8'},
      );

      expect(response.body, contains('<html lang="fr" dir="ltr">'));
    });

    test('serves its script and style', () async {
      final script = await send('GET', path('/app.js'));
      final style = await send('GET', path('/app.css'));

      expect(script.status, HttpStatus.ok);
      expect(script.headers.contentType?.mimeType, 'text/javascript');
      expect(script.body, contains('EventSource'));
      expect(style.headers.contentType?.mimeType, 'text/css');
      expect(style.body, contains('prefers-color-scheme:dark'));
    });

    test('says hello', () async {
      final response = await send('GET', path('/api/hello'));

      expect(jsonDecode(response.body), {
        'pin': true,
        'languages': room.languageList(),
      });
    });
  });

  group('refuses', () {
    test('wrong tokens and paths', () async {
      expect((await send('GET', '/s/wrong')).status, HttpStatus.notFound);
      expect((await send('GET', '/')).status, HttpStatus.notFound);
      expect((await send('GET', '/x/abcdefghijklmnopqrstuv')).status, 404);
      expect((await send('GET', path('/nothing'))).status, 404);
      expect(
        (await send('POST', path('/api/nothing'), json: {})).status,
        HttpStatus.notFound,
      );
      expect((await send('PUT', path(''))).status, HttpStatus.methodNotAllowed);
    });

    test('other host names (DNS rebinding)', () async {
      final response = await send(
        'GET',
        path(''),
        headers: {'Host': 'evil.example:${server.port}'},
      );

      expect(response.status, HttpStatus.misdirectedRequest);
    });

    test('peers that are not on the local network', () async {
      final strict = await io.IoShareServer.bind(
        address: '127.0.0.1',
        room: room,
        strings: shareStrings,
      );
      addTearDown(strict.close);
      final request = await client.getUrl(strict.url);
      final response = await request.close();
      await response.drain<void>();

      // Loopback is not a private address of a local network.
      expect(response.statusCode, HttpStatus.forbidden);
    });

    test('requests that are not JSON of the page', () async {
      expect(
        (await send(
          'POST',
          path('/api/join'),
          body: 'language=fr',
          contentType: 'application/x-www-form-urlencoded',
        )).status,
        HttpStatus.badRequest,
      );
      expect(
        (await send('POST', path('/api/join'), body: '[1]')).status,
        HttpStatus.badRequest,
      );
      expect(
        (await send('POST', path('/api/join'), body: '{')).status,
        HttpStatus.badRequest,
      );
      expect(
        (await send(
          'POST',
          path('/api/join'),
          json: {'language': 'fr', 'pin': 'x' * 5000},
        )).status,
        HttpStatus.badRequest,
      );
      expect(
        (await send(
          'POST',
          path('/api/join'),
          headers: {'Origin': 'http://evil.example'},
          json: {'language': 'fr', 'pin': '1234'},
        )).status,
        HttpStatus.forbidden,
      );
      expect(room.guests, isEmpty);
    });

    test('too many requests from one address', () async {
      var limited = false;
      for (var i = 0; i <= io.IoShareServer.maxRequestsPerMinute; i++) {
        final response = await send('GET', path('/api/hello'));
        limited = response.status == HttpStatus.tooManyRequests;
      }

      expect(limited, isTrue);
    });

    test('connections beyond the limits', () async {
      final capped = await io.IoShareServer.bind(
        address: '127.0.0.1',
        room: room,
        strings: shareStrings,
        allowPeer: (_) => true,
        maxConnections: 3,
        maxConnectionsPerAddress: 2,
      );
      addTearDown(capped.close);
      final sockets = <Socket>[];
      addTearDown(() {
        for (final socket in sockets) {
          socket.destroy();
        }
      });

      /// Whether a new connection from [from] stays open.
      Future<bool> stays(String from) async {
        final socket = await Socket.connect(
          '127.0.0.1',
          capped.port,
          sourceAddress: from,
        );
        sockets.add(socket);
        final closed = Completer<bool>();
        socket.listen(
          (_) {},
          onError: (Object _) {
            if (!closed.isCompleted) closed.complete(true);
          },
          onDone: () {
            if (!closed.isCompleted) closed.complete(true);
          },
        );
        return !await closed.future.timeout(
          const Duration(milliseconds: 300),
          onTimeout: () => false,
        );
      }

      expect(await stays('127.0.0.1'), isTrue);
      expect(await stays('127.0.0.1'), isTrue);
      expect(await stays('127.0.0.1'), isFalse);
      expect(await stays('127.0.0.2'), isTrue);
      expect(await stays('127.0.0.2'), isFalse);

      // A connection that closes makes room for another.
      sockets.first.destroy();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${capped.port}${path('/api/hello')}'),
      );
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, HttpStatus.ok);
    });

    test('bodies that take too long', () async {
      final strict = await io.IoShareServer.bind(
        address: '127.0.0.1',
        room: room,
        strings: shareStrings,
        allowPeer: (_) => true,
        bodyTimeout: const Duration(milliseconds: 200),
      );
      addTearDown(strict.close);

      /// The status line answering a join whose body comes [slowly] (a
      /// byte every 100 ms) or never.
      Future<String> answer({required bool slowly}) async {
        final socket = await Socket.connect('127.0.0.1', strict.port);
        addTearDown(socket.destroy);
        // The server may close it while the slow body still comes.
        socket.done.ignore();
        socket.write(
          'POST ${path('/api/join')} HTTP/1.1\r\n'
          'Host: 127.0.0.1:${strict.port}\r\n'
          'Content-Type: application/json\r\n'
          'Content-Length: 100\r\n\r\n{',
        );
        final lines = utf8.decoder.bind(socket).transform(const LineSplitter());
        final first = lines.first;
        if (slowly) {
          for (var i = 0; i < 5; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            socket.write(' ');
          }
        }
        return await first.timeout(const Duration(seconds: 5));
      }

      expect(await answer(slowly: false), contains('400'));
      expect(await answer(slowly: true), contains('400'));
    });

    test('bodies that are too large or cut off', () async {
      // Sent in chunks: no length announced.
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}${path('/api/join')}'),
      );
      request.headers.contentType = ContentType.json;
      request.write('{"pin": "${'1' * 5000}"}');
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, HttpStatus.badRequest);

      final socket = await Socket.connect('127.0.0.1', server.port);
      socket.done.ignore();
      socket.write(
        'POST ${path('/api/join')} HTTP/1.1\r\n'
        'Host: 127.0.0.1:${server.port}\r\n'
        'Content-Type: application/json\r\n'
        'Content-Length: 100\r\n\r\n{',
      );
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      socket.destroy();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // The server goes on.
      expect((await send('GET', path('/api/hello'))).status, HttpStatus.ok);
      expect(room.guests, isEmpty);
    });

    test('everything once the room ended', () async {
      await room.end();
      await settle();

      expect(server.url.port, server.port);
      await expectLater(send('GET', path('')), throwsA(isA<SocketException>()));
    });
  });

  group('join', () {
    test('needs the PIN and the language', () async {
      Future<int> attempt(Map<String, Object?> body) async =>
          (await send('POST', path('/api/join'), json: body)).status;

      expect(await attempt({'language': 'fr'}), HttpStatus.forbidden);
      expect(await attempt({'language': 'fr', 'pin': 42}), 400);
      expect(await attempt({'pin': '1234'}), HttpStatus.badRequest);
      expect(await attempt({'language': 'de', 'pin': '1234'}), 400);

      final response = await send(
        'POST',
        path('/api/join'),
        headers: {'Origin': 'http://127.0.0.1:${server.port}'},
        json: {'language': 'es', 'pin': '1234'},
      );
      expect(response.status, HttpStatus.ok);
      final body = jsonDecode(response.body) as Map<String, Object?>;
      expect(body['language'], 'es');
      expect(body['guest'], isA<String>());
      expect(body['key'], isA<String>());
      expect((body['strings']! as Map)['_locale'], 'es');
      expect(room.guests.single.language, spanish);
    });

    test('limits wrong PINs per address', () async {
      for (var i = 0; i < io.IoShareServer.maxWrongPinsPerMinute; i++) {
        final response = await send(
          'POST',
          path('/api/join'),
          json: {'language': 'fr', 'pin': '0000'},
        );
        expect(response.status, HttpStatus.forbidden);
      }

      final response = await send(
        'POST',
        path('/api/join'),
        json: {'language': 'fr', 'pin': '1234'},
      );
      expect(response.status, HttpStatus.tooManyRequests);
    });

    test('names the languages a guest can pick when no more fit', () async {
      final limited = ShareRoom(
        token: 'abcdefghijklmnopqrstuv',
        languages: const [english, spanish, french, german],
        translations: translations,
        onReply: (_, _) {},
        conversationLanguages: () => const [english, spanish],
        maxExtraLanguages: 1,
      );
      addTearDown(limited.end);
      final other = await io.IoShareServer.bind(
        address: '127.0.0.1',
        room: limited,
        strings: shareStrings,
        allowPeer: (_) => true,
      );
      addTearDown(other.close);
      Future<_Response> post(
        String rest,
        Object json, [
        Map<String, String> headers = const {},
      ]) => send(
        'POST',
        path(rest),
        json: json,
        headers: headers,
        port: other.port,
      );

      final first = await post('/api/join', {'language': 'fr'});
      expect(first.status, HttpStatus.ok);
      final refused = await post('/api/join', {'language': 'de'});
      expect(refused.status, HttpStatus.conflict);
      expect(jsonDecode(refused.body), {
        'error': 'languageLimit',
        'languages': ['en', 'es', 'fr'],
      });

      final second = await post('/api/join', {'language': 'en'});
      final body = jsonDecode(second.body) as Map<String, Object?>;
      final change = await post(
        '/api/language',
        {'language': 'de'},
        {
          'X-Mozhi-Guest': body['guest']! as String,
          'X-Mozhi-Key': body['key']! as String,
        },
      );
      expect(change.status, HttpStatus.conflict);
      expect(jsonDecode(change.body), containsPair('error', 'languageLimit'));
    });

    test('limits joins in all', () async {
      for (var i = 0; i < ShareRoom.maxRoomJoinsPerMinute; i++) {
        final joined =
            room.join(languageCode: 'fr', pin: '1234') as ShareJoined;
        room.leave(joined.guest);
      }

      final response = await send(
        'POST',
        path('/api/join'),
        json: {'language': 'fr', 'pin': '1234'},
      );
      expect(response.status, HttpStatus.tooManyRequests);
    });

    test('reports a full, locked or ended room', () async {
      for (var i = 0; i < room.maxGuests; i++) {
        room.join(languageCode: 'fr', pin: '1234');
      }
      expect(
        (await send(
          'POST',
          path('/api/join'),
          json: {'language': 'fr', 'pin': '1234'},
        )).status,
        HttpStatus.conflict,
      );

      for (var i = 0; i < ShareRoom.maxWrongPins; i++) {
        room.join(languageCode: 'fr', pin: '0000');
      }
      expect(
        (await send(
          'POST',
          path('/api/join'),
          json: {'language': 'fr', 'pin': '1234'},
        )).status,
        HttpStatus.locked,
      );
    });
  });

  group('a guest', () {
    test('changes language', () async {
      final joined = await join();

      final response = await send(
        'POST',
        path('/api/language'),
        headers: auth(joined),
        json: {'language': 'es'},
      );
      expect(response.status, HttpStatus.ok);
      expect(
        ((jsonDecode(response.body) as Map)['strings'] as Map)['_locale'],
        'es',
      );
      expect(room.guests.single.language, spanish);

      expect(
        (await send(
          'POST',
          path('/api/language'),
          headers: auth(joined),
          json: {'language': 'de'},
        )).status,
        HttpStatus.badRequest,
      );
      expect(
        (await send(
          'POST',
          path('/api/language'),
          headers: auth(joined),
          json: {'language': 3},
        )).status,
        HttpStatus.badRequest,
      );
      expect(
        (await send(
          'POST',
          path('/api/language'),
          json: {'language': 'es'},
        )).status,
        HttpStatus.unauthorized,
      );
      for (var i = 1; i < 10; i++) {
        room.setLanguage(joined.guest, 'fr');
      }
      expect(
        (await send(
          'POST',
          path('/api/language'),
          headers: auth(joined),
          json: {'language': 'es'},
        )).status,
        HttpStatus.tooManyRequests,
      );
    });

    test('replies', () async {
      final joined = await join();

      Future<int> reply(Object? text, {bool signed = true}) async =>
          (await send(
            'POST',
            path('/api/reply'),
            headers: signed ? auth(joined) : const {},
            json: {'text': text},
          )).status;

      expect(await reply('Bonjour'), HttpStatus.noContent);
      expect(replies.single.$2, 'Bonjour');
      expect(await reply('again'), HttpStatus.tooManyRequests);
      expect(await reply(' '), HttpStatus.badRequest);
      expect(await reply(3), HttpStatus.badRequest);
      expect(await reply('a' * 501), HttpStatus.requestEntityTooLarge);
      expect(await reply('x', signed: false), HttpStatus.unauthorized);
      room.repliesAllowed = false;
      expect(await reply('Bonjour'), HttpStatus.forbidden);
    });

    test('leaves', () async {
      final joined = await join();

      expect(
        (await send('POST', path('/api/leave'), json: {})).status,
        HttpStatus.unauthorized,
      );
      expect(
        (await send(
          'POST',
          path('/api/leave'),
          headers: auth(joined),
          json: {},
        )).status,
        HttpStatus.noContent,
      );
      expect(room.guests, isEmpty);
    });
  });

  group('the update stream', () {
    test('needs the guest key', () async {
      final response = await send(
        'GET',
        path('/api/events?guest=nobody&key=nothing'),
      );

      expect(response.status, HttpStatus.unauthorized);
    });

    test('sends snapshots, pings and the end', () async {
      final joined = await join();
      final request = await client.getUrl(
        Uri.parse(
          'http://127.0.0.1:${server.port}'
          '${path('/api/events?guest=${joined.guest.id}&key=${joined.key}')}',
        ),
      );
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.contentType?.mimeType, 'text/event-stream');
      final lines = <String>[];
      final snapshots = StreamController<Map<String, Object?>>.broadcast();
      final done = Completer<void>();
      var event = '';
      response.transform(utf8.decoder).transform(const LineSplitter()).listen((
        line,
      ) {
        lines.add(line);
        if (line.startsWith('event: ')) event = line.substring(7);
        if (line.startsWith('data: ') && event == 'snapshot') {
          snapshots.add(jsonDecode(line.substring(6)) as Map<String, Object?>);
        }
      }, onDone: done.complete);

      final first = await snapshots.stream.first;
      expect(first['turns'], isEmpty);
      expect(room.guests.single.connected, isTrue);

      final next = snapshots.stream.first;
      room.update([
        ConversationTurn(
          id: 0,
          side: ConversationSide.a,
          original: 'Hello',
          source: english,
          target: spanish,
          createdAt: sentAt,
        ),
      ]);
      final second = await next;
      expect((second['turns']! as List).single, containsPair('text', 'Hello'));

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(lines, contains(': ping'));

      await room.end();
      await done.future;
      expect(lines, contains('event: ended'));
      await snapshots.close();
    });

    test('disconnects a page that takes in nothing', () async {
      final slow = await io.IoShareServer.bind(
        address: '127.0.0.1',
        room: room,
        strings: shareStrings,
        allowPeer: (_) => true,
        maxFlushTime: const Duration(milliseconds: 300),
      );
      addTearDown(slow.close);
      final joined = await join();
      final response = await (await client.getUrl(
        Uri.parse(
          'http://127.0.0.1:${slow.port}'
          '${path('/api/events?guest=${joined.guest.id}&key=${joined.key}')}',
        ),
      )).close();
      final subscription = response.listen((_) {}, onError: (Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(room.guests.single.connected, isTrue);
      // The page stops reading.
      subscription.pause();

      for (var round = 0; round < 10 && room.guests.single.connected; round++) {
        room.update(_bigTurns(round));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }

      expect(room.guests.single.connected, isFalse);
      await subscription.cancel();
    });

    test('ends a page that takes in nothing at once', () async {
      final joined = await join();
      final response = await (await client.getUrl(
        Uri.parse(
          'http://127.0.0.1:${server.port}'
          '${path('/api/events?guest=${joined.guest.id}&key=${joined.key}')}',
        ),
      )).close();
      final subscription = response.listen((_) {}, onError: (Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      subscription.pause();
      for (var round = 0; round < 2; round++) {
        room.update(_bigTurns(round));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }

      final ending = Stopwatch()..start();
      await room.end();
      await server.close();
      expect(ending.elapsed, lessThan(const Duration(seconds: 2)));
      await subscription.cancel();
    });

    test('sends the latest snapshot once a slow page caught up', () async {
      final joined = await join();
      final response = await (await client.getUrl(
        Uri.parse(
          'http://127.0.0.1:${server.port}'
          '${path('/api/events?guest=${joined.guest.id}&key=${joined.key}')}',
        ),
      )).close();
      final snapshots = <String>[];
      final subscription = response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.startsWith('data: {"revision"')) {
              final turns =
                  (jsonDecode(line.substring(6)) as Map)['turns'] as List;
              snapshots.add(
                turns.isEmpty ? '' : (turns.first as Map)['text'] as String,
              );
            }
          }, onError: (Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      subscription.pause();
      const rounds = 6;
      for (var round = 0; round < rounds; round++) {
        room.update(_bigTurns(round));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }

      subscription.resume();
      for (var i = 0; i < 50; i++) {
        if (snapshots.lastOrNull?.startsWith('${rounds - 1} ') ?? false) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(snapshots.last, startsWith('${rounds - 1} '));
      // Not one snapshot per change: the waiting ones were sent as one.
      expect(snapshots.length, lessThan(rounds + 1));
      expect(room.guests.single.connected, isTrue);
      await subscription.cancel();
    });

    test('of a new page replaces the old one', () async {
      final joined = await join();
      final location = Uri.parse(
        'http://127.0.0.1:${server.port}'
        '${path('/api/events?guest=${joined.guest.id}&key=${joined.key}')}',
      );
      final old = await (await client.getUrl(location)).close();
      final oldLines = <String>[];
      final oldDone = Completer<void>();
      old
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(oldLines.add, onDone: oldDone.complete);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final fresh = await (await client.getUrl(location)).close();
      final freshLines = fresh
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      final subscription = freshLines.listen((_) {});
      await oldDone.future;

      expect(oldLines, isNot(contains('event: ended')));
      expect(room.guests.single.connected, isTrue);
      await subscription.cancel();
    });

    test('marks the guest away when the page goes', () async {
      final joined = await join();
      final location = Uri.parse(
        'http://127.0.0.1:${server.port}'
        '${path('/api/events?guest=${joined.guest.id}&key=${joined.key}')}',
      );
      final response = await (await client.getUrl(location)).close();
      final subscription = response.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(room.guests.single.connected, isTrue);

      await subscription.cancel();
      client.close(force: true);
      client = HttpClient();
      for (var i = 0; i < 20 && room.guests.single.connected; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      expect(room.guests.single.connected, isFalse);
    });

    test('ends when the guest is gone', () async {
      final joined = await join();
      final location = Uri.parse(
        'http://127.0.0.1:${server.port}'
        '${path('/api/events?guest=${joined.guest.id}&key=${joined.key}')}',
      );
      final response = await (await client.getUrl(location)).close();
      final lines = <String>[];
      final done = Completer<void>();
      response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(lines.add, onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Removed by the host's room (e.g. after a long absence elsewhere).
      room.leave(joined.guest);
      await done.future.timeout(const Duration(seconds: 5));

      expect(lines, contains('event: ended'));
    });
  });

  test('the platform factory starts a server', () async {
    expect(shareServerSupported, isTrue);
    final started = await startShareServer(
      address: '127.0.0.1',
      room: room,
      strings: shareStrings,
    );
    addTearDown(started.close);

    expect(started.url.host, '127.0.0.1');
  });

  test('strings fall back to English', () {
    expect(shareStrings(['xx', 'pt-BR']).localeName, 'pt');
    expect(shareStrings(['', 'xx']).localeName, 'en');
  });
}

/// A hundred turns of 50,000 characters, starting with [round].
List<ConversationTurn> _bigTurns(int round) => [
  for (var i = 0; i < ShareRoom.maxTurns; i++)
    ConversationTurn(
      id: i,
      side: ConversationSide.a,
      original: '$round ${'x' * 50000}',
      source: english,
      target: spanish,
      createdAt: sentAt,
    ),
];
