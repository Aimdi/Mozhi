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

  /// Too many guests joined in a short time
  /// ([ShareRoom.maxRoomJoinsPerMinute]).
  tooMany,

  /// The language would be one more than [ShareRoom.maxExtraLanguages]
  /// (see [ShareRoom.readableLanguages] for what may be read).
  languageLimit,

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
///   there is one). At most [maxGuests] at a time and
///   [maxRoomJoinsPerMinute] joins a minute; after [maxWrongPins] wrong
///   PINs nobody new may join.
/// * Each guest sees the shared turns ([update]: what was said since the
///   sharing started; the last [maxTurns]) in their language
///   ([snapshotFor]), translated once per language ([ShareTranslations]):
///   only those turns, only for the languages guests read now. Besides
///   the conversation's two languages, guests may read at most
///   [maxExtraLanguages] others at a time; a language keeps its place
///   (and its translations) for [languageKeep] after its last guest left
///   it, so leaving and joining again, or switching back and forth,
///   doesn't have the same turns translated again.
/// * Guests may reply ([reply], unless [repliesAllowed] is off): at most
///   [maxReplyLength] characters, one every [replyInterval] and
///   [maxRepliesPerMinute] a minute per device (the `client` a guest
///   joined from, so joining again does not reset it), and
///   [maxRoomRepliesPerMinute] a minute from all guests together.
///   Language changes likewise ([maxLanguageChangesPerMinute],
///   [maxRoomLanguageChangesPerMinute]).
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
    this.maxExtraLanguages = defaultMaxExtraLanguages,
    List<Language> Function()? conversationLanguages,
    ShareSecrets? secrets,
    DateTime Function()? clock,
    Timer Function(Duration, void Function())? timer,
  }) : _ownLanguages = conversationLanguages ?? (() => const []),
       _secrets = secrets ?? ShareSecrets(),
       _clock = clock ?? DateTime.now,
       _timer = timer ?? Timer.new,
       _replies = ShareRateLimiter(
         max: maxRepliesPerMinute,
         per: const Duration(minutes: 1),
         clock: clock,
       ),
       _replyGap = ShareRateLimiter(max: 1, per: replyInterval, clock: clock),
       _languageChanges = ShareRateLimiter(
         max: maxLanguageChangesPerMinute,
         per: const Duration(minutes: 1),
         clock: clock,
       ),
       _roomJoins = ShareRateLimiter(
         max: maxRoomJoinsPerMinute,
         per: const Duration(minutes: 1),
         clock: clock,
       ),
       _roomReplies = ShareRateLimiter(
         max: maxRoomRepliesPerMinute,
         per: const Duration(minutes: 1),
         clock: clock,
       ),
       _roomLanguageChanges = ShareRateLimiter(
         max: maxRoomLanguageChangesPerMinute,
         per: const Duration(minutes: 1),
         clock: clock,
       ) {
    _translationChanges = _translations.changes.listen((_) => _changed());
  }

  /// The longest reply, in characters.
  static const maxReplyLength = 500;

  /// The shortest time between two replies of a guest.
  static const replyInterval = Duration(seconds: 2);

  /// Replies a guest's device may send per minute.
  static const maxRepliesPerMinute = 12;

  /// Replies per minute from all guests together.
  static const maxRoomRepliesPerMinute = 20;

  /// Language changes a guest's device may make per minute.
  static const maxLanguageChangesPerMinute = 10;

  /// Language changes per minute from all guests together.
  static const maxRoomLanguageChangesPerMinute = 30;

  /// Joins per minute in all, whoever asks (the server also limits them
  /// per address).
  static const maxRoomJoinsPerMinute = 20;

  /// See [maxExtraLanguages].
  static const defaultMaxExtraLanguages = 4;

  /// How long a language no guest reads any more keeps its translations
  /// and its place among the [maxExtraLanguages].
  static const languageKeep = Duration(minutes: 5);

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
  final List<Language> Function() _ownLanguages;
  final ShareSecrets _secrets;
  final DateTime Function() _clock;
  final Timer Function(Duration, void Function()) _timer;
  final ShareRateLimiter _replies;
  final ShareRateLimiter _replyGap;
  final ShareRateLimiter _languageChanges;
  final ShareRateLimiter _roomJoins;
  final ShareRateLimiter _roomReplies;
  final ShareRateLimiter _roomLanguageChanges;
  late final StreamSubscription<void> _translationChanges;

  /// The key of the room-wide limits.
  static const _everyone = '';

  /// The most guests at a time.
  // Immutable configuration passed to the constructor, not state.
  // ignore: avoid_public_fields
  final int maxGuests;

  /// The most languages guests may read at a time besides the
  /// conversation's two (`conversationLanguages`), each translated by the
  /// host's engine for every turn.
  // ignore: avoid_public_fields
  final int maxExtraLanguages;

  String? _pin;
  bool _repliesAllowed = true;
  int _wrongPins = 0;
  bool _ended = false;
  int _nextNumber = 1;
  int _revision = 0;
  final Map<String, _Guest> _guests = {};
  List<ConversationTurn> _turns = const [];

  /// The languages guests read at the last [_translate].
  List<Language> _reading = const [];

  /// Languages no guest reads any more whose translations are kept, until
  /// when (see [languageKeep]); never one guests read.
  final Map<String, (Language, DateTime)> _kept = {};
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
      if (_codeOf(language) == wanted) return language;
    }
    return null;
  }

  /// Whether a guest may read [language] now: one of the conversation's
  /// two, one that guests read (or read until a moment ago, see
  /// [languageKeep]), or another one while fewer than [maxExtraLanguages]
  /// are.
  bool canRead(Language language) {
    if (_isOwn(language)) return true;
    final inUse = _extraInUse();
    return inUse.contains(_codeOf(language)) ||
        inUse.length < maxExtraLanguages;
  }

  /// The languages of [languages] guests can read without one more
  /// ([canRead]): the conversation's two and the others in use.
  List<Language> get readableLanguages {
    final inUse = _extraInUse();
    return [
      for (final language in languages)
        if (_isOwn(language) || inUse.contains(_codeOf(language))) language,
    ];
  }

  /// The conversation's turns to share (oldest first).
  void update(List<ConversationTurn> turns) {
    if (_ended) return;
    _turns = turns;
    _translate();
    _changed();
  }

  /// Adds a guest reading [languageCode], when [pin] is right. [client]
  /// identifies the guest's device (the server passes the device token
  /// of its cookie, see `IoShareServer`): the guest's limits are counted
  /// per device, so joining again doesn't reset them.
  ShareJoinResult join({
    required String languageCode,
    String? pin,
    String? client,
  }) {
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
    if (!_roomJoins.allows(_everyone)) {
      return const ShareJoinRefused(ShareJoinError.tooMany);
    }
    if (!canRead(language)) {
      return const ShareJoinRefused(ShareJoinError.languageLimit);
    }
    _roomJoins.allow(_everyone);
    final guest = ShareGuest(
      id: _secrets.id(),
      number: _nextNumber++,
      language: language,
      joinedAt: _clock(),
    );
    final key = _secrets.token();
    _guests[guest.id] = _Guest(guest, key, client ?? guest.id)
      ..absence = _absent(guest.id);
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
  /// host does not offer or that would be one too many ([canRead]), or
  /// too many changes.
  bool setLanguage(ShareGuest guest, String languageCode) {
    final entry = _guests[guest.id];
    final language = languageOf(languageCode);
    if (entry == null || language == null || !canRead(language)) {
      return false;
    }
    if (!_languageChanges.allows(entry.client) ||
        !_roomLanguageChanges.allows(_everyone)) {
      return false;
    }
    _languageChanges.allow(entry.client);
    _roomLanguageChanges.allow(_everyone);
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
    final client = entry.client;
    if (!_replyGap.allows(client) ||
        !_replies.allows(client) ||
        !_roomReplies.allows(_everyone)) {
      return ShareReplyResult.tooFast;
    }
    _replyGap.allow(client);
    _replies.allow(client);
    _roomReplies.allow(_everyone);
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
    // Nothing more is translated for a language nobody reads now.
    _translate();
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
    final turns = _visible;
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
  /// [consent] (see [ShareTranslations.retry]).
  void retryLanguage(Language language, {ConsentRequiredException? consent}) =>
      _translations.retry(language, consent: consent);

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

  static String _codeOf(Language language) =>
      LanguageMatcher.normalize(language.code).toLowerCase();

  bool _isOwn(Language language) => _ownLanguages().any(
    (own) => ShareTranslations.sameLanguage(own, language),
  );

  /// The turns guests see: the last [maxTurns].
  List<ConversationTurn> get _visible => _turns.length > maxTurns
      ? _turns.sublist(_turns.length - maxTurns)
      : _turns;

  /// The codes of the languages besides the conversation's two that guests
  /// read, or read until a moment ago.
  Set<String> _extraInUse() {
    _forgetKept(_clock());
    return {
      for (final language in guestLanguages)
        if (!_isOwn(language)) _codeOf(language),
      for (final (language, _) in _kept.values)
        if (!_isOwn(language)) _codeOf(language),
    };
  }

  void _forgetKept(DateTime now) =>
      _kept.removeWhere((_, kept) => !kept.$2.isAfter(now));

  /// Has what guests see translated, and nothing else.
  void _translate() {
    final now = _clock();
    final reading = guestLanguages;
    final read = {for (final language in reading) _codeOf(language)};
    for (final language in _reading) {
      final code = _codeOf(language);
      if (!read.contains(code)) _kept[code] = (language, now.add(languageKeep));
    }
    read.forEach(_kept.remove);
    _reading = reading;
    _forgetKept(now);
    _translations.ensure(
      _visible,
      reading,
      keep: [for (final (language, _) in _kept.values) language],
    );
  }

  void _changed() {
    _revision++;
    if (!_changes.isClosed) _changes.add(null);
  }
}

class _Guest {
  new(this.guest, this.key, this.client);

  ShareGuest guest;
  final String key;

  /// The device the guest joined from (its limits are counted per device).
  final String client;
  int connections = 0;
  Timer? absence;
}
