/// Regular expressions for spans that must never be translated.
abstract final class ProtectedPatterns {
  /// `http(s)://…`, `ftp://…` and `www.…` URLs (trailing punctuation
  /// excluded).
  static const url =
      r'''(?:(?:https?|ftp)://|www\.)[^\s<>\[\]`"]*[^\s<>\[\]`".,;:!?)']''';

  static const email = r'[\w.+-]+@[\w-]+(?:\.[\w-]+)*\.[A-Za-z]{2,}';

  /// HTML/XML tags and comments.
  static const htmlTag =
      r'<!--[\s\S]*?-->|</?[A-Za-z][\w:.-]*(?:\s+[^<>]*?)?\s*/?>';

  /// `&amp;`, `&#160;`, `&#x2014;`.
  static const htmlEntity =
      '&(?:#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]*);';

  /// printf-style placeholders (`%s`, `%1$d`, `%.2f`, `%@`, `%(name)s`).
  static const printf =
      r'%(?:\d+\$)?(?:\([A-Za-z_]\w*\))?[-+ 0#]*\d*(?:\.\d+)?[sdifuxXeEgGcp@]';

  /// Template placeholders: `{{name}}`, `${name}`, `$t(key)`,
  /// vue-i18n `@:key`.
  static const template =
      r'\{\{[^{}]*\}\}|\$\{[^{}]*\}|\$t\([^()]*\)|@(?:\.\w+)?:[\w.]+';

  /// A whole pattern from alternatives.
  static RegExp combine(List<String> alternatives) =>
      RegExp(alternatives.map((pattern) => '(?:$pattern)').join('|'));

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
}
