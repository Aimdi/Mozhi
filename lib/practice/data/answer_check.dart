import 'dart:math' as math;

import 'package:equatable/equatable.dart';
import 'package:mozhi/practice/data/fsrs.dart';

/// How a word of the expected answer came out.
enum AnswerWordStatus {
  /// Said or typed as expected (ignoring case, punctuation and accents).
  matched,

  /// Nearly: a letter or two off, or part of it.
  close,

  /// Not said or typed.
  missed,
}

/// A word of the expected answer, as written there, and how it came out.
final class AnswerWord extends Equatable {
  const new(this.text, this.status);

  final String text;
  final AnswerWordStatus status;

  @override
  List<Object?> get props => [text, status];
}

/// The comparison of an answer (heard or typed) with the expected text:
/// each expected word [matched], [AnswerWordStatus.close] or missed, and
/// the answer's words that were not expected ([extra]).
final class AnswerCheck extends Equatable {
  const new({
    required this.answer,
    required this.words,
    this.extra = const [],
    this.score = 1,
  });

  /// What was heard or typed.
  final String answer;

  /// The expected text word by word (character by character in Chinese,
  /// Japanese and Thai), with how each came out.
  final List<AnswerWord> words;

  /// Words of the answer that the expected text does not have.
  final List<String> extra;

  /// 0 (nothing right) to 1 (all right, nothing else).
  final double score;

  /// How many expected words came out right.
  int get matched =>
      words.where((word) => word.status == AnswerWordStatus.matched).length;

  /// Whether the answer was right, word for word.
  bool get isExact =>
      extra.isEmpty &&
      words.every((word) => word.status == AnswerWordStatus.matched);

  /// The rating the comparison suggests (the user rates): Good when it was
  /// right, Hard when most of it was, Again otherwise. Never Easy: only
  /// the user knows how easy it was.
  FsrsRating get suggestedRating => isExact || score >= 0.999
      ? FsrsRating.good
      : score >= 0.75
      ? FsrsRating.hard
      : FsrsRating.again;

  @override
  List<Object?> get props => [answer, words, extra, score];
}

/// Compares [answer] with [expected] in [languageCode] (a BCP-47 code,
/// for number words): both are normalised ([answerKeys]: case,
/// punctuation, accents, number words as digits), then aligned word by
/// word (the longest common subsequence, where words a letter or two
/// apart count as close).
AnswerCheck checkAnswer({
  required String expected,
  required String answer,
  String? languageCode,
}) {
  final numbers = _numberWords(languageCode);
  final shown = _displayTokens(expected);
  final keys = <String>[];
  final owners = <int>[];
  for (var i = 0; i < shown.length; i++) {
    for (final key in _keys(shown[i], numbers)) {
      keys.add(key);
      owners.add(i);
    }
  }
  final heardTokens = _displayTokens(answer);
  final heard = <String>[];
  final heardOwners = <int>[];
  for (var i = 0; i < heardTokens.length; i++) {
    for (final key in _keys(heardTokens[i], numbers)) {
      heard.add(key);
      heardOwners.add(i);
    }
  }
  final alignment = _align(
    keys.take(_maxTokens).toList(),
    heard.take(_maxTokens).toList(),
  );
  // Words past [_maxTokens] are not compared: missed.
  final statuses = [
    ...alignment.expected,
    for (var i = alignment.expected.length; i < keys.length; i++)
      AnswerWordStatus.missed,
  ];
  final words = <AnswerWord>[];
  for (var i = 0; i < shown.length; i++) {
    final own = [
      for (var k = 0; k < keys.length; k++)
        if (owners[k] == i) statuses[k],
    ];
    // Punctuation alone (a dash, an emoji) is never wrong.
    if (own.isEmpty) continue;
    final status = own.every((s) => s == AnswerWordStatus.matched)
        ? AnswerWordStatus.matched
        : own.every((s) => s == AnswerWordStatus.missed)
        ? AnswerWordStatus.missed
        : AnswerWordStatus.close;
    words.add(AnswerWord(shown[i], status));
  }
  final extraOwners = <int>{
    for (var k = 0; k < heard.length; k++)
      if (k >= alignment.heard.length || !alignment.heard[k]) heardOwners[k],
  };
  final extra = [for (final i in extraOwners.toList()..sort()) heardTokens[i]];
  final weight = statuses.fold<double>(
    0,
    (sum, status) =>
        sum +
        switch (status) {
          AnswerWordStatus.matched => 1,
          AnswerWordStatus.close => 0.5,
          AnswerWordStatus.missed => 0,
        },
  );
  final total = math.max(keys.length, heard.length);
  return AnswerCheck(
    answer: answer,
    words: List.unmodifiable(words),
    extra: List.unmodifiable(extra),
    score: total == 0 ? 1 : weight / total,
  );
}

/// The normalised words of [text]: lower case, without punctuation,
/// symbols or accents (apostrophes join, other punctuation separates),
/// number words of [languageCode] as digits; Chinese and Japanese
/// characters and Thai, Lao, Khmer and Burmese letters one by one.
List<String> answerKeys(String text, {String? languageCode}) {
  final numbers = _numberWords(languageCode);
  return [for (final token in _displayTokens(text)) ..._keys(token, numbers)];
}

/// The most words compared (longer texts compare their beginning).
const _maxTokens = 300;

/// [text] as shown: its words (split at white space) and, in scripts
/// written without spaces, single characters.
List<String> _displayTokens(String text) {
  final tokens = <String>[];
  for (final word in text.trim().split(RegExp(r'\s+'))) {
    if (word.isEmpty) continue;
    final buffer = StringBuffer();
    for (final rune in word.runes) {
      if (_isUnspaced(rune)) {
        if (buffer.isNotEmpty) {
          tokens.add(buffer.toString());
          buffer.clear();
        }
        tokens.add(String.fromCharCode(rune));
      } else {
        buffer.writeCharCode(rune);
      }
    }
    if (buffer.isNotEmpty) tokens.add(buffer.toString());
  }
  return tokens;
}

/// The normalised keys of one shown token (none for punctuation alone,
/// several when punctuation such as a hyphen separates words in it).
List<String> _keys(String token, Map<String, String> numbers) {
  final folded = _fold(token.toLowerCase())
      .replaceAll(_apostrophes, '')
      .replaceAll(_separators, ' ')
      .trim();
  if (folded.isEmpty) return const [];
  return [
    for (final key in folded.split(RegExp(r'\s+')))
      if (key.isNotEmpty) numbers[key] ?? key,
  ];
}

final _apostrophes = RegExp("['’ʼ‘`´]");
final _separators = RegExp(r'[\p{P}\p{S}]', unicode: true);

/// Folds the letters with diacritics of lower-case [text] (and drops
/// combining marks, Arabic vowel marks and Hebrew points).
String _fold(String text) {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    if (_isMark(rune)) continue;
    if (_extraFolds[rune] case final plain?) {
      buffer.write(plain);
      continue;
    }
    if (rune <= 0xffff) {
      final index = _accented.indexOf(String.fromCharCode(rune));
      if (index >= 0) {
        buffer.write(_plain[index]);
        continue;
      }
    }
    buffer.writeCharCode(rune);
  }
  return buffer.toString();
}

bool _isMark(int rune) =>
    (rune >= 0x0300 && rune <= 0x036f) ||
    (rune >= 0x0591 && rune <= 0x05bd) ||
    rune == 0x05bf ||
    rune == 0x05c1 ||
    rune == 0x05c2 ||
    rune == 0x05c4 ||
    rune == 0x05c5 ||
    rune == 0x05c7 ||
    (rune >= 0x064b && rune <= 0x065f) ||
    rune == 0x0670;

/// Letters without a decomposition that read as plain ones.
const _extraFolds = {
  0x00df: 'ss', // ß
  0x00e6: 'ae', // æ
  0x0153: 'oe', // œ
  0x00f8: 'o', // ø
  0x0111: 'd', // đ
  0x0142: 'l', // ł
  0x0127: 'h', // ħ
  0x0131: 'i', // dotless ı
  0x03c2: 'σ', // final ς
};

/// Scripts written without spaces between words: compared character by
/// character.
bool _isUnspaced(int rune) =>
    (rune >= 0x0e00 && rune <= 0x0eff) || // Thai, Lao
    (rune >= 0x1000 && rune <= 0x109f) || // Myanmar
    (rune >= 0x1780 && rune <= 0x17ff) || // Khmer
    (rune >= 0x3040 && rune <= 0x30ff) || // kana
    (rune >= 0x3400 && rune <= 0x4dbf) ||
    (rune >= 0x4e00 && rune <= 0x9fff) ||
    (rune >= 0xf900 && rune <= 0xfaff) ||
    (rune >= 0x20000 && rune <= 0x2fa1f);

/// Number words (folded) of the language [code] and their digits.
Map<String, String> _numberWords(String? code) {
  final primary = code?.split(RegExp('[-_]')).first.toLowerCase();
  final words = _numbers[primary];
  if (words == null) return const {};
  final parts = words.split(' ');
  return {for (var i = 0; i + 1 < parts.length; i += 2) parts[i]: parts[i + 1]};
}

/// "word digits" pairs, folded like [_keys] folds (no accents, ß as ss).
const _numbers = {
  'en':
      'zero 0 one 1 two 2 three 3 four 4 five 5 six 6 seven 7 eight 8 '
      'nine 9 ten 10 eleven 11 twelve 12 thirteen 13 fourteen 14 fifteen 15 '
      'sixteen 16 seventeen 17 eighteen 18 nineteen 19 twenty 20 thirty 30 '
      'forty 40 fifty 50 sixty 60 seventy 70 eighty 80 ninety 90 '
      'hundred 100 thousand 1000',
  'es':
      'cero 0 uno 1 una 1 un 1 dos 2 tres 3 cuatro 4 cinco 5 seis 6 siete 7 '
      'ocho 8 nueve 9 diez 10 once 11 doce 12 trece 13 catorce 14 quince 15 '
      'dieciseis 16 diecisiete 17 dieciocho 18 diecinueve 19 veinte 20 '
      'treinta 30 cuarenta 40 cincuenta 50 sesenta 60 setenta 70 ochenta 80 '
      'noventa 90 cien 100 mil 1000',
  'fr':
      'zero 0 un 1 une 1 deux 2 trois 3 quatre 4 cinq 5 six 6 sept 7 huit 8 '
      'neuf 9 dix 10 onze 11 douze 12 treize 13 quatorze 14 quinze 15 '
      'seize 16 vingt 20 trente 30 quarante 40 cinquante 50 soixante 60 '
      'cent 100 mille 1000',
  'de':
      'null 0 eins 1 ein 1 eine 1 zwei 2 drei 3 vier 4 funf 5 sechs 6 '
      'sieben 7 acht 8 neun 9 zehn 10 elf 11 zwolf 12 dreizehn 13 '
      'vierzehn 14 funfzehn 15 sechzehn 16 siebzehn 17 achtzehn 18 '
      'neunzehn 19 zwanzig 20 dreissig 30 vierzig 40 funfzig 50 sechzig 60 '
      'siebzig 70 achtzig 80 neunzig 90 hundert 100 tausend 1000',
  'it':
      'zero 0 uno 1 una 1 un 1 due 2 tre 3 quattro 4 cinque 5 sei 6 sette 7 '
      'otto 8 nove 9 dieci 10 undici 11 dodici 12 tredici 13 quattordici 14 '
      'quindici 15 sedici 16 diciassette 17 diciotto 18 diciannove 19 '
      'venti 20 trenta 30 quaranta 40 cinquanta 50 sessanta 60 settanta 70 '
      'ottanta 80 novanta 90 cento 100 mille 1000',
  'pt':
      'zero 0 um 1 uma 1 dois 2 duas 2 tres 3 quatro 4 cinco 5 seis 6 '
      'sete 7 oito 8 nove 9 dez 10 onze 11 doze 12 treze 13 catorze 14 '
      'quatorze 14 quinze 15 dezesseis 16 dezasseis 16 dezessete 17 '
      'dezassete 17 dezoito 18 dezenove 19 dezanove 19 vinte 20 trinta 30 '
      'quarenta 40 cinquenta 50 sessenta 60 setenta 70 oitenta 80 '
      'noventa 90 cem 100 mil 1000',
  'nl':
      'nul 0 een 1 twee 2 drie 3 vier 4 vijf 5 zes 6 zeven 7 acht 8 '
      'negen 9 tien 10 elf 11 twaalf 12 dertien 13 veertien 14 vijftien 15 '
      'zestien 16 zeventien 17 achttien 18 negentien 19 twintig 20 '
      'dertig 30 veertig 40 vijftig 50 zestig 60 zeventig 70 tachtig 80 '
      'negentig 90 honderd 100 duizend 1000',
};

/// The alignment of [expected] with [heard]: each expected key's status
/// and whether each heard key was used.
({List<AnswerWordStatus> expected, List<bool> heard}) _align(
  List<String> expected,
  List<String> heard,
) {
  final n = expected.length;
  final m = heard.length;
  // score[i][j]: the best weight aligning expected[i..] with heard[j..]
  // (2 a match, 1 a close word).
  final score = List.generate(n + 1, (_) => List.filled(m + 1, 0));
  int pair(int i, int j) {
    final a = expected[i];
    final b = heard[j];
    if (a == b) return 2;
    return _isClose(a, b) ? 1 : 0;
  }

  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      final weight = pair(i, j);
      score[i][j] = math.max(
        weight == 0 ? 0 : weight + score[i + 1][j + 1],
        math.max(score[i + 1][j], score[i][j + 1]),
      );
    }
  }
  final statuses = List.filled(n, AnswerWordStatus.missed);
  final used = List.filled(m, false);
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    final weight = pair(i, j);
    if (weight > 0 && score[i][j] == weight + score[i + 1][j + 1]) {
      statuses[i] = weight == 2
          ? AnswerWordStatus.matched
          : AnswerWordStatus.close;
      used[j] = true;
      i++;
      j++;
    } else if (score[i + 1][j] >= score[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return (expected: statuses, heard: used);
}

/// Whether [a] and [b] are a letter or two apart (one edit from 4
/// letters, two from 8); digits must be equal.
bool _isClose(String a, String b) {
  final shorter = math.min(a.length, b.length);
  if (shorter < 4) return false;
  if (RegExp(r'\d').hasMatch(a) || RegExp(r'\d').hasMatch(b)) return false;
  final limit = shorter >= 8 ? 2 : 1;
  if ((a.length - b.length).abs() > limit) return false;
  return _editDistance(a, b, limit) <= limit;
}

/// The Levenshtein distance of [a] and [b], or more than [limit] once it
/// is sure to exceed it.
int _editDistance(String a, String b, int limit) {
  final x = a.runes.toList();
  final y = b.runes.toList();
  var previous = List.generate(y.length + 1, (j) => j);
  for (var i = 1; i <= x.length; i++) {
    final current = List.filled(y.length + 1, 0)..[0] = i;
    var best = current[0];
    for (var j = 1; j <= y.length; j++) {
      final cost = x[i - 1] == y[j - 1] ? 0 : 1;
      current[j] = math.min(
        math.min(current[j - 1] + 1, previous[j] + 1),
        previous[j - 1] + cost,
      );
      best = math.min(best, current[j]);
    }
    if (best > limit) return limit + 1;
    previous = current;
  }
  return previous[y.length];
}

/// Lower-case letters with diacritics and the letters they fold to
/// ([_plain], one for one): Latin, Vietnamese and Greek, from Unicode's
/// canonical decompositions (generated with Python's `unicodedata`), and
/// Russian ё.
const _accented =
    'àáâãäåçèéêëìíîïñòóôõöùúûüýÿāăąćĉċčďēĕėęěĝğġģĥĩīĭįĵķĺļľńņňōŏő'
    'ŕŗřśŝşšţťũūŭůűųŵŷźżžơưǎǐǒǔǖǘǚǜǟǡǣǧǩǫǭǯǰǵǹǻǽǿȁȃȅȇȉȋȍȏȑȓȕȗșțȟȧ'
    'ȩȫȭȯȱȳḁḃḅḇḉḋḍḏḑḓḕḗḙḛḝḟḡḣḥḧḩḫḭḯḱḳḵḷḹḻḽḿṁṃṅṇṉṋṍṏṑṓṕṗṙṛṝṟṡṣṥṧṩṫ'
    'ṭṯṱṳṵṷṹṻṽṿẁẃẅẇẉẋẍẏẑẓẕẖẗẘẙẛạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợ'
    'ụủứừửữựỳỵỷỹΐάέήίΰϊϋόύώἀἁἂἃἄἅἆἇἐἑἒἓἔἕἠἡἢἣἤἥἦἧἰἱἲἳἴἵἶἷὀὁὂὃὄὅὐὑ'
    'ὒὓὔὕὖὗὠὡὢὣὤὥὦὧὰάὲέὴήὶίὸόὺύὼώᾀᾁᾂᾃᾄᾅᾆᾇᾐᾑᾒᾓᾔᾕᾖᾗᾠᾡᾢᾣᾤᾥᾦᾧᾰᾱᾲᾳᾴᾶᾷῂ'
    'ῃῄῆῇῐῑῒΐῖῗῠῡῢΰῤῥῦῧῲῳῴῶῷё';
const _plain =
    'aaaaaaceeeeiiiinooooouuuuyyaaaccccdeeeeegggghiiiijklllnnnooo'
    'rrrssssttuuuuuuwyzzzouaiouuuuuaaægkooʒjgnaæøaaeeiioorruustha'
    'eooooyabbbcdddddeeeeefghhhhhiikkkllllmmmnnnnoooopprrrrssssst'
    'tttuuuuuvvwwwwwxxyzzzhtwyſaaaaaaaaaaaaeeeeeeeeiioooooooooooo'
    'uuuuuuuyyyyιαεηιυιυουωααααααααεεεεεεηηηηηηηηιιιιιιιιοοοοοουυ'
    'υυυυυυωωωωωωωωααεεηηιιοουυωωααααααααηηηηηηηηωωωωωωωωαααααααη'
    'ηηηηιιιιιιυυυυρρυυωωωωωе';
