/// The categories of the settings, in the order they are listed: each has
/// a page of its own below `/settings` ([location]); on wide screens they
/// are the master list of a master | detail layout.
///
/// Plain data (no widgets): the router reads it without loading the
/// deferred settings pages.
enum SettingsCategory {
  /// App language, tab order, haptic feedback, multiline input.
  general('general'),

  /// Privacy mode, incognito, history, the network and, at the end, the
  /// destructive "Clear history" and "Delete all local data".
  privacy('privacy'),

  /// Offline languages, Mozhi instances, translation services, quality
  /// modes and instant translation.
  engines('engines'),

  /// AI providers, the insights assistant, presets, glossaries and usage.
  ai('ai'),

  /// Theme, dark look, accent colour, romanization.
  appearance('appearance'),

  /// Read aloud and voice input.
  speech('speech'),

  /// About Mozhi: version, source code, licences and setup (the existing
  /// About page, `/settings/about`).
  about('about');

  new(this.path);

  /// The category's path segment below `/settings`.
  final String path;

  /// Query parameter naming a row to scroll to and highlight on the
  /// category's page, e.g. `/settings/privacy?row=incognito`.
  static const rowParameter = 'row';

  /// The categories with a route of their own; [about] is the About page.
  static List<SettingsCategory> get routed =>
      values.where((category) => category != about).toList();

  /// The category's location, scrolled to [row] when given.
  String location({String? row}) => Uri(
    path: '/settings/$path',
    queryParameters: row == null ? null : {rowParameter: row},
  ).toString();

  /// The category whose [path] is [path], or null.
  static SettingsCategory? tryParse(String? path) =>
      values.where((category) => category.path == path).firstOrNull;
}
