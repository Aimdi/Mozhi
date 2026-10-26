import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';

/// The lock screen of the main window: the app's name, "Mozhi is locked"
/// and an Unlock button, on a plain surface (nothing of the app behind
/// it). [failed] says the last attempt did not unlock, as a live region.
class AppLockScreen extends StatelessWidget {
  const new({
    required this.onUnlock,
    this.prompting = false,
    this.failed = false,
    super.key,
  });

  /// Opens the system prompt.
  final VoidCallback onUnlock;

  /// Whether the system prompt is showing (the button waits).
  final bool prompting;

  /// Whether the last prompt ended without unlocking.
  final bool failed;

  /// The Unlock button.
  static const unlockKey = Key('app_lock_unlock');

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      key: const Key('app_lock_screen'),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ExcludeSemantics(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.primaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Icon(
                          Icons.lock_outline,
                          size: 40,
                          color: colors.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.appTitle,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Semantics(
                    header: true,
                    child: Text(
                      l10n.appLockLockedTitle,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.appLockLockedBody,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _UnlockButton(prompting: prompting, onUnlock: onUnlock),
                  _FailedNotice(failed: failed),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The lock prompt of the translucent windows (text selected in another
/// app): a card at the bottom above the other app, which stays visible
/// around it, with Close (closes the window) and Unlock.
class AppLockCompactScreen extends StatelessWidget {
  const new({
    required this.onUnlock,
    required this.onClose,
    this.prompting = false,
    this.failed = false,
    super.key,
  });

  final VoidCallback onUnlock;

  /// Closes the window.
  final VoidCallback onClose;
  final bool prompting;
  final bool failed;

  /// The Close button.
  static const closeKey = Key('app_lock_close');

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      key: const Key('app_lock_compact_screen'),
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Tapping the other app around the card closes the window, like
          // the quick translate sheet.
          Positioned.fill(
            child: Semantics(
              button: true,
              label: l10n.commonClose,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onClose,
                child: ColoredBox(color: colors.scrim.withValues(alpha: 0.32)),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Card(
                    margin: EdgeInsets.zero,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              ExcludeSemantics(
                                child: Icon(
                                  Icons.lock_outline,
                                  color: colors.primary,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Semantics(
                                  header: true,
                                  child: Text(
                                    l10n.appLockLockedTitle,
                                    style: theme.textTheme.titleLarge,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            l10n.appLockQuickBody,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          _FailedNotice(failed: failed),
                          const SizedBox(height: 16),
                          Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              TextButton(
                                key: closeKey,
                                onPressed: onClose,
                                child: Text(l10n.commonClose),
                              ),
                              _UnlockButton(
                                prompting: prompting,
                                onUnlock: onUnlock,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UnlockButton extends StatelessWidget {
  const new({required this.prompting, required this.onUnlock});

  final bool prompting;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      key: AppLockScreen.unlockKey,
      style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
      // Waits while the system prompt shows.
      onPressed: prompting ? null : onUnlock,
      icon: const Icon(Icons.fingerprint),
      label: Text(context.l10n.appLockUnlock),
    );
  }
}

/// "Not unlocked" after a cancelled or failed prompt, announced by screen
/// readers.
class _FailedNotice extends StatelessWidget {
  const new({required this.failed});

  final bool failed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: failed
          ? Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                context.l10n.appLockNotUnlocked,
                key: const Key('app_lock_failed'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}
