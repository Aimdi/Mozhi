/// Regular expressions for spans that must never be translated.
///
/// Used by the Documents feature (per format) and, for the main translate
/// screen, by `TextMasker` (spans masked before a machine translation
/// engine sees them) and `TranslationQa` (spans that must come back).
///
/// The sources need `RegExp(..., unicode: true)` ([email] uses Unicode
/// property classes); [combine] compiles them so.
abstract final class ProtectedPatterns {
  /// `http(s)://…`, `ftp://…` and `www.…` URLs (trailing punctuation
  /// excluded).
  static const url =
      r'''(?:(?:https?|ftp)://|www\.)[^\s<>\[\]`"]*[^\s<>\[\]`".,;:!?)']''';

  /// E-mail addresses, also with letters of any script written with spaces
  /// (`jürgen@example.de`, `info@müller.de`, `иван@пример.рф`) and
  /// punycode top-level domains (`xn--p1ai`). Never starts inside a word,
  /// and never takes in Chinese, Japanese, Korean, Thai, Lao, Khmer,
  /// Myanmar or Tibetan characters, as text in those scripts runs on
  /// without spaces around an address (`请发邮件至info@example.com获取`).
  /// A trailing dot (end of a sentence) is left out. Needs
  /// `unicode: true`.
  static const email =
      '(?<!$_emailChar|[._%+-])(?:$_emailChar|[._%+-])+'
      '@(?:$_emailChar|-)+(?:\\.(?:$_emailChar|-)+)*'
      '\\.(?:xn--[A-Za-z0-9-]+|(?:(?!\\p{N})$_emailChar){2,})';

  /// A letter, combining mark or digit of a script written with spaces
  /// (see [email]).
  static const _emailChar =
      r'(?:(?![\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}'
      r'\p{Script=Hangul}\p{Script=Thai}\p{Script=Lao}\p{Script=Khmer}'
      r'\p{Script=Myanmar}\p{Script=Tibetan}])[\p{L}\p{M}\p{N}])';

  /// HTML/XML tags and comments.
  static const htmlTag =
      r'<!--[\s\S]*?-->|</?[A-Za-z][\w:.-]*(?:\s+[^<>]*?)?\s*/?>';

  /// `&amp;`, `&#160;`, `&#x2014;`.
  static const htmlEntity =
      '&(?:#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]*);';

  /// printf-style placeholders (`%s`, `%1$d`, `%.2f`, `%@`, `%(name)s`).
  static const printf =
      r'%(?:\d+\$)?(?:\([A-Za-z_]\w*\))?[-+ 0#]*\d*(?:\.\d+)?[sdifuxXeEgGcp@]';

  /// [printf] for free text: without the space flag and not followed by a
  /// letter, so that "100% done" or "50%off" are not placeholders.
  static const printfInText =
      r'%(?:\d+\$)?(?:\([A-Za-z_]\w*\))?[-+0#]*\d*(?:\.\d+)?[sdifuxXeEgGcp@](?![A-Za-z])';

  /// Template placeholders: `{{name}}`, `${name}`, `$t(key)`,
  /// vue-i18n `@:key`.
  static const template =
      r'\{\{[^{}]*\}\}|\$\{[^{}]*\}|\$t\([^()]*\)|@(?:\.\w+)?:[\w.]+';

  /// Single-brace placeholders: `{name}`, `{0}`, `{user.name}` (not ICU
  /// messages such as `{count, plural, ...}`).
  static const braces = r'\{(?:[A-Za-z_][\w.-]*|\d+)\}';

  /// A whole pattern from alternatives (compiled with `unicode: true`).
  static RegExp combine(List<String> alternatives) => RegExp(
    alternatives.map((pattern) => '(?:$pattern)').join('|'),
    unicode: true,
  );

  /// Plain text: URLs and e-mail addresses.
  static final RegExp plainText = combine([url, email]);

  /// Subtitle cues: formatting tags (`<i>`, `<font …>`, WebVTT `<v Name>`,
  /// `<c.yellow>`, timestamps), ASS overrides (`{\an8}`) and entities.
  static final RegExp subtitle = combine([
    r'<[^<>\n]+>',
    r'\{\\[^{}\n]*\}',
    htmlEntity,
  ]);

  /// Markdown inline content.
  static final RegExp markdown = combine([
    // Code spans (single or double backticks).
    r'``(?:[^`]|`(?!`))+``|`[^`\n]+`',
    // Images are kept whole.
    r'!\[[^\]\n]*\]\([^()\s]*(?:\([^()]*\))?[^()\s]*(?:\s+"[^"]*")?\)',
    // Link destinations and reference labels right after `]`.
    r'''(?<=\])\((?:[^()\s]|\([^()]*\))*(?:\s+(?:"[^"]*"|'[^']*'|\([^()]*\)))?\)''',
    r'(?<=\])\[[^\]\n]*\]',
    // Footnote references.
    r'\[\^[^\]\n]+\]',
    // Autolinks.
    r'<(?:https?|ftp|mailto):[^<>\s]+>|<[^<>\s@]+@[^<>\s@]+>',
    htmlTag,
    htmlEntity,
    url,
    email,
    // Inline math.
    r'\$\$[^$\n]+\$\$',
  ]);

  /// JSON / ARB string values (ICU arguments are handled structurally).
  static final RegExp json = combine([
    htmlTag,
    htmlEntity,
    url,
    email,
    template,
    printf,
  ]);

  /// Placeholders of free text ([template], [braces], [printfInText]).
  static final RegExp placeholders = combine([template, braces, printfInText]);

  /// Everything a machine translation engine should get masked in free
  /// text (the translate screen): tags, entities, URLs, e-mail addresses
  /// and placeholders.
  static final RegExp translation = combine([
    htmlTag,
    htmlEntity,
    url,
    email,
    template,
    braces,
    printfInText,
  ]);
}
