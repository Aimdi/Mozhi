import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/cubit/offline_models_cubit.dart';
import 'package:mozhi/offline/data/bergamot_model_details.dart'
    show offlineModelDetailsOf;
import 'package:mozhi/offline/view/offline_models_page.dart'
    show MeteredDownloadDialog, offlineOutcomeMessage;
import 'package:mozhi/offline/widgets/offline_engine_badge.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/language_search.dart';
import 'package:mozhi/translate/widgets/language_text.dart';
import 'package:mozhi/translate/widgets/offline_offer.dart';
import 'package:mozhi/translate/widgets/shortcuts_help.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

/// Largest size of the picker as a dialog (wide windows).
const languagePickerDialogSize = Size(560, 720);

/// Largest size of the picker as a dropdown under a language button (wide
/// windows, see [showLanguagePicker]).
const languagePickerDropdownSize = Size(960, 560);

/// Whether the language picker focuses its search field when it opens:
/// on large screens ([wide]) and after keyboard use (the focus highlight
/// is the keyboard's). After a touch on a phone it does not (the on-screen
/// keyboard would cover the list); a key typed on a hardware keyboard
/// still starts the search there ([LanguagePickerSheet]).
bool languagePickerAutofocus({required bool wide}) =>
    wide ||
    FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

/// Opens the searchable language picker; resolves to the chosen language
/// (null when dismissed). [source] picks the source list (with "Detect
/// language"), otherwise the target list (with custom styles for AI). Both
/// offer a free-form custom language for AI engines that take them.
/// [autofocusSearch] focuses the search field (keyboard users can type to
/// filter right away); by default [languagePickerAutofocus].
///
/// Full screen on phones. From [TranslateLayout.wideBreakpoint] it drops
/// down under the language button at [anchor] (in global coordinates) as
/// a grid of columns, like Google Translate's, or is a dialog without an
/// anchor. Tapping outside or Esc closes each, as does the close button.
/// The offline engine provided above [context] (if any) marks the
/// languages that work offline.
Future<Language?> showLanguagePicker(
  BuildContext context, {
  required bool source,
  bool? autofocusSearch,
  Rect? anchor,
}) {
  final translate = context.read<TranslateCubit>();
  final settings = context.read<SettingsCubit>();
  final offline = maybeOfflineTranslator(context);
  final store = _maybeStore(context);
  final wide =
      MediaQuery.sizeOf(context).width >= TranslateLayout.wideBreakpoint;
  final autofocus = autofocusSearch ?? languagePickerAutofocus(wide: wide);
  Widget picker({required bool grid}) => MultiBlocProvider(
    providers: [
      BlocProvider.value(value: translate),
      BlocProvider.value(value: settings),
    ],
    child: LanguagePickerSheet(
      source: source,
      autofocusSearch: autofocus,
      offlineTranslator: offline,
      offlineStore: store,
      grid: grid,
    ),
  );
  if (wide && anchor != null) {
    final l10n = context.l10n;
    final navigator = Navigator.of(context, rootNavigator: true);
    return navigator.push(
      _LanguageDropdownRoute(
        anchor: anchor,
        title: source
            ? l10n.translatePickerSourceTitle
            : l10n.translatePickerTargetTitle,
        barrierLabel: MaterialLocalizations.of(context)
            .modalBarrierDismissLabel,
        themes: InheritedTheme.capture(from: context, to: navigator.context),
        builder: (_) => picker(grid: true),
      ),
    );
  }
  return showDialog<Language>(
    context: context,
    builder: (_) {
      if (!wide) return Dialog.fullscreen(child: picker(grid: false));
      return Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints.loose(languagePickerDialogSize),
          child: picker(grid: false),
        ),
      );
    },
  );
}

/// The app's preferences store, when one is provided above [context].
KeyValueStore? _maybeStore(BuildContext context) {
  try {
    return context.read<KeyValueStore>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// The dropdown of [showLanguagePicker] on large screens: the picker in a
/// panel under (or, without room, above) the language button at [anchor].
class _LanguageDropdownRoute extends PopupRoute<Language> {
  new({
    required this.anchor,
    required this.title,
    required this.barrierLabel,
    required this.themes,
    required this.builder,
  });

  /// The language button, in global coordinates.
  final Rect anchor;

  /// What screen readers announce for the panel.
  final String title;
  final CapturedThemes themes;
  final WidgetBuilder builder;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 150);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return themes.wrap(
      Builder(
        builder: (context) {
          final media = MediaQuery.of(context);
          final theme = Theme.of(context);
          final menu = theme.popupMenuTheme;
          return CustomSingleChildLayout(
            delegate: LanguageDropdownLayout(
              anchor: anchor,
              textDirection: Directionality.of(context),
              padding:
                  media.padding +
                  EdgeInsets.only(bottom: media.viewInsets.bottom),
            ),
            child: Semantics(
              scopesRoute: true,
              namesRoute: true,
              explicitChildNodes: true,
              label: title,
              // Like the app's menus: their colour, outline and shadow.
              child: Material(
                key: const Key('translate_language_dropdown'),
                elevation: menu.elevation ?? 3,
                color: menu.color ?? theme.colorScheme.surfaceContainer,
                surfaceTintColor: menu.surfaceTintColor,
                shape:
                    menu.shape ??
                    RoundedRectangleBorder(
                      borderRadius: AppLook.of(context).menuRadius,
                      side: BorderSide(color: theme.colorScheme.outline),
                    ),
                clipBehavior: Clip.antiAlias,
                child: builder(context),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return child;
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    );
  }
}

/// Places the language picker's dropdown: under the [anchor] (the
/// language button) when there is room for at least [minHeight] there (or
/// more room than above it), otherwise above it; aligned with the
/// anchor's start, at most [languagePickerDropdownSize] and kept [margin]
/// inside the window (less its [padding]: system bars, the keyboard).
class LanguageDropdownLayout extends SingleChildLayoutDelegate {
  const new({
    required this.anchor,
    required this.textDirection,
    this.padding = EdgeInsets.zero,
  });

  /// Space kept free along the window's edges.
  static const double margin = 16;

  /// Space between the anchor and the panel.
  static const double gap = 4;

  /// Height under the anchor that is enough to open downwards.
  static const double minHeight = 280;

  final Rect anchor;
  final TextDirection textDirection;
  final EdgeInsets padding;

  /// Whether the panel opens downwards, and its height, in a window of
  /// [size].
  (bool, double) _vertical(Size size) {
    final below = size.height - padding.bottom - margin - anchor.bottom - gap;
    final above = anchor.top - gap - padding.top - margin;
    final down = below >= minHeight || below >= above;
    final room = down ? below : above;
    return (down, clampDouble(room, 0, languagePickerDropdownSize.height));
  }

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final size = constraints.biggest;
    final width = clampDouble(
      size.width - padding.horizontal - 2 * margin,
      0,
      languagePickerDropdownSize.width,
    );
    return BoxConstraints.tight(Size(width, _vertical(size).$2));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final (down, _) = _vertical(size);
    final minX = padding.left + margin;
    final maxX = math.max(
      minX,
      size.width - padding.right - margin - childSize.width,
    );
    final x = textDirection == TextDirection.ltr
        ? anchor.left
        : anchor.right - childSize.width;
    final y = down ? anchor.bottom + gap : anchor.top - gap - childSize.height;
    return Offset(clampDouble(x, minX, maxX), y);
  }

  @override
  bool shouldRelayout(LanguageDropdownLayout oldDelegate) =>
      anchor != oldDelegate.anchor ||
      textDirection != oldDelegate.textDirection ||
      padding != oldDelegate.padding;
}

/// What the target picker of an AI engine with styles shows while nothing
/// is searched.
enum _PickerTab { languages, styles }

/// Sections: Detect language and Detected (source: the language detected
/// in the input, and other likely ones), Recent, Pinned, Downloaded
/// (offline) and All languages; the target list of an AI engine keeps its
/// Styles (custom "languages" such as Pirate speak) behind a "Styles"
/// segment, so the languages come first. Languages are shown with their
/// names in the UI language (`context.languageName`: "Französisch" in
/// German), All languages sorted by them ([sortLanguagesByName]), and with
/// the native name below when it differs. Searching filters by the name
/// in the UI language, English name, native name and code, ignoring case
/// and diacritics ([matchLanguages]: "francais" finds Français), and lists
/// matching styles after the languages.
///
/// A list ([grid] false: phones, the dialog) or a grid of columns ([grid]:
/// the dropdown of large screens).
///
/// The search field takes the focus when the picker opens with
/// [autofocusSearch]; otherwise the first character typed on a hardware
/// keyboard moves there and starts the search.
///
/// Languages that work offline with the other language of the pair (the
/// target's source, the source's target; any source while it is detected
/// and nothing is detected yet), because the [offlineTranslator]'s models
/// for both are on the device ([offlineReadyLanguages]), carry an offline
/// mark ("Works offline"); the languages whose models are on the device are
/// also listed under "Downloaded (offline)". In the Android app, a language
/// the offline engine supports but has not downloaded offers "Download"
/// in its row: the offline languages' own download
/// ([OfflineModelsCubit.download]: their "Wi-Fi only" choice from
/// [offlineStore], the same question before using mobile data).
///
/// Recent and pinned languages show a pin button to unpin or pin them;
/// the others show it while hovered or focused, and a long press pins or
/// unpins any language. The pin and download buttons are their own
/// controls next to the row's, not inside it.
///
/// The target list's Pinned section is `TranslateState.pinnedTargets` (the
/// pins the engine offers, matched like everywhere else); on desktop its
/// first nine entries show their shortcut (Alt+1 … Alt+9, see
/// [translatePinnedShortcut]).
///
/// When the engine takes custom languages
/// (`TranslateState.supportsCustomLanguages`, AI engines with the general
/// prompt profile), a search without matches offers "Use “…” as custom
/// language" (Enter picks it) in both lists, e.g. "Gen Z slang" as the
/// source or "Pirate speak" as the target.
class LanguagePickerSheet extends StatefulWidget {
  const new({
    required this.source,
    this.autofocusSearch = false,
    this.offlineTranslator,
    this.offlineStore,
    this.grid = false,
    super.key,
  });

  final bool source;

  /// Focus the search field when the picker opens.
  final bool autofocusSearch;

  /// The device's offline engine (defaults to the one provided above).
  final OfflineTranslator? offlineTranslator;

  /// Where the offline languages keep their "Wi-Fi only" choice (defaults
  /// to the app's preferences provided above).
  final KeyValueStore? offlineStore;

  /// Whether the languages are laid out in columns.
  final bool grid;

  @override
  State<LanguagePickerSheet> createState() => _LanguagePickerSheetState();
}

class _LanguagePickerSheetState extends State<LanguagePickerSheet> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'translate_language_search');
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  String _query = '';
  _PickerTab _tab = _PickerTab.languages;

  OfflineTranslator? _translator;

  /// [offlineLanguageKey]s of the languages whose models are on the
  /// device.
  Set<String> _offline = const {};

  /// The offline engine's codes by [offlineLanguageKey].
  Map<String, String> _supported = const {};
  bool _offlineRequested = false;

  /// The offline languages' downloads, once one was asked for.
  OfflineModelsCubit? _models;
  StreamSubscription<OfflineModelsState>? _modelsSubscription;
  OfflineModelOutcome? _outcome;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_offlineRequested) return;
    _offlineRequested = true;
    final translator =
        widget.offlineTranslator ?? maybeOfflineTranslator(context);
    if (translator == null || !translator.isAvailable) return;
    _translator = translator;
    _supported = {
      for (final code in translator.supportedLanguages)
        offlineLanguageKey(code): code,
    };
    unawaited(_loadOffline());
  }

  @override
  void dispose() {
    unawaited(_modelsSubscription?.cancel());
    unawaited(_models?.close());
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _loadOffline() async {
    final translator = _translator;
    if (translator == null) return;
    final ready = await offlineReadyLanguages(translator);
    if (mounted && !setEquals(ready, _offline)) {
      setState(() => _offline = ready);
    }
  }

  /// Whether rows offer to download their offline models: in the Android
  /// app, with the offline engine running.
  bool get _offersDownloads =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      _translator != null;

  /// The other language of the pair, as a code: null for "Detect language"
  /// with nothing detected (any source), empty for a custom language.
  String? _otherCode(TranslateState state) {
    final other = widget.source ? state.target : state.source;
    if (other.isCustom) return '';
    if (!other.isAuto) return other.code;
    final detected = state.result?.detectedSource;
    return detected == null || detected.isEmpty ? null : detected;
  }

  /// Whether [language]'s models are on the device.
  bool _downloaded(Language language) =>
      !language.isCustom &&
      !language.isAuto &&
      _offline.contains(offlineLanguageKey(language.code));

  /// Whether [language] works offline with the other language of the pair
  /// ([_otherCode]).
  bool _worksOffline(Language language, String? other) {
    if (!_downloaded(language)) return false;
    if (other == null) return true;
    if (other.isEmpty) return false;
    final key = offlineLanguageKey(other);
    return key == offlineLanguageKey(language.code) || _offline.contains(key);
  }

  /// The offline engine's code for [language] when its row offers the
  /// download: supported, not on the device and not English (the pivot,
  /// part of every model).
  String? _downloadCode(Language language) {
    if (!_offersDownloads || language.isCustom || language.isAuto) {
      return null;
    }
    final key = offlineLanguageKey(language.code);
    if (key == 'en' || _offline.contains(key)) return null;
    return _supported[key];
  }

  Future<void> _download(String code) async {
    final translator = _translator;
    if (translator == null) return;
    var models = _models;
    if (models == null) {
      models = _models = OfflineModelsCubit(
        translator: translator,
        store:
            widget.offlineStore ?? _maybeStore(context) ?? PreferencesStore(),
        details: offlineModelDetailsOf(translator),
      );
      _modelsSubscription = models.stream.listen(_onModels);
      // The "Wi-Fi only" choice (and what is on the device).
      await models.load();
      if (!mounted || models.isClosed) return;
    }
    await models.download(code);
  }

  void _onModels(OfflineModelsState state) {
    if (!mounted) return;
    // Pending downloads and their progress.
    setState(() {});
    final outcome = state.outcome;
    if (outcome == null || identical(outcome, _outcome)) return;
    _outcome = outcome;
    unawaited(_onOutcome(outcome));
  }

  /// As on the offline languages page: asks before using mobile data, and
  /// says how a download went.
  Future<void> _onOutcome(OfflineModelOutcome outcome) async {
    final models = _models;
    if (models == null) return;
    if (outcome.needsMeteredConsent) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => MeteredDownloadDialog(
          language: outcome.language,
          size: models.state.downloadSizeOf(outcome.language.code),
        ),
      );
      if ((confirmed ?? false) && !models.isClosed) {
        await models.download(outcome.language.code, overMeteredNetwork: true);
      }
      return;
    }
    if (outcome.succeeded) await _loadOffline();
    if (!mounted) return;
    _messenger.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(offlineOutcomeMessage(context.l10n, outcome))),
      );
  }

  void _pick(Language language) => Navigator.of(context).pop(language);

  void _setQuery(String query) => setState(() => _query = query);

  /// A character typed on a hardware keyboard while the search field has
  /// no focus starts the search with it.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || _searchFocus.hasFocus) {
      return KeyEventResult.ignored;
    }
    final character = event.character;
    final keyboard = HardwareKeyboard.instance;
    if (character == null ||
        character.trim().isEmpty ||
        character.runes.any((rune) => rune < 0x20 || rune == 0x7F) ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final text = '${_search.text}$character';
    _search.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _setQuery(text);
    _searchFocus.requestFocus();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = context.watch<TranslateCubit>().state;
    final settings = context.watch<SettingsCubit>().state;
    final source = widget.source;
    final languages = source ? state.sourceLanguages : state.targetLanguages;
    final selected = source ? state.source : state.target;
    final allowCustom = state.supportsCustomLanguages;
    final styles = allowCustom && !source
        ? LanguageCatalog.customSuggestions.map(Language.custom).toList()
        : const <Language>[];
    final tabs = styles.isNotEmpty && _query.trim().isEmpty;
    final tab = tabs ? _tab : _PickerTab.languages;

    final items = _items(
      context,
      state: state,
      settings: settings,
      languages: languages,
      selected: selected,
      allowCustom: allowCustom,
      styles: styles,
      tab: tab,
    );

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                key: const Key('translate_language_close'),
                tooltip: l10n.commonClose,
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    source
                        ? l10n.translatePickerSourceTitle
                        : l10n.translatePickerTargetTitle,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 12),
            child: Semantics(
              label: l10n.commonSearch,
              child: TextField(
                key: const Key('translate_language_search'),
                controller: _search,
                focusNode: _searchFocus,
                enableIMEPersonalizedLearning: imeLearningAllowed(context),
                autofocus: widget.autofocusSearch,
                onChanged: _setQuery,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _submitSearch(languages, allowCustom),
                decoration: InputDecoration(
                  hintText: l10n.translatePickerSearchHint,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: l10n.commonClear,
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _search.clear();
                            _setQuery('');
                          },
                        ),
                ),
              ),
            ),
          ),
          if (tabs)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 12, top: 12),
              child: SegmentedButton<_PickerTab>(
                key: const Key('translate_language_tabs'),
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: _PickerTab.languages,
                    label: Text(l10n.translatePickerLanguagesTab),
                  ),
                  ButtonSegment(
                    value: _PickerTab.styles,
                    icon: const Icon(Icons.auto_awesome),
                    label: Text(l10n.translatePickerStyles),
                  ),
                ],
                selected: {tab},
                onSelectionChanged: (selection) =>
                    setState(() => _tab = selection.first),
              ),
            ),
        ],
      ),
    );

    // The header sits outside the scroll view so it can never cover the
    // focused row while keyboard focus moves through the list. A local
    // messenger shows how a download went inside the picker.
    return ScaffoldMessenger(
      key: _messenger,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        // Esc closes the picker (the scaffold's own Esc only closes
        // drawers, and would shadow the route's).
        body: Actions(
          actions: {
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (_) => Navigator.of(context).maybePop(),
            ),
          },
          child: Focus(
            autofocus: !widget.autofocusSearch,
            onKeyEvent: _onKeyEvent,
            child: Column(
              children: [
                header,
                Expanded(
                  child: CustomScrollView(
                    key: const Key('translate_language_list'),
                    slivers: [
                      ..._slivers(context, items, state),
                      SliverPadding(
                        padding: EdgeInsets.only(
                          bottom: 24 + MediaQuery.viewInsetsOf(context).bottom,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Enter picks the single/first match, or the custom language.
  void _submitSearch(List<Language> languages, bool allowCustom) {
    final query = _query.trim();
    if (query.isEmpty) return;
    final matches = matchLanguages(
      languages,
      query,
      displayName: context.languageName,
    );
    if (matches.isNotEmpty) {
      _pick(matches.first);
    } else if (allowCustom) {
      _pick(Language.custom(query));
    }
  }

  /// [items] as slivers: one list, or the languages in grids between the
  /// headers ([LanguagePickerSheet.grid]).
  List<Widget> _slivers(
    BuildContext context,
    List<_Item> items,
    TranslateState state,
  ) {
    final other = _otherCode(state);
    if (!widget.grid) {
      return [
        SliverList.list(
          children: [
            for (final item in items) _itemWidget(item, other, dense: false),
          ],
        ),
      ];
    }
    final extent = math.max(64, MediaQuery.textScalerOf(context).scale(64));
    final slivers = <Widget>[];
    var run = <_LanguageItem>[];
    void flush() {
      if (run.isEmpty) return;
      final tiles = run;
      run = [];
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 240,
              mainAxisExtent: extent.toDouble(),
              crossAxisSpacing: 8,
            ),
            delegate: SliverChildListDelegate([
              for (final tile in tiles) _itemWidget(tile, other, dense: true),
            ]),
          ),
        ),
      );
    }

    for (final item in items) {
      if (item is _LanguageItem) {
        run.add(item);
      } else {
        flush();
        slivers.add(
          SliverToBoxAdapter(child: _itemWidget(item, other, dense: true)),
        );
      }
    }
    flush();
    return slivers;
  }

  Widget _itemWidget(_Item item, String? other, {required bool dense}) {
    switch (item) {
      case _WidgetItem(:final child):
        return child;
      case _LanguageItem():
        final language = item.language;
        final download = _downloadCode(language);
        final models = _models?.state;
        return _LanguageTile(
          key: ValueKey((item.section, language.code)),
          language: language,
          selected: item.selected,
          pinned: item.pinned,
          alwaysShowPin: item.alwaysShowPin,
          offline: _worksOffline(language, other),
          shortcut: item.shortcut,
          dense: dense,
          onTap: () => _pick(language),
          onTogglePin: () => context.read<SettingsCubit>().togglePinnedLanguage(
            item.pin ?? language,
          ),
          download: download == null
              ? null
              : (
                  label: offlineDownloadLabel(context.l10n, [
                    (
                      code: download,
                      name: context.languageName(language),
                      bytes: offlineModelDetailsOf(_translator!)
                          ?.downloadSize(download),
                    ),
                  ]),
                  pending: models?.pending.containsKey(download) ?? false,
                  progress: models?.progress[download],
                  onPressed: () => unawaited(_download(download)),
                  cancelLabel: context.l10n.offlineCancelDownloadTooltip(
                    context.languageName(language),
                  ),
                  onCancel: (models?.canCancelDownload(download) ?? false)
                      ? () => unawaited(_models?.cancelDownload(download))
                      : null,
                  cancellable: models?.canCancel ?? false,
                ),
        );
    }
  }

  List<_Item> _items(
    BuildContext context, {
    required TranslateState state,
    required AppSettings settings,
    required List<Language> languages,
    required Language selected,
    required bool allowCustom,
    required List<Language> styles,
    required _PickerTab tab,
  }) {
    final l10n = context.l10n;
    final query = _query.trim();
    final regular = languages.where((l) => !l.isAuto).toList();
    final pinned = settings.pinnedLanguages;

    _LanguageItem Function(Language) items(String section) =>
        (language) => _LanguageItem(
          section: section,
          language: language,
          selected: language == selected,
          pinned: pinned.contains(language),
          alwaysShowPin: section == 'recent',
        );

    _Item header(String title, {Key? key}) =>
        _WidgetItem(_Header(title, key: key));

    if (query.isNotEmpty) {
      final matches = matchLanguages(
        regular,
        query,
        displayName: context.languageName,
      );
      // Style suggestions are target languages ("Translate into Pirate
      // speak"); a custom source is typed.
      final folded = foldForSearch(query);
      final matchingStyles = [
        for (final style in styles)
          if (foldForSearch(style.name).contains(folded)) style,
      ];
      return [
        if (matches.isEmpty && allowCustom)
          _WidgetItem(
            ListTile(
              key: const Key('translate_language_custom'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              leading: const Icon(Icons.auto_awesome),
              title: Text(l10n.translatePickerUseCustom(query)),
              subtitle: Text(
                widget.source
                    ? l10n.translatePickerCustomSourceHint
                    : l10n.translatePickerCustomHint,
              ),
              onTap: () => _pick(Language.custom(query)),
            ),
          ),
        if (matches.isEmpty && !allowCustom)
          _WidgetItem(
            Padding(
              padding: const EdgeInsets.all(24),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  l10n.translatePickerNoResults(query),
                  key: const Key('translate_language_no_results'),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ...matches.map(items('matches')),
        if (matchingStyles.isNotEmpty) ...[
          header(l10n.translatePickerStyles),
          _WidgetItem(
            _StyleChips(
              styles: matchingStyles,
              selected: selected,
              onPick: _pick,
            ),
          ),
        ],
      ];
    }

    if (tab == _PickerTab.styles) {
      return [
        _WidgetItem(
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
            child: Text(
              l10n.translatePickerCustomHint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        _WidgetItem(
          _StyleChips(styles: styles, selected: selected, onPick: _pick),
        ),
      ];
    }

    Language? available(Language wanted) {
      if (wanted.isCustom) return allowCustom ? wanted : null;
      for (final language in regular) {
        if (language == wanted) return language;
      }
      return null;
    }

    final recents = settings.recentLanguages.map(available).nonNulls.toList();
    // Targets: the pins as the engine lists them, in the order the
    // shortcuts number them. Each tile (un)pins the stored language.
    final pinnedAvailable = widget.source
        ? pinned.map(available).nonNulls.toList()
        : state.pinnedTargets(pinned);
    Language pinOf(Language listed) => widget.source
        ? listed
        : pinned.firstWhere(
            (pin) => state.usableTarget(pin) == listed,
            orElse: () => listed,
          );
    final platform = Theme.of(context).platform;
    final hints = !widget.source && showsShortcutHints(platform);
    final auto = widget.source
        ? languages.where((l) => l.isAuto).firstOrNull
        : null;
    final detected = state.result?.detectedSource;
    final detectedLanguages = widget.source
        ? _detected(state, regular)
        : const <Language>[];
    final downloaded = regular.where(_downloaded).toList();

    return [
      if (auto != null)
        _WidgetItem(
          ListTile(
            key: const Key('translate_language_auto'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            leading: const Icon(Icons.auto_awesome_outlined),
            title: Text(l10n.translateDetectLanguage),
            subtitle: detected == null
                ? null
                : Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _DetectedChip(
                        label: l10n.translateDetectedLanguage(
                          localizedLanguageNameFor(context, detected, regular),
                        ),
                      ),
                    ),
                  ),
            selected: selected.isAuto,
            trailing: selected.isAuto ? const Icon(Icons.check) : null,
            onTap: () => _pick(auto),
          ),
        ),
      if (detectedLanguages.isNotEmpty) ...[
        header(
          l10n.translatePickerDetected,
          key: const Key('translate_language_section_detected'),
        ),
        ...detectedLanguages.map(items('detected')),
      ],
      if (recents.isNotEmpty) ...[
        header(l10n.translatePickerRecent),
        ...recents.map(items('recent')),
      ],
      if (pinnedAvailable.isNotEmpty) ...[
        header(l10n.translatePickerPinned),
        for (final (index, language) in pinnedAvailable.indexed)
          _LanguageItem(
            section: 'pinned',
            language: language,
            selected: language == selected,
            pinned: true,
            alwaysShowPin: true,
            pin: pinOf(language),
            shortcut: hints
                ? translatePinnedShortcut(
                    index,
                    command: shortcutUsesCommandKey(platform),
                  )
                : null,
          ),
      ],
      if (downloaded.isNotEmpty) ...[
        header(
          l10n.translatePickerDownloaded,
          key: const Key('translate_language_section_downloaded'),
        ),
        ...downloaded.map(items('downloaded')),
      ],
      header(l10n.translatePickerAll),
      ...sortLanguagesByName(regular, context.languageName).map(items('all')),
    ];
  }

  /// The language detected in the input, then the other likely ones (an
  /// uncertain detection), as [regular] lists them.
  static List<Language> _detected(
    TranslateState state,
    List<Language> regular,
  ) {
    final code = state.result?.detectedSource;
    if (code == null || code.isEmpty) return const [];
    final detected = LanguageMatcher.match(
      Language(code: code, name: code),
      regular,
    );
    return [
      ?detected,
      for (final language in state.detectedAlternativeLanguages)
        if (language != detected && regular.contains(language)) language,
    ];
  }
}

/// An entry of the language picker: a language ([_LanguageItem]) or
/// anything else ([_WidgetItem]: headers, "Detect language", the custom
/// language, styles).
sealed class _Item {
  const new();
}

final class _WidgetItem extends _Item {
  const new(this.child);

  final Widget child;
}

final class _LanguageItem extends _Item {
  const new({
    required this.section,
    required this.language,
    required this.selected,
    required this.pinned,
    this.alwaysShowPin = false,
    this.pin,
    this.shortcut,
  });

  /// The section it is listed in (a language can be in several).
  final String section;
  final Language language;
  final bool selected;
  final bool pinned;

  /// Whether the pin button always shows (Recent and Pinned), not only
  /// while the row is hovered or focused.
  final bool alwaysShowPin;

  /// The stored pin that [language] stands for (else [language]).
  final Language? pin;

  /// The keyboard shortcut that picks this language.
  final ({String keys, String keysSemantics})? shortcut;
}

class _Header extends StatelessWidget {
  const new(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
        child: Text(
          title,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

/// Custom AI "languages" (LinkedIn Speak, Pirate speak, ...) as chips.
class _StyleChips extends StatelessWidget {
  const new({
    required this.styles,
    required this.selected,
    required this.onPick,
  });

  final List<Language> styles;
  final Language selected;
  final ValueChanged<Language> onPick;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final style in styles)
            ChoiceChip(
              avatar: const Icon(Icons.auto_awesome),
              label: Text(style.name),
              selected: style == selected,
              showCheckmark: true,
              onSelected: (_) => onPick(style),
            ),
        ],
      ),
    );
  }
}

class _DetectedChip extends StatelessWidget {
  const new({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: AppLook.of(context).badgeRadius,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium
              ?.copyWith(color: scheme.onSecondaryContainer),
        ),
      ),
    );
  }
}

/// The download of a [_LanguageTile]'s offline models: the button's
/// `label` ("Download German (25 MB)"), whether it is `pending` (with its
/// `progress`, 0 to 1, when known) and what starts it. While it runs and
/// the engine can stop it (`cancellable`), the progress ring is a Cancel
/// button (`cancelLabel`: "Cancel downloading German") that calls
/// `onCancel` (null while it is being stopped: disabled).
typedef _OfflineDownloadAction = ({
  String label,
  bool pending,
  double? progress,
  VoidCallback onPressed,
  String cancelLabel,
  bool cancellable,
  VoidCallback? onCancel,
});

/// A language: its name (with the offline mark when it works offline) and
/// native name; a long press pins or unpins it ([onTogglePin]).
///
/// The pin button shows with [alwaysShowPin] (Recent and Pinned), else
/// while the row is hovered or has the keyboard focus (it, or the pin
/// button itself). It and the download button ([download]) lie over the
/// row's end as controls of their own beside the row's (not inside it).
/// [dense]: a cell of the grid layout (one line each for the names).
class _LanguageTile extends StatefulWidget {
  const new({
    required this.language,
    required this.selected,
    required this.pinned,
    required this.onTap,
    required this.onTogglePin,
    this.alwaysShowPin = false,
    this.offline = false,
    this.shortcut,
    this.download,
    this.dense = false,
    super.key,
  });

  final Language language;
  final bool selected;
  final bool pinned;
  final bool alwaysShowPin;
  final VoidCallback onTap;
  final VoidCallback onTogglePin;

  /// Whether it works offline (with the other language of the pair).
  final bool offline;

  /// The keyboard shortcut that picks this language, shown at the end.
  final ({String keys, String keysSemantics})? shortcut;

  /// Its offline models' download, when offered.
  final _OfflineDownloadAction? download;

  final bool dense;

  @override
  State<_LanguageTile> createState() => _LanguageTileState();
}

class _LanguageTileState extends State<_LanguageTile> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final language = widget.language;
    final native = language.nativeName;
    final name = context.languageName(language);
    final shortcut = widget.shortcut;
    final download = widget.download;
    final dense = widget.dense;
    final showPin = widget.alwaysShowPin || _hovered || _focused;
    final pinLabel = widget.pinned
        ? l10n.translateUnpin(name)
        : l10n.translatePin(name);
    final lines = dense ? 1 : null;
    final overflow = dense ? TextOverflow.ellipsis : null;
    final title = widget.offline
        ? Text.rich(
            TextSpan(
              children: [
                TextSpan(text: name),
                const TextSpan(text: ' '),
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Tooltip(
                    message: l10n.translateOfflineWorks,
                    child: Icon(
                      OfflineEngineBadge.icon,
                      key: ValueKey(
                        'translate_language_offline:${language.code}',
                      ),
                      size: 18,
                      color: theme.colorScheme.tertiary,
                      semanticLabel: l10n.translateOfflineWorks,
                    ),
                  ),
                ),
              ],
            ),
            maxLines: lines,
            overflow: overflow,
          )
        : Text(name, maxLines: lines, overflow: overflow);
    final buttons = [
      if (download != null && download.pending && download.cancellable)
        _CancelDownloadButton(
          key: ValueKey('translate_language_cancel_download:${language.code}'),
          label: download.cancelLabel,
          progress: download.progress,
          onPressed: download.onCancel,
        )
      else if (download != null && download.pending)
        SizedBox.square(
          key: ValueKey('translate_language_downloading:${language.code}'),
          dimension: kMinInteractiveDimension,
          child: Center(
            child: SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(
                value: download.progress,
                strokeWidth: 2.5,
                semanticsLabel: l10n.offlineDownloading,
              ),
            ),
          ),
        )
      else if (download != null)
        IconButton(
          key: ValueKey('translate_language_download:${language.code}'),
          tooltip: download.label,
          color: theme.colorScheme.primary,
          icon: const Icon(Icons.download_for_offline_outlined),
          onPressed: download.onPressed,
        ),
      if (showPin)
        IconButton(
          key: ValueKey('translate_language_pin:${language.code}'),
          tooltip: pinLabel,
          isSelected: widget.pinned,
          icon: const Icon(Icons.push_pin_outlined),
          selectedIcon: const Icon(Icons.push_pin),
          onPressed: widget.onTogglePin,
        ),
    ];
    final end = dense ? 4.0 : 8.0;
    final tile = Semantics(
      container: true,
      onLongPressHint: pinLabel,
      child: ListTile(
        contentPadding: EdgeInsetsDirectional.only(
          start: dense ? 12 : 24,
          end: end,
        ),
        visualDensity: dense ? VisualDensity.compact : null,
        // A cell of the grid is a rounded box, tinted while selected, so
        // its check mark is not read as the next cell's.
        shape: dense
            ? RoundedRectangleBorder(
                borderRadius: AppLook.of(context).badgeRadius,
              )
            : null,
        selectedTileColor: dense
            ? theme.colorScheme.primary.withValues(alpha: 0.08)
            : null,
        selected: widget.selected,
        leading: language.isCustom ? const Icon(Icons.auto_awesome) : null,
        title: title,
        subtitle: language.isCustom
            ? Text(l10n.translatePickerCustomBadge, maxLines: lines)
            : (native != null && native.isNotEmpty && native != name)
            // The locale makes screen readers use a matching voice and
            // picks the right glyphs (e.g. Japanese vs Chinese Han
            // characters).
            ? Text.rich(
                TextSpan(text: native, locale: localeForLanguage(language)),
                maxLines: lines,
                overflow: overflow,
              )
            : null,
        onTap: widget.onTap,
        onLongPress: widget.onTogglePin,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (shortcut != null)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: Text(
                  shortcut.keys,
                  key: ValueKey('translate_language_shortcut:${language.code}'),
                  semanticsLabel: shortcut.keysSemantics,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (widget.selected) const Icon(Icons.check),
            // Room for the buttons lying over the row's end.
            SizedBox(width: buttons.length * kMinInteractiveDimension),
          ],
        ),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: Stack(
          children: [
            tile,
            if (buttons.isNotEmpty)
              PositionedDirectional(
                end: end,
                top: 0,
                bottom: 0,
                child: Row(mainAxisSize: MainAxisSize.min, children: buttons),
              ),
          ],
        ),
      ),
    );
  }
}

/// Cancel for a running download in a picker row: its progress ring with
/// a stop mark inside, in a 48 dp button whose tooltip and screen reader
/// label say what it stops ("Cancel downloading German"; the progress is
/// its value). [onPressed] null disables it (the download is stopping).
class _CancelDownloadButton extends StatelessWidget {
  const new({
    required this.label,
    required this.progress,
    required this.onPressed,
    super.key,
  });

  final String label;

  /// Fraction received (null: not known yet).
  final double? progress;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final fraction = progress;
    final stopping = onPressed == null;
    final status = stopping
        ? l10n.offlineCancelling
        : fraction == null
        ? l10n.offlineDownloading
        : l10n.offlineDownloadingProgress((fraction * 100).floor());
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: label,
        value: status,
        enabled: !stopping,
        onTap: onPressed,
        excludeSemantics: true,
        child: IconButton(
          onPressed: onPressed,
          icon: SizedBox.square(
            dimension: 24,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(
                    value: stopping ? null : fraction,
                    strokeWidth: 2.5,
                  ),
                ),
                Icon(
                  Icons.close,
                  size: 14,
                  color: stopping
                      ? theme.disabledColor
                      : theme.colorScheme.primary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
