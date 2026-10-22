import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/image_translate/view/image_translate_page.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/quality_toggle.dart';
import 'package:mozhi/translate/widgets/recent_pairs_sheet.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

/// Most recent language pairs offered in [TranslateHero].
const translateHeroMaxPairs = 3;

/// Space between [TranslateHero]'s quality chip and the app mark.
const double translateHeroChipGap = 32;

/// The greeting for the time of day of [now]: morning from 5:00, afternoon
/// from 12:00, evening from 18:00 (and through the night).
String translateGreeting(AppLocalizations l10n, DateTime now) =>
    switch (now.hour) {
      >= 5 && < 12 => l10n.translateGreetingMorning,
      >= 12 && < 18 => l10n.translateGreetingAfternoon,
      _ => l10n.translateGreetingEvening,
    };

/// The middle of the empty translate screen (like Kagi Translate's start
/// screen): the quality mode chip ([QualityChip], while Fast and Best
/// engines are set up and [showQualityChip]; the app bar leaves its toggle
/// out meanwhile), the app mark, a greeting for the time of day and chips
/// for the other ways in (Camera: image translation, Document: document
/// translation). Below them:
///
/// * after the app comes back to the front with text on the clipboard,
///   "Paste and translate" ([TranslatePasteOffer]);
/// * "Continue" with the last translation of the on-device history
///   ([translateHeroContinueEntry]; one tap shows it again with
///   `TranslateCubit.restoreHistoryEntry`, nothing is sent);
/// * up to [translateHeroMaxPairs] recent language pairs other than the
///   current one (`AppSettings.recentPairs`; one tap applies a pair with
///   `TranslateCubit.applyLanguagePair`);
/// * on large screens, where the keyboard shortcuts are.
///
/// Everything comes from this device (settings and history): no requests.
///
/// The composer is docked below it (see `TranslateView`); the hero gives
/// way to the translation as soon as the input has focus or text.
class TranslateHero extends StatelessWidget {
  const new({this.showQualityChip = true, super.key});

  /// Whether the quality chip is offered here (else the screen keeps the
  /// toggle in the app bar, e.g. in a window too low for both).
  final bool showQualityChip;

  /// The clock of the greeting (tests pin it).
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = AppPalette.of(context).secondaryText;
    final state = context.watch<TranslateCubit>().state;
    final settings = context.watch<SettingsCubit>().state;
    final pairs = [
      for (final pair in settings.recentPairs)
        if (!isCurrentLanguagePair(pair, state)) pair,
    ].take(translateHeroMaxPairs).toList();
    final wide =
        MediaQuery.sizeOf(context).width >= TranslateLayout.wideBreakpoint;
    final router = GoRouter.maybeOf(context);
    final history = _historyOf(context);
    final last = translateHeroContinueEntry(
      settings: settings,
      history: history,
      state: state,
    );
    return Padding(
      key: const Key('translate_hero'),
      padding: const EdgeInsets.symmetric(
        horizontal: TranslateLayout.gutter,
        vertical: 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showQualityChip && state.hasQualityModes) ...[
            const QualityChip(),
            const SizedBox(height: translateHeroChipGap),
          ],
          // The app mark (as in the navigation rail); decorative.
          ExcludeSemantics(
            child: Icon(
              Icons.translate_rounded,
              size: 52,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 12),
          Semantics(
            header: true,
            child: Text(
              translateGreeting(l10n, clock()),
              key: const Key('translate_greeting'),
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineMedium?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
                height: 1.15,
              ),
            ),
          ),
          if (router != null) ...[
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                _HeroChip(
                  key: const Key('translate_hero_camera'),
                  icon: Icons.photo_camera_outlined,
                  label: l10n.translateHeroCamera,
                  onPressed: () => unawaited(
                    router.push<void>(ImageTranslatePage.locationFor()),
                  ),
                ),
                _HeroChip(
                  key: const Key('translate_hero_document'),
                  icon: Icons.description_outlined,
                  label: l10n.translateHeroDocument,
                  onPressed: () =>
                      unawaited(router.push<void>(AppRoutes.documents)),
                ),
              ],
            ),
          ],
          const TranslatePasteOffer(),
          if (last != null) ...[
            const SizedBox(height: 16),
            _ContinueButton(entry: last),
          ],
          if (pairs.isNotEmpty) ...[
            const SizedBox(height: 24),
            Semantics(
              container: true,
              explicitChildNodes: true,
              label: l10n.translateEmptyRecentPairs,
              child: Column(
                children: [
                  ExcludeSemantics(
                    child: Text(
                      l10n.translateEmptyRecentPairs,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelLarge?.copyWith(color: muted),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Outlined hairline pills (X topics).
                  TranslatePills(
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final (index, pair) in pairs.indexed)
                          ActionChip(
                            key: ValueKey('translate_empty_pair:$index'),
                            avatar: Icon(
                              Icons.history,
                              size: 18,
                              color: scheme.primary,
                            ),
                            label: Text(translatePairLabel(l10n, pair)),
                            onPressed:
                                (pair.source.isCustom ||
                                        pair.target.isCustom) &&
                                    !state.supportsCustomLanguages
                                ? null
                                : () => context
                                      .read<TranslateCubit>()
                                      .applyLanguagePair(pair),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (wide) ...[
            const SizedBox(height: 24),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.keyboard_outlined, size: 18, color: muted),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    l10n.translateEmptyShortcutsTip,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The history the empty screen continues from: the app-wide
/// [HistoryCubit]'s state, or null when none is provided.
HistoryState? _historyOf(BuildContext context) {
  try {
    return context.watch<HistoryCubit>().state;
  } on ProviderNotFoundException {
    return null;
  }
}

/// The entry "Continue" on the empty screen offers: the newest translation
/// of the on-device [history] while history is kept
/// (`AppSettings.saveHistory`, not incognito) and the engine of [state]
/// offers its languages (see `TranslateCubit.restoreHistoryEntry`); else
/// null. Dictionary look-ups are skipped.
HistoryEntry? translateHeroContinueEntry({
  required AppSettings settings,
  required HistoryState? history,
  required TranslateState state,
}) {
  if (history == null ||
      !settings.saveHistory ||
      settings.incognito ||
      history.paused ||
      state.engine == null) {
    return null;
  }
  final entry = history.entries
      .where((entry) => !entry.isDictionary && entry.text.trim().isNotEmpty)
      .firstOrNull;
  if (entry == null || state.usableTarget(entry.target) == null) return null;
  final source = entry.source;
  final sources = state.sourceLanguages;
  final usableSource = source.isAuto
      ? sources.isEmpty || sources.contains(Language.auto)
      : source.isCustom
      ? state.supportsCustomLanguages
      : LanguageMatcher.match(source, sources) != null;
  return usableSource ? entry : null;
}

/// The short codes of [entry]'s languages, "EN → FR" (the detected
/// language for an auto source).
String _shortPair(AppLocalizations l10n, HistoryEntry entry) {
  String code(Language language, [String? detected]) {
    if (language.isCustom) return language.name;
    final value = language.isAuto ? (detected ?? language.code) : language.code;
    return LanguageAvatar.initials(value);
  }

  return l10n.translateLanguagePair(
    bidiIsolate(code(entry.source, entry.detectedSource)),
    bidiIsolate(code(entry.target)),
  );
}

/// "Continue: (the text, on one line) EN → FR" for the last translation in
/// the history; a tap shows it again (`TranslateCubit.restoreHistoryEntry`).
class _ContinueButton extends StatelessWidget {
  const new({required this.entry});

  final HistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = AppPalette.of(context).secondaryText;
    final text = entry.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final source = entry.source.isAuto && entry.detectedSource != null
        ? LanguageCatalog.byCode(entry.detectedSource!) ?? entry.source
        : entry.source;
    final pair = translatePairLabel(
      l10n,
      LanguagePair(source: source, target: entry.target),
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: TranslateLayout.maxColumnWidth,
      ),
      child: Semantics(
        button: true,
        label: l10n.translateHeroContinueSemantics(text, pair),
        excludeSemantics: true,
        child: OutlinedButton(
          key: const Key('translate_hero_continue'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(48, 48),
            shape: const StadiumBorder(),
            side: BorderSide(color: theme.colorScheme.outline),
            padding: const EdgeInsetsDirectional.only(start: 16, end: 12),
          ),
          onPressed: () =>
              context.read<TranslateCubit>().restoreHistoryEntry(entry),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.history, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                l10n.translateHeroContinue,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _shortPair(l10n, entry),
                style: theme.textTheme.labelMedium?.copyWith(color: muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Paste and translate" on the empty screen after the app comes back to
/// the front with text on the clipboard (Android).
///
/// Privacy: when the app resumes it only asks whether the clipboard holds
/// text ([hasClipboardText], `Clipboard.hasStrings`: on Android that reads
/// the clip's description, not the clip, so the system's "pasted from your
/// clipboard" notice does not show). The clipboard is read only when the
/// chip is tapped ([readClipboardText]); the text is then put in like a
/// paste (`TranslateCubit.setInput`), so it is translated only when the
/// user's settings translate pasted text by themselves (instant
/// translation; the label says "Paste copied text" otherwise). Nothing is
/// asked on the web, where asking reads the clipboard (and may prompt).
///
/// A tap or the close button hides it; it goes with the empty screen as
/// soon as the input has text or focus.
class TranslatePasteOffer extends StatefulWidget {
  const new({super.key});

  /// Whether the clipboard holds text, without reading it (tests replace
  /// it).
  @visibleForTesting
  static Future<bool> Function() hasClipboardText = Clipboard.hasStrings;

  /// The clipboard's text (tests replace it).
  @visibleForTesting
  static Future<String?> Function() readClipboardText = _readClipboard;

  /// Whether this platform can ask [hasClipboardText] without reading the
  /// clipboard: Android (tests replace it).
  @visibleForTesting
  static bool Function() asksOnResume = _onAndroid;

  static Future<String?> _readClipboard() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;

  static bool _onAndroid() =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  State<TranslatePasteOffer> createState() => _TranslatePasteOfferState();
}

class _TranslatePasteOfferState extends State<TranslatePasteOffer> {
  AppLifecycleListener? _lifecycle;
  bool _offer = false;

  @override
  void initState() {
    super.initState();
    if (TranslatePasteOffer.asksOnResume()) {
      _lifecycle = AppLifecycleListener(onResume: () => unawaited(_check()));
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }

  /// Asks (without reading) whether the clipboard holds text.
  Future<void> _check() async {
    if (context.read<TranslateCubit>().state.input.isNotEmpty) return;
    bool has;
    try {
      has = await TranslatePasteOffer.hasClipboardText();
    } on Object {
      has = false;
    }
    if (mounted && has != _offer) setState(() => _offer = has);
  }

  Future<void> _paste() async {
    setState(() => _offer = false);
    final cubit = context.read<TranslateCubit>();
    String? text;
    try {
      text = await TranslatePasteOffer.readClipboardText();
    } on Object {
      text = null;
    }
    if (text == null || text.trim().isEmpty || cubit.isClosed) return;
    if (cubit.state.input.isNotEmpty) return;
    cubit.setInput(text, pasted: true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_offer) return const SizedBox.shrink();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final state = context.watch<TranslateCubit>().state;
    final settings = context.watch<SettingsCubit>().state;
    final engine = state.engine;
    final instant =
        engine != null &&
        (engine.isAi ? settings.instantTranslateAi : settings.instantTranslate);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: TranslatePills(
        child: InputChip(
          key: const Key('translate_paste_offer'),
          avatar: Icon(Icons.content_paste, size: 18, color: scheme.primary),
          label: Text(
            instant
                ? l10n.translateHeroPasteTranslate
                : l10n.translateHeroPaste,
          ),
          onPressed: () => unawaited(_paste()),
          onDeleted: () => setState(() => _offer = false),
          deleteButtonTooltipMessage: l10n.translateHeroPasteDismiss,
        ),
      ),
    );
  }
}

/// A tonal chip of [TranslateHero]: an icon and a short label.
class _HeroChip extends StatelessWidget {
  const new({
    required this.icon,
    required this.label,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FilledButton.tonalIcon(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: const StadiumBorder(),
        backgroundColor: scheme.secondaryContainer,
        foregroundColor: scheme.onSecondaryContainer,
        textStyle: Theme.of(context).textTheme.labelLarge
            ?.copyWith(fontWeight: FontWeight.w700),
      ),
      onPressed: onPressed,
      icon: Icon(icon, size: 20, color: scheme.primary),
      label: Text(label),
    );
  }
}
