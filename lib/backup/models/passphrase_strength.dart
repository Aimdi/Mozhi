/// How hard a passphrase is to guess, from its length and number of words
/// only (worked out on the device; nothing is looked up).
///
/// Someone who has a backup file can try passphrases offline as fast as
/// their hardware allows (Argon2id slows each try down, it can't stop
/// them), so length matters most: four or more random words are
/// [strong].
enum PassphraseStrength {
  /// Shorter than [minLength] characters: refused.
  tooShort,

  /// Under 14 characters and fewer than 3 words.
  weak,

  /// 3 words, or 14 characters or more.
  fair,

  /// 4 words or more and 16 characters or more, or 24 characters or more.
  strong;

  /// The shortest passphrase accepted, in characters (Unicode code
  /// points).
  static const minLength = 8;

  /// The strength of [passphrase].
  static PassphraseStrength of(String passphrase) {
    final length = passphrase.runes.length;
    if (length < minLength) return tooShort;
    final words = _word.allMatches(passphrase).length;
    if ((words >= 4 && length >= 16) || length >= 24) return strong;
    if (words >= 3 || length >= 14) return fair;
    return weak;
  }

  /// Whether a passphrase this strong is accepted.
  bool get acceptable => this != tooShort;

  /// A run of letters or digits.
  static final _word = RegExp(r'[\p{L}\p{N}]+', unicode: true);
}
