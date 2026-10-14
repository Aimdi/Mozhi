import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/engine_selector.dart';
import 'package:mozhi/translate/widgets/language_bar.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:mozhi/web_translate/core/readable_extractor.dart';
import 'package:mozhi/web_translate/cubit/web_translate_cubit.dart';
import 'package:mozhi/web_translate/data/page_extraction.dart';
import 'package:mozhi/web_translate/data/web_page_fetcher.dart';
import 'package:mozhi/web_translate/widgets/web_reader.dart';
import 'package:mozhi/web_translate/widgets/web_translate_status.dart';
import 'package:mozhi/web_translate/widgets/web_url_field.dart';
import 'package:translation_repository/translation_repository.dart';

/// The engine and languages currently selected in the text translator, or
/// null while no engine is available.
WebTranslateSelection? webTranslateSelectionOf(TranslateState state) {
  final engine = state.engine;
  if (engine == null) return null;
  return WebTranslateSelection(
    engine: engine,
    source: state.source,
    target: state.target,
    options: state.options,
  );
}

// coverage:ignore-start
Future<ReadablePage> _extractInBackground(FetchedWebPage page) =>
    compute(extractFetchedPage, page);
// coverage:ignore-end

/// Kagi-style web page translation: enter a URL, read the page's main text
/// translated with the engine and languages of the text translator
/// ([TranslateCubit]), as translation, original or side by side.
///
/// Needs [TranslationRepository] and [TranslateCubit] above it; a
/// [UsageTracker] above it (optional) counts AI requests.
class WebTranslatePage extends StatelessWidget {
  const new({
    this.initialUrl,
    this.autoLoad = true,
    this.fetcher,
    this.extract,
    this.isWeb = kIsWeb,
    super.key,
  });

  /// Address to load (and translate) right away, or with [autoLoad] off
  /// only to put in the address field.
  final String? initialUrl;

  /// Whether a non-empty [initialUrl] is loaded right away (otherwise only
  /// when the user presses Translate).
  final bool autoLoad;

  /// Downloads pages; a default [WebPageFetcher] when null.
  final WebPageFetcher? fetcher;

  /// Extracts readable blocks; runs in a background isolate when null.
  final ReadablePageExtractor? extract;

  /// Shows the cross-origin (CORS) notice of browser builds.
  final bool isWeb;

  @override
  Widget build(BuildContext context) {
    final url = initialUrl?.trim() ?? '';
    return BlocProvider(
      create: (context) => WebTranslateCubit(
        repository: context.read<TranslationRepository>(),
        fetcher: fetcher ?? WebPageFetcher(),
        extract: extract ?? _extractInBackground,
        initialUrl: url,
        usageTracker: _usageTracker(context),
      ),
      child: WebTranslateView(
        autoLoad: autoLoad && url.isNotEmpty,
        isWeb: isWeb,
      ),
    );
  }
}

/// The app's usage tracker, or null when none is provided (e.g. in tests).
UsageTracker? _usageTracker(BuildContext context) {
  try {
    return context.read<UsageTracker>();
  } on ProviderNotFoundException {
    return null;
  }
}

class WebTranslateView extends StatefulWidget {
  const new({this.autoLoad = false, this.isWeb = false, super.key});

  /// Loads the cubit's address after the first frame.
  final bool autoLoad;

  /// Shows the cross-origin (CORS) notice.
  final bool isWeb;

  /// From this width the side-by-side reader is available.
  static const wideBreakpoint = 840.0;

  @override
  State<WebTranslateView> createState() => _WebTranslateViewState();
}

class _WebTranslateViewState extends State<WebTranslateView> {
  late final TextEditingController _url;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(
      text: context.read<WebTranslateCubit>().state.url,
    );
    if (widget.autoLoad) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  void _load() {
    FocusManager.instance.primaryFocus?.unfocus();
    final selection = webTranslateSelectionOf(
      context.read<TranslateCubit>().state,
    );
    unawaited(context.read<WebTranslateCubit>().load(selection: selection));
  }

  void _syncField(BuildContext context, WebTranslateState state) {
    if (_url.text == state.url) return;
    _url.value = TextEditingValue(
      text: state.url,
      selection: TextSelection.collapsed(offset: state.url.length),
    );
  }

  /// Re-translates the page when the engine, languages or options change.
  void _selectionChanged(BuildContext context, TranslateState translate) {
    final selection = webTranslateSelectionOf(translate);
    final cubit = context.read<WebTranslateCubit>();
    final state = cubit.state;
    if (selection == null ||
        !state.hasPage ||
        state.status == WebTranslateStatus.loading) {
      return;
    }
    if (selection == state.selection &&
        state.status != WebTranslateStatus.loaded) {
      return;
    }
    unawaited(cubit.translate(selection));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return MultiBlocListener(
      listeners: [
        BlocListener<WebTranslateCubit, WebTranslateState>(
          listenWhen: (previous, current) => previous.url != current.url,
          listener: _syncField,
        ),
        BlocListener<TranslateCubit, TranslateState>(
          listenWhen: (previous, current) =>
              webTranslateSelectionOf(previous) !=
              webTranslateSelectionOf(current),
          listener: _selectionChanged,
        ),
      ],
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.webTranslateTitle),
          actions: const [WebTranslateActions(), SizedBox(width: 4)],
        ),
        body: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide =
                  constraints.maxWidth >= WebTranslateView.wideBreakpoint;
              final maxWidth = wide ? 1280.0 : 760.0;
              final gutter = math
                  .max(16, (constraints.maxWidth - maxWidth) / 2)
                  .toDouble();
              return SelectionArea(
                child: CustomScrollView(
                  key: const Key('web_translate_scroll_view'),
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 0),
                      sliver: SliverToBoxAdapter(
                        child: _Controls(
                          controller: _url,
                          isWeb: widget.isWeb,
                          onLoad: _load,
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 32),
                      sliver: _Body(wide: wide),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const new({
    required this.controller,
    required this.isWeb,
    required this.onLoad,
  });

  final TextEditingController controller;
  final bool isWeb;
  final VoidCallback onLoad;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<WebTranslateCubit>();
    final urlInvalid = context.select<WebTranslateCubit, bool>(
      (cubit) => cubit.state.urlInvalid,
    );
    final loading = context.select<WebTranslateCubit, bool>(
      (cubit) => cubit.state.status == WebTranslateStatus.loading,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isWeb) ...[
          const WebTranslateWebNotice(),
          const SizedBox(height: 16),
        ],
        WebUrlField(
          controller: controller,
          invalid: urlInvalid,
          onChanged: cubit.setUrl,
          onSubmitted: onLoad,
        ),
        const SizedBox(height: 12),
        const LanguageBar(),
        const SizedBox(height: 8),
        Row(
          children: [
            const Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: EngineSelectorButton(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              key: const Key('web_translate_go_button'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: loading ? null : onLoad,
              icon: const Icon(Icons.translate),
              label: Text(l10n.webTranslateGo),
            ),
          ],
        ),
        const SizedBox(height: 16),
        WebTranslateStatusPanel(onRetryLoad: onLoad),
      ],
    );
  }
}

class _Body extends StatelessWidget {
  const new({required this.wide});

  final bool wide;

  @override
  Widget build(BuildContext context) {
    final hasPage = context.select<WebTranslateCubit, bool>(
      (cubit) => cubit.state.hasPage,
    );
    if (hasPage) return WebReaderSliver(wide: wide);
    final idle = context.select<WebTranslateCubit, bool>(
      (cubit) =>
          cubit.state.status == WebTranslateStatus.idle &&
          cubit.state.error == null,
    );
    return SliverToBoxAdapter(
      child: idle ? const WebTranslateEmptyState() : const SizedBox.shrink(),
    );
  }
}
