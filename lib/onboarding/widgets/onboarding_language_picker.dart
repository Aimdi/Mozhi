import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:translation_repository/translation_repository.dart';

/// Opens a searchable list of [languages] (with "Detect language" first
/// when [source]); resolves to the chosen language, or null when dismissed.
///
/// Languages for which [isOffline] is true are marked "Available offline".
Future<Language?> showOnboardingLanguagePicker(
  BuildContext context, {
  required bool source,
  required Language selected,
  List<Language>? languages,
  bool Function(Language language)? isOffline,
}) {
  return showModalBottomSheet<Language>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => OnboardingLanguagePicker(
      source: source,
      selected: selected,
      languages: languages ?? LanguageCatalog.all,
      isOffline: isOffline,
    ),
  );
}

/// The list of [showOnboardingLanguagePicker]: a search field and the
/// languages filtered by English name, native name or code.
class OnboardingLanguagePicker extends StatefulWidget {
  const new({
    required this.source,
    required this.selected,
    required this.languages,
    this.isOffline,
    super.key,
  });

  /// Offers "Detect language" ([Language.auto]) first.
  final bool source;
  final Language selected;
  final List<Language> languages;
  final bool Function(Language language)? isOffline;

  @override
  State<OnboardingLanguagePicker> createState() =>
      _OnboardingLanguagePickerState();
}

class _OnboardingLanguagePickerState extends State<OnboardingLanguagePicker> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Language> get _visible {
    final needle = _search.text.trim().toLowerCase();
    final languages = [
      if (widget.source) Language.auto,
      for (final language in widget.languages)
        if (!language.isAuto && !language.isCustom) language,
    ];
    if (needle.isEmpty) return languages;
    return [
      for (final language in languages)
        if (language.name.toLowerCase().contains(needle) ||
            context.languageName(language).toLowerCase().contains(needle) ||
            (language.nativeName?.toLowerCase().contains(needle) ?? false) ||
            language.code.toLowerCase() == needle)
          language,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final visible = _visible;
    final title = widget.source
        ? l10n.onboardingLanguagesFrom
        : l10n.onboardingLanguagesInto;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.9,
      minChildSize: 0.5,
      builder: (context, controller) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              key: const Key('onboarding_language_search'),
              controller: _search,
              enableIMEPersonalizedLearning: imeLearningAllowed(context),
              autocorrect: false,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: l10n.onboardingLanguagesSearch,
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Expanded(
            child: visible.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        l10n.onboardingLanguagesNoMatches(_search.text.trim()),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: AppPalette.of(context).secondaryText,
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: controller,
                    itemCount: visible.length,
                    itemBuilder: (context, index) {
                      final language = visible[index];
                      return _LanguageRow(
                        key: ValueKey(language.code),
                        language: language,
                        selected: language == widget.selected,
                        offline:
                            !language.isAuto &&
                            (widget.isOffline?.call(language) ?? false),
                        onTap: () => Navigator.of(context).pop(language),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _LanguageRow extends StatelessWidget {
  const new({
    required this.language,
    required this.selected,
    required this.offline,
    required this.onTap,
    super.key,
  });

  final Language language;
  final bool selected;
  final bool offline;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final native = language.nativeName;
    final name = context.languageName(language);
    final details = [
      if (native != null && native != name) native,
      if (offline) l10n.onboardingLanguagesAvailableOffline,
    ];
    return ListTile(
      selected: selected,
      leading: language.isAuto
          ? const Icon(Icons.auto_awesome_outlined)
          : LanguageAvatar(code: language.code),
      title: Text(name),
      subtitle: details.isEmpty ? null : Text(details.join(' · ')),
      trailing: selected
          ? Icon(Icons.check, color: theme.colorScheme.primary)
          : offline
          ? ExcludeSemantics(
              child: Icon(
                Icons.offline_pin_outlined,
                color: AppPalette.of(context).secondaryText,
              ),
            )
          : null,
      onTap: onTap,
    );
  }
}
