import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/cubit/document_translate_cubit.dart';
import 'package:mozhi/documents/data/document_file_service.dart';
import 'package:mozhi/documents/pdf/pdf_translator.dart';
import 'package:mozhi/documents/widgets/widgets.dart';
import 'package:mozhi/image_translate/view/image_translate_page.dart'
    show ocrPreferredLanguages;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/clipboard_service.dart'
    show systemShowsCopyConfirmation;
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

/// Document translation (DeepL/Kagi style): text formats, office
/// documents and e-books translated with their formatting, and PDFs read
/// and translated page by page on Android.
///
/// Needs a [TranslationRepository] and the app-wide [TranslateCubit]
/// above it; engine, languages and options start from the translate
/// screen. [initialFile]/[initialText] open a document right away;
/// [fileService] and [translator] can be replaced in tests.
///
/// Leaving while a document is being translated asks first
/// ([DocumentLeaveGuard]).
class DocumentTranslatePage extends StatelessWidget {
  const new({
    this.initialFile,
    this.initialText,
    this.shareId,
    this.unavailableFile,
    this.fileService,
    this.translator,
    this.pdfTranslator,
    super.key,
  });

  /// A file to open right away (e.g. one shared from another app).
  final PickedFile? initialFile;

  /// The share (its token) [initialFile] or [unavailableFile] comes from,
  /// for a file shared from another app: a new share replaces the open
  /// document (asking first while it is being translated,
  /// [DocumentShareHandoff]). A share without either could not be read.
  final String? shareId;

  /// A shared file that could not be opened: its name (when known) and
  /// whether it was too large (otherwise it could not be read). Shown as
  /// the document's error.
  final ({String? name, bool tooLarge})? unavailableFile;

  /// Text to open right away in text mode (e.g. long input handed over
  /// from the translate screen). Ignored when [initialFile] is given.
  final String? initialText;

  /// File picking, saving, sharing and clipboard access (defaults to the
  /// platform plugins).
  final DocumentFileService? fileService;
  final DocumentTranslator? translator;

  /// Reads, translates and writes PDFs (default: the platform's, created
  /// when a PDF is opened).
  final PdfTranslator? pdfTranslator;

  @override
  Widget build(BuildContext context) {
    // Read here: the create callback must not depend on inherited widgets.
    final locale = Localizations.maybeLocaleOf(context);
    return BlocProvider(
      create: (context) {
        final translate = context.read<TranslateCubit>().state;
        final settings = _settings(context);
        final cubit = DocumentTranslateCubit(
          repository: context.read<TranslationRepository>(),
          files: fileService ?? const PlatformDocumentFileService(),
          translator: translator,
          engines: translate.engines,
          engine: translate.engine,
          sourceLanguages: translate.sourceLanguages,
          targetLanguages: translate.targetLanguages,
          source: translate.source,
          target: translate.target,
          options: translate.options,
          usageTracker: _usageTracker(context),
          pdfTranslator: pdfTranslator,
          // A PDF in "Detect language" is read with these languages' text
          // recognition data first, as photos are.
          ocrPreferred: settings == null
              ? const []
              : ocrPreferredLanguages(settings, locale),
        );
        if (initialFile != null || unavailableFile != null || shareId != null) {
          openSharedDocument(
            cubit,
            file: initialFile,
            unavailable: unavailableFile,
          );
        } else if (initialText case final text? when text.isNotEmpty) {
          cubit.setText(text);
        }
        return cubit;
      },
      child: DocumentShareHandoff(
        shareId: shareId,
        file: initialFile,
        unavailable: unavailableFile,
        child: const DocumentTranslateView(),
      ),
    );
  }
}

class DocumentTranslateView extends StatelessWidget {
  const new({super.key});

  /// Width from which settings and preview are shown side by side.
  static const wideBreakpoint = 840.0;

  void _syncEngines(BuildContext context, TranslateState translate) {
    context.read<DocumentTranslateCubit>().syncEngines(
      engines: translate.engines,
      engine: translate.engine,
      sourceLanguages: translate.sourceLanguages,
      targetLanguages: translate.targetLanguages,
      source: translate.source,
      target: translate.target,
      options: translate.options,
    );
  }

  void _showNotice(BuildContext context, DocumentNotice notice) {
    // Android 13+ confirms copies itself.
    if (notice == DocumentNotice.copied && systemShowsCopyConfirmation) return;
    final l10n = context.l10n;
    final message = switch (notice) {
      DocumentNotice.saved => l10n.documentsSaved,
      DocumentNotice.saveFailed => l10n.documentsSaveFailed,
      DocumentNotice.shareFailed => l10n.documentsShareFailed,
      DocumentNotice.shareUnsupported => l10n.documentsShareUnsupported,
      DocumentNotice.copied => l10n.commonCopied,
      DocumentNotice.clipboardEmpty => l10n.documentsClipboardEmpty,
      DocumentNotice.languagesFailed => l10n.documentsLanguagesFailed,
    };
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), showCloseIcon: true));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final hasDocument = context.select<DocumentTranslateCubit, bool>(
      (cubit) => cubit.state.hasDocument || cubit.state.fileName != null,
    );
    final translating = context.select<DocumentTranslateCubit, bool>(
      (cubit) => cubit.state.isTranslating,
    );

    return MultiBlocListener(
      listeners: [
        BlocListener<TranslateCubit, TranslateState>(
          listenWhen: (previous, current) =>
              previous.engines != current.engines ||
              previous.engine != current.engine ||
              previous.sourceLanguages != current.sourceLanguages ||
              previous.targetLanguages != current.targetLanguages ||
              previous.source != current.source ||
              previous.target != current.target ||
              previous.options != current.options,
          listener: _syncEngines,
        ),
        BlocListener<DocumentTranslateCubit, DocumentTranslateState>(
          listenWhen: (previous, current) =>
              current.notice != null && previous.noticeId != current.noticeId,
          listener: (context, state) => _showNotice(context, state.notice!),
        ),
      ],
      // Translating a document is the user's own action: when the privacy
      // settings stop it, ask right away (the parts are retried after).
      child:
          ConsentDialogListener<DocumentTranslateCubit, DocumentTranslateState>(
            consentOf: (state) => state.isTranslating
                ? null
                : state.failures.values
                      .whereType<ConsentRequiredException>()
                      .firstOrNull,
            requestsOf: documentRequests,
            onGranted: (context) => unawaited(
              context.read<DocumentTranslateCubit>().consentGranted(),
            ),
            child: DocumentLeaveGuard(
              child: Scaffold(
                appBar: AppBar(
                  title: Text(l10n.documentsTitle),
                  actions: [
                    if (hasDocument)
                      IconButton(
                        key: const Key('documents_clear'),
                        tooltip: l10n.documentsRemove,
                        onPressed: translating
                            ? null
                            : context.read<DocumentTranslateCubit>().clear,
                        icon: const Icon(Icons.close),
                      ),
                  ],
                ),
                body: SafeArea(
                  top: false,
                  child: LayoutBuilder(
                    builder: (context, constraints) =>
                        constraints.maxWidth >= wideBreakpoint
                        ? const _WideLayout()
                        : const _NarrowLayout(),
                  ),
                ),
              ),
            ),
          ),
    );
  }
}

class _Controls extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    // Flat sections separated by hairlines instead of cards.
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        DocumentSourceCard(),
        Hairline(),
        DocumentSettingsCard(),
        DocumentProgressSection(),
        DocumentFailuresCard(),
        DocumentActions(),
      ],
    );
  }
}

class _NarrowLayout extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 16,
            children: [_Controls(), DocumentPreviewTabs()],
          ),
        ),
      ),
    );
  }
}

class _WideLayout extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    return const Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 420,
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(24, 16, 12, 24),
            child: _Controls(),
          ),
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(12, 16, 24, 24),
            child: DocumentSideBySide(),
          ),
        ),
      ],
    );
  }
}

/// The app settings, or null when none are provided (e.g. in tests).
AppSettings? _settings(BuildContext context) {
  try {
    return context.read<SettingsCubit>().state;
  } on ProviderNotFoundException {
    return null;
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
