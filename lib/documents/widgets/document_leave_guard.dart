import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/documents/cubit/document_translate_cubit.dart';
import 'package:mozhi/documents/data/document_file_service.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Asks whether to stop the running translation: for leaving the screen
/// (the default), or for opening a file shared from another app
/// ([forSharedFile]). True when the user agreed.
Future<bool> confirmStopTranslating(
  BuildContext context, {
  bool forSharedFile = false,
}) async {
  final l10n = context.l10n;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const Key('documents_stop_dialog'),
      title: Text(
        forSharedFile
            ? l10n.documentsSharedReplaceTitle
            : l10n.documentsLeaveTitle,
      ),
      content: Text(l10n.documentsLeaveMessage),
      actions: [
        TextButton(
          key: const Key('documents_stop_cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: const Key('documents_stop_confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(
            forSharedFile
                ? l10n.documentsSharedReplaceConfirm
                : l10n.documentsLeaveConfirm,
          ),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// Keeps the screen open while a document is being translated: leaving
/// (Back, the app bar's back button) asks first ([confirmStopTranslating]),
/// and stops the translation when the user agrees. Closing the screen
/// otherwise would silently throw the work away.
class DocumentLeaveGuard extends StatelessWidget {
  const new({required this.child, super.key});

  final Widget child;

  Future<void> _confirm(BuildContext context) async {
    final cubit = context.read<DocumentTranslateCubit>();
    final navigator = Navigator.of(context);
    if (!await confirmStopTranslating(context)) return;
    cubit.cancel();
    // `pop` leaves whatever the guard says; the first screen of the app
    // leaves the app.
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      await SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final translating = context.select<DocumentTranslateCubit, bool>(
      (cubit) => cubit.state.isTranslating,
    );
    return PopScope<Object?>(
      canPop: !translating,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirm(context));
      },
      child: child,
    );
  }
}

/// Hands a file shared from another app to the open document screen: a
/// new share ([shareId], the share's token) loads [file], or shows why it
/// could not be opened ([unavailable]). While a document is being
/// translated it asks first ([confirmStopTranslating]); without the user's
/// yes the share is dropped. The share the screen opened with is loaded
/// by the page itself.
class DocumentShareHandoff extends StatefulWidget {
  const new({
    required this.shareId,
    required this.child,
    this.file,
    this.unavailable,
    super.key,
  });

  final String? shareId;
  final PickedFile? file;
  final ({String? name, bool tooLarge})? unavailable;
  final Widget child;

  @override
  State<DocumentShareHandoff> createState() => _DocumentShareHandoffState();
}

class _DocumentShareHandoffState extends State<DocumentShareHandoff> {
  @override
  void didUpdateWidget(DocumentShareHandoff oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shareId != null && widget.shareId != oldWidget.shareId) {
      final (file, unavailable) = (widget.file, widget.unavailable);
      // Not while building: it may ask first.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_receive(file, unavailable));
      });
    }
  }

  Future<void> _receive(
    PickedFile? file,
    ({String? name, bool tooLarge})? unavailable,
  ) async {
    final cubit = context.read<DocumentTranslateCubit>();
    if (cubit.state.isTranslating) {
      final stop = await confirmStopTranslating(context, forSharedFile: true);
      if (!stop || !mounted || cubit.isClosed) return;
      cubit.cancel();
    }
    openSharedDocument(cubit, file: file, unavailable: unavailable);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Loads a shared [file] into [cubit], or shows why it could not be opened
/// ([unavailable]; neither: it could not be read).
void openSharedDocument(
  DocumentTranslateCubit cubit, {
  PickedFile? file,
  ({String? name, bool tooLarge})? unavailable,
}) {
  if (file != null) {
    cubit.loadFile(file.name, file.bytes);
  } else {
    cubit.fileUnavailable(
      name: unavailable?.name,
      tooLarge: unavailable?.tooLarge ?? false,
    );
  }
}
