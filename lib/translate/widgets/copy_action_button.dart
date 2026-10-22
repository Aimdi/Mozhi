import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/haptics.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/output_card.dart' show copyAndConfirm;
import 'package:mozhi/translate/widgets/status_announcer.dart';

/// A copy button that confirms in place: [text] is copied
/// ([copyAndConfirm] with an inline confirmation), the icon morphs into a
/// check mark for [confirmFor], and screen readers hear "Copied to
/// clipboard" once (a polite announcement, not a focus change) unless a
/// snack bar says it (Android 12 and older). The button keeps its name
/// ([tooltip], "Copy" by default) while it shows the check mark.
///
/// [quiet] draws it like the other actions under the translation (a grey
/// 20 dp icon); otherwise it takes the ambient [IconButton] style. An empty
/// [text] disables it. Copying ticks lightly (haptics).
class CopyActionButton extends StatefulWidget {
  const new({required this.text, this.tooltip, this.quiet = false, super.key});

  /// How long the check mark shows.
  static const confirmFor = Duration(seconds: 2);

  final String text;

  /// The button's name; "Copy" by default.
  final String? tooltip;

  /// The quiet look of the actions under the translation.
  final bool quiet;

  @override
  State<CopyActionButton> createState() => _CopyActionButtonState();
}

class _CopyActionButtonState extends State<CopyActionButton> {
  bool _copied = false;
  Timer? _reset;

  /// Copies so far whose confirmation is announced (each one again).
  int _announcements = 0;
  bool _announce = false;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    Haptics.light(context);
    final snackBar = await copyAndConfirm(
      context,
      widget.text,
      inlineConfirmation: true,
    );
    if (!mounted) return;
    _reset?.cancel();
    setState(() {
      _copied = true;
      _announce = !snackBar;
      if (_announce) _announcements++;
    });
    _reset = Timer(CopyActionButton.confirmFor, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = AppPalette.of(context);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final enabled = widget.text.trim().isNotEmpty;
    final icon = AnimatedSwitcher(
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 200),
      switchInCurve: Curves.easeOutBack,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(scale: animation, child: child),
      ),
      child: _copied
          ? Icon(
              Icons.check,
              key: const ValueKey('copied'),
              color: palette.success,
            )
          : const Icon(Icons.copy_outlined, key: ValueKey('copy')),
    );
    return StatusAnnouncer(
      message: _copied && _announce ? l10n.commonCopied : null,
      announcementId: _announcements,
      child: IconButton(
        tooltip: widget.tooltip ?? l10n.commonCopy,
        style: widget.quiet
            ? IconButton.styleFrom(
                iconSize: 20,
                foregroundColor: palette.secondaryText,
              )
            : null,
        icon: icon,
        onPressed: enabled ? () => unawaited(_copy()) : null,
      ),
    );
  }
}
