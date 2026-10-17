import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/data/bergamot_model_details.dart'
    show offlineModelDetailsOf;
import 'package:mozhi/settings/view/widgets/delete_local_data.dart'
    show formatStoredSize;
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// The device's offline engine when one is provided above [context] (the
/// app provides Bergamot, or an unavailable one on the web), else null.
OfflineTranslator? maybeOfflineTranslator(BuildContext context) {
  try {
    return context.read<OfflineTranslator>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// The key [code] is compared with the offline engine's codes by: its
/// primary subtag after [LanguageMatcher.normalize] (`zh-CN` and `zh`,
/// `nb` and `no` are the same language there).
String offlineLanguageKey(String code) =>
    LanguageMatcher.normalize(code).split('-').first.toLowerCase();

/// English, the pivot every offline model translates to or from.
const _english = 'en';

/// The keys ([offlineLanguageKey]) of the languages [translator] can
/// translate on this device now: those whose models are downloaded.
/// English only counts once another language is (it is the pivot, never a
/// download of its own). Empty when the engine is unavailable or fails.
Future<Set<String>> offlineReadyLanguages(OfflineTranslator translator) async {
  if (!translator.isAvailable) return const {};
  final Set<String> downloaded;
  try {
    downloaded = await translator.downloadedLanguages();
  } on Object {
    return const {};
  }
  final keys = {for (final code in downloaded) offlineLanguageKey(code)};
  if (keys.every((key) => key == _english)) return const {};
  return keys;
}

/// A language to download for translating on this device.
typedef OfflineDownload = ({String code, String name, int? bytes});

/// What [translator] needs to translate [source] → [target] on the device:
/// null when it does not support one of them (or is unavailable); else
/// the languages of the pair (but English) whose models are not in
/// [ready] ([offlineReadyLanguages]), each with its download size when
/// the engine knows it. An empty list: the pair works offline already.
/// A source of `auto` (or null) only needs the target.
List<OfflineDownload>? offlineDownloadsFor(
  OfflineTranslator translator, {
  required String? source,
  required String target,
  required Set<String> ready,
}) {
  if (!translator.isAvailable || target == Language.auto.code) return null;
  final supported = <String, String>{
    for (final code in translator.supportedLanguages)
      offlineLanguageKey(code): code,
  };
  final keys = [
    if (source != null && source != Language.auto.code)
      offlineLanguageKey(source),
    offlineLanguageKey(target),
  ];
  if (!keys.every(supported.containsKey)) return null;
  final details = offlineModelDetailsOf(translator);
  return [
    for (final key in {...keys})
      if (key != _english && !ready.contains(key))
        (
          code: supported[key]!,
          name: LanguageCatalog.nameOf(supported[key]!),
          bytes: details?.downloadSize(supported[key]!),
        ),
  ];
}

/// The label of a button that downloads [downloads]: "Download German
/// (25 MB)", "Download German, Japanese (52 MB)", or without the size when
/// it is unknown.
String offlineDownloadLabel(
  AppLocalizations l10n,
  List<OfflineDownload> downloads,
) {
  final names = [for (final download in downloads) download.name].join(', ');
  final sizes = [for (final download in downloads) download.bytes];
  if (sizes.isEmpty || sizes.any((size) => size == null || size <= 0)) {
    return l10n.translateOfflineDownloadLanguage(names);
  }
  final total = sizes.fold<int>(0, (sum, size) => sum + size!);
  return l10n.translateOfflineDownload(names, formatStoredSize(l10n, total));
}

/// Opens the offline languages (Settings › Offline), where the models are
/// downloaded; back returns here.
void openOfflineModels(BuildContext context) =>
    unawaited(GoRouter.of(context).push<void>(AppRoutes.offline));

/// Next to a request the privacy settings stopped before it left the
/// device ([consent]): the way to translate on the device instead, when
/// the offline engine supports the language pair. "Download German
/// (25 MB)" opens the offline languages while a model is missing; once
/// they are all there, "Translate on this device" switches to the
/// on-device engine. Shows nothing otherwise (no offline engine, e.g. on
/// the web, or a pair it does not support).
class OfflinePairOffer extends StatefulWidget {
  const new({required this.consent, this.translator, super.key});

  final ConsentRequiredException consent;

  /// The offline engine; defaults to the one provided above.
  final OfflineTranslator? translator;

  @override
  State<OfflinePairOffer> createState() => _OfflinePairOfferState();
}

class _OfflinePairOfferState extends State<OfflinePairOffer> {
  OfflineTranslator? _translator;
  List<OfflineDownload>? _downloads;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_translator != null) return;
    _translator = widget.translator ?? maybeOfflineTranslator(context);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(OfflinePairOffer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.consent.source != widget.consent.source ||
        oldWidget.consent.target != widget.consent.target) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final translator = _translator;
    final target = widget.consent.target;
    if (translator == null || !translator.isAvailable || target == null) {
      return;
    }
    final ready = await offlineReadyLanguages(translator);
    if (!mounted) return;
    setState(() {
      _downloads = offlineDownloadsFor(
        translator,
        source: widget.consent.source,
        target: target,
        ready: ready,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final downloads = _downloads;
    if (downloads == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    final cubit = context.read<TranslateCubit>();
    final Widget button;
    if (downloads.isEmpty) {
      final offline = cubit.state.engines.where((e) => e.isOffline).firstOrNull;
      if (offline == null) return const SizedBox.shrink();
      button = TextButton.icon(
        key: const Key('translate_offline_use'),
        onPressed: () => unawaited(cubit.selectEngine(offline)),
        icon: const Icon(Icons.offline_bolt_outlined),
        label: Text(l10n.translateUseOffline),
      );
    } else {
      button = TextButton.icon(
        key: const Key('translate_offline_download'),
        onPressed: () => openOfflineModels(context),
        icon: const Icon(Icons.download_for_offline_outlined),
        label: Text(offlineDownloadLabel(l10n, downloads)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Align(alignment: AlignmentDirectional.centerStart, child: button),
    );
  }
}
