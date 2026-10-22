import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:mozhi/conversation/share/data/share_secrets.dart';
import 'package:mozhi/conversation/share/data/share_translations.dart';
import 'package:translation_repository/translation_repository.dart';

/// A guest following a shared conversation in their browser.
class ShareGuest extends Equatable {
  const new({
    required this.id,
    required this.number,
    required this.language,
    required this.joinedAt,
    this.connected = false,
  });

  /// Random public id (the guest's key is kept by the room).
  final String id;

  /// 1 for the first guest of the conversation, then 2, 3... ("Guest 2").
  final int number;

  /// The language the guest reads and writes.
  final Language language;
  final DateTime joinedAt;

  /// Whether the guest's page is connected for updates right now.
  final bool connected;

  ShareGuest copyWith({Language? language, bool? connected}) => ShareGuest(
    id: id,
    number: number,
    language: language ?? this.language,
    joinedAt: joinedAt,
    connected: connected ?? this.connected,
  );

  @override
  List<Object?> get props => [id, number, language, joinedAt, connected];
}

/// The answer to a guest who asks to join ([ShareRoom.join]).
sealed class ShareJoinResult {
  const new();
}

/// Joined: the guest's [key] authenticates its later requests.
final class ShareJoined extends ShareJoinResult {
  const new(this.guest, this.key);

  final ShareGuest guest;
  final String key;
}

/// Why a guest could not join.
enum ShareJoinError {
  /// The PIN is wrong.
  wrongPin,

  /// Too many wrong PINs: nobody new may join this conversation.
  locked,

  /// There are [ShareRoom.maxGuests] guests already.
  full,

  /// The language is not one the host offers.
  unknownLanguage,

  /// The conversation ended.
  ended,
}

final class ShareJoinRefused extends ShareJoinResult {
  const new(this.error);

  final ShareJoinError error;
}

/// The answer to a guest's reply ([ShareRoom.reply]).
enum ShareReplyResult {
  sent,

  /// Blank.
  empty,

  /// Longer than [ShareRoom.maxReplyLength].
  tooLong,

  /// Too many replies in a short time.
  tooFast,

  /// The host turned replies off.
  disabled,

  /// The conversation ended.
  ended,
}

/// Called with what [guest] replied.
typedef ShareReplyCallback = void Function(ShareGuest guest, String text);

/// The guests of a conversation shared on the local network and what they
/// see, independent of how they connect (the HTTP server,
/// `share_server_io.dart`, is a thin layer over it):
///
/// * Guests join with a language from [languages] (and the [pin], when
///   there is one). At most [maxGuests] at a time; after
///   [maxWrongPins] wrong PINs nobody new may join.
/// * Each guest sees the shared turns ([update]: what was said since the
///   sharing started) in their language ([snapshotFor]), translated once
///   per language ([ShareTranslations]).
/// * Guests may reply ([reply], unless [repliesAllowed] is off): at most
///   [maxReplyLength] characters, one every [replyInterval] and
///   [maxRepliesPerMinute] a minute.
/// * A guest whose page is gone ([disconnected]) for [absenceGrace] is
///   removed.
/// * [end] ends it for everyone.
///
/// [changes] fires whenever what a guest sees (or the host's view of the
/// guests) may have changed.
class ShareRoom {
  new({
    required this.token,
    required this.languages,
    required this._translations,
    required this._onReply,
    this._pin,
    this.maxGuests = 8,
    ShareSecrets? secrets,
    DateTime Function()? clock,
    Timer Function(Duration, void Function())? timer,
  }) : _secrets = secrets ?? ShareSecrets(),
       _clock = clock ?? DateTime.now,
       _timer = timer ?? Timer.new,
       _replies = ShareRateLimiter(
         max: maxRepliesPerMinute,
         per: const Duration(minutes: 1),
         clock: clock,
       ),
       _replyGap = ShareRateLimiter(max: 1, per: replyInterval, clock: clock),
       _languageChanges = ShareRateLimiter(
         max: 10,
         per: const Duration(minutes: 1),
         clock: clock,
       ) {
    _translationChanges = _translations.changes.listen((_) => _changed());
  }

  /// The longest reply, in characters.
  static const maxReplyLength = 500;

  /// The shortest time between two replies of a guest.
  static const replyInterval = Duration(seconds: 2);

  /// Replies a guest may send per minute.
  static const maxRepliesPerMinute = 12;

  /// Wrong PINs (from anyone) after which nobody new may join.
  static const maxWrongPins = 20;

  /// How long a guest's page may be gone before the guest is removed (a
  /// page reload or a short network loss keeps the guest).
  static const absenceGrace = Duration(seconds: 45);

  /// The most recent turns a guest's page receives.
  static const maxTurns = 100;

  /// The session token in the link (128 random bits).
  final String token;

  /// What guests may pick (the host engine's languages).
  final List<Language> languages;

  final ShareTranslations _translations;
  final ShareReplyCallback _onReply;
  final ShareSecrets _secrets;
  final DateTime Function() _clock;
  final Timer Function(Duration, void Function()) _timer;
  final ShareRateLimiter _replies;
  final ShareRateLimiter _replyGap;
  final ShareRateLimiter _languageChanges;
  late final StreamSubscription<void> _translationChanges;

  /// The most guests at a time.
  // Immutable configuration passed to the constructor, not state.
  // ignore: avoid_public_fields
  final int maxGuests;

  String? _pin;
  bool _repliesAllowed = true;
  int _wrongPins = 0;
  bool _ended = false;
  int _nextNumber = 1;
  int _revision = 0;
  final Map<String, _Guest> _guests = {};
  List<ConversationTurn> _turns = const [];
  final _changes = StreamController<void>.broadcast();

  /// Something a guest (or the host) sees may have changed.
  Stream<void> get changes => _changes.stream;

  /// Increases with every change.
  int get revision => _revision;

  /// The PIN guests must enter, if any.
  String? get pin => _pin;

  /// Requires [pin] for new guests (null: none). Guests who joined stay.
  set pin(String? value) {
    _pin = value;
    _wrongPins = 0;
    _changed();
  }

  /// Whether guests may reply.
  bool get repliesAllowed => _repliesAllowed;

  set repliesAllowed(bool value) {
    if (value == _repliesAllowed) return;
    _repliesAllowed = value;
    _changed();
  }

  /// Too many wrong PINs: nobody new may join (a new PIN lifts it).
  bool get locked => _wrongPins >= maxWrongPins;

  bool get ended => _ended;

  /// The guests, in the order they joined.
  List<ShareGuest> get guests => [
    for (final guest in _guests.values) guest.guest,
  ];

  /// The languages the guests read, each once, in the order they were
  /// first picked.
  List<Language> get guestLanguages {
    final result = <Language>[];
    for (final guest in _guests.values) {
      final language = guest.guest.language;
      if (!result.any(
        (other) => ShareTranslations.sameLanguage(other, language),
      )) {
        result.add(language);
      }
    }
    return result;
  }

  /// The language of [languages] with [code], if any.
  Language? languageOf(String code) {
    final wanted = LanguageMatcher.normalize(code.trim()).toLowerCase();
    for (final language in languages) {
      if (LanguageMatcher.normalize(language.code).toLowerCase() == wanted) {
        return language;
      }
    }
    return null;
  }

  /// The conversation's turns to share (oldest first).
  void update(List<ConversationTurn> turns) {
    if (_ended) return;
    _turns = turns;
    _translate();
    _changed();
  }

  /// Adds a guest reading [languageCode], when [pin] is right.
  ShareJoinResult join({required String languageCode, String? pin}) {
    if (_ended) return const ShareJoinRefused(ShareJoinError.ended);
    if (locked) return const ShareJoinRefused(ShareJoinError.locked);
    final expected = _pin;
    if (expected != null && !constantTimeEquals(pin?.trim() ?? '', expected)) {
      _wrongPins++;
      _changed();
      return ShareJoinRefused(
        locked ? ShareJoinError.locked : ShareJoinError.wrongPin,
      );
    }
    final language = languageOf(languageCode);
    if (language == null) {
      return const ShareJoinRefused(ShareJoinError.unknownLanguage);
    }
    if (_guests.length >= maxGuests) {
      return const ShareJoinRefused(ShareJoinError.full);
    }
    final guest = ShareGuest(
      id: _secrets.id(),
      number: _nextNumber++,
      language: language,
      joinedAt: _clock(),
    );
    final key = _secrets.token();
    _guests[guest.id] = _Guest(guest, key)..absence = _absent(guest.id);
    _translate();
    _changed();
    return ShareJoined(guest, key);
  }

  /// The guest with [id] if [key] is theirs.
  ShareGuest? authenticate(String? id, String? key) {
    if (id == null || key == null || _ended) return null;
    final guest = _guests[id];
    if (guest == null || !constantTimeEquals(key, guest.key)) return null;
    return guest.guest;
  }

  /// [guest] reads [languageCode] from now on; false for a language the
  /// host does not offer, or too many changes.
  bool setLanguage(ShareGuest guest, String languageCode) {
    final entry = _guests[guest.id];
    final language = languageOf(languageCode);
    if (entry == null || language == null) return false;
    if (!_languageChanges.allow(guest.id)) return false;
    entry.guest = entry.guest.copyWith(language: language);
    _translate();
    _changed();
    return true;
  }

  /// What [guest] replied: added to the conversation by the host.
  ShareReplyResult reply(ShareGuest guest, String text) {
    final entry = _guests[guest.id];
    if (_ended || entry == null) return ShareReplyResult.ended;
    if (!_repliesAllowed) return ShareReplyResult.disabled;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return ShareReplyResult.empty;
    if (trimmed.runes.length > maxReplyLength) {
      return ShareReplyResult.tooLong;
    }
    if (!_replyGap.allows(guest.id) || !_replies.allows(guest.id)) {
      return ShareReplyResult.tooFast;
    }
    _replyGap.allow(guest.id);
    _replies.allow(guest.id);
    _onReply(entry.guest, trimmed);
    return ShareReplyResult.sent;
  }

  /// [guest] left (their page said so).
  void leave(ShareGuest guest) => _remove(guest.id);

  /// [guest]'s page opened an update stream.
  void connected(ShareGuest guest) {
    final entry = _guests[guest.id];
    if (entry == null) return;
    entry.connections++;
    entry.absence?.cancel();
    entry.absence = null;
    if (!entry.guest.connected) {
      entry.guest = entry.guest.copyWith(connected: true);
      _changed();
    }
  }

  /// One of [guest]'s update streams closed; without another one for
  /// [absenceGrace], the guest is removed.
  void disconnected(ShareGuest guest) {
    final entry = _guests[guest.id];
    if (entry == null) return;
    entry.connections--;
    if (entry.connections > 0) return;
    entry.connections = 0;
    entry.guest = entry.guest.copyWith(connected: false);
    entry.absence?.cancel();
    entry.absence = _absent(guest.id);
    _changed();
  }

  Timer _absent(String id) => _timer(absenceGrace, () {
    final entry = _guests[id];
    if (entry != null && entry.connections == 0) _remove(id);
  });

  void _remove(String id) {
    final entry = _guests.remove(id);
    if (entry == null) return;
    entry.absence?.cancel();
    _changed();
  }

  /// What [guest]'s page shows: the shared turns in their language (the
  /// last [maxTurns]), newest last.
  ///
  /// `who` is `host` (side A), `partner` (side B on the host's phone),
  /// `guest` (another guest, with its `guest` number) or `you`; `state`
  /// is a [ShareTextStatus] name.
  Map<String, Object?> snapshotFor(ShareGuest guest) {
    final language = _guests[guest.id]?.guest.language ?? guest.language;
    final turns = _turns.length > maxTurns
        ? _turns.sublist(_turns.length - maxTurns)
        : _turns;
    return {
      'revision': _revision,
      'language': language.code,
      'repliesAllowed': _repliesAllowed,
      'turns': [
        for (final turn in turns)
          if (_translations.textOf(turn, language) case final shown)
            {
              'id': turn.id,
              'who': switch (turn.guest) {
                null when turn.side == ConversationSide.a => 'host',
                null => 'partner',
                final number when number == guest.number => 'you',
                _ => 'guest',
              },
              'guest': ?turn.guest,
              'language': _nameOf(turn.source),
              'text': shown.text,
              'original': turn.original,
              'state': shown.status.name,
              'time': turn.createdAt.toUtc().toIso8601String(),
            },
      ],
    };
  }

  /// The language list guests pick from.
  List<Map<String, String>> languageList() => [
    for (final language in languages)
      {
        'code': language.code,
        'name': language.name,
        if (language.nativeName case final native?
            when native.isNotEmpty && native != language.name)
          'nativeName': native,
      },
  ];

  /// Translates again the turns of [language] that waited for the host's
  /// consent (see [ShareTranslations.retry]).
  void retryLanguage(Language language) => _translations.retry(language);

  /// What the host sees about the guests' extra languages.
  List<ShareLanguageState> languageStates() =>
      _translations.languageStates(guestLanguages);

  /// Ends the conversation for every guest.
  Future<void> end() async {
    if (_ended) return;
    _ended = true;
    for (final entry in _guests.values) {
      entry.absence?.cancel();
    }
    _changed();
    await _translationChanges.cancel();
    await _translations.dispose();
    await _changes.close();
  }

  static String _nameOf(Language language) =>
      language.nativeName?.trim().isNotEmpty ?? false
      ? language.nativeName!
      : language.name;

  void _translate() => _translations.ensure(_turns, guestLanguages);

  void _changed() {
    _revision++;
    if (!_changes.isClosed) _changes.add(null);
  }
}

class _Guest {
  new(this.guest, this.key);

  ShareGuest guest;
  final String key;
  int connections = 0;
  Timer? absence;
}
