import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';

/// The frame of the backup and restore dialogs: full screen on phones
/// (narrower than [fullScreenBelow]), with a close button and [title] in
/// the app bar and the [actions] at the bottom; a dialog of at most
/// [maxWidth] elsewhere. [body] scrolls.
class BackupDialogFrame extends StatelessWidget {
  const new({
    required this.title,
    required this.body,
    this.actions = const [],
    this.canClose = true,
    super.key,
  });

  /// Width below which the dialog fills the screen.
  static const fullScreenBelow = 600.0;

  /// Width of the dialog on wide screens.
  static const maxWidth = 560.0;

  final String title;
  final Widget body;
  final List<Widget> actions;

  /// Whether the close button (and Escape, Back) closes the dialog; false
  /// while something runs that must not be interrupted.
  final bool canClose;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final content = SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.sm,
        AppSpacing.xl,
        AppSpacing.lg,
      ),
      child: body,
    );
    final buttons = actions.isEmpty
        ? null
        : Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.lg,
              AppSpacing.lg,
            ),
            child: OverflowBar(
              alignment: MainAxisAlignment.end,
              overflowAlignment: OverflowBarAlignment.end,
              spacing: AppSpacing.sm,
              overflowSpacing: AppSpacing.sm,
              children: actions,
            ),
          );
    final close = canClose
        ? const CloseButton()
        : const IconButton(onPressed: null, icon: Icon(Icons.close));
    final Widget dialog;
    if (size.width < fullScreenBelow) {
      dialog = Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(leading: close, title: Text(title)),
          body: SafeArea(top: false, child: content),
          bottomNavigationBar: buttons == null
              ? null
              : SafeArea(top: false, child: buttons),
        ),
      );
    } else {
      final theme = Theme.of(context);
      dialog = Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: maxWidth,
            maxHeight: size.height * 0.9,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(
                  AppSpacing.xl,
                  AppSpacing.md,
                  AppSpacing.sm,
                  0,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(title, style: theme.textTheme.titleLarge),
                      ),
                    ),
                    close,
                  ],
                ),
              ),
              Flexible(child: content),
              ?buttons,
            ],
          ),
        ),
      );
    }
    return PopScope(canPop: canClose, child: dialog);
  }
}
