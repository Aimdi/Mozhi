import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';

/// A deferred library (`import '…' deferred as x;`) loaded at most once.
///
/// On the web each deferred library is a separate `main.dart.js_N.part.js`
/// that is only downloaded when the screen is first opened, which keeps it
/// out of the startup bundle. Elsewhere loading completes right away.
final class DeferredLibrary {
  /// [load] calls the libraries' `loadLibrary()`.
  new(this._load);

  final Future<void> Function() _load;
  Future<void>? _loading;
  bool _isLoaded = false;

  /// Whether [load] has completed: the library can be used synchronously.
  bool get isLoaded => _isLoaded;

  /// Loads the library; a failed load can be retried.
  Future<void> load() => _loading ??= _load().then(
    (_) => _isLoaded = true,
    onError: (Object error, StackTrace stackTrace) {
      _loading = null;
      Error.throwWithStackTrace(error, stackTrace);
    },
  );
}

/// Builds [builder] once [library] is loaded, with a small loading screen
/// until then (and a retry if the download fails).
class DeferredPage extends StatefulWidget {
  const new({required this.library, required this.builder, super.key});

  final DeferredLibrary library;

  /// Builds the page; may use the deferred library.
  final WidgetBuilder builder;

  @override
  State<DeferredPage> createState() => _DeferredPageState();
}

class _DeferredPageState extends State<DeferredPage> {
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (!widget.library.isLoaded) _load();
  }

  void _load() {
    if (_failed) setState(() => _failed = false);
    unawaited(
      widget.library.load().then<void>(
        (_) {
          if (mounted) setState(() {});
        },
        onError: (Object _) {
          if (mounted) setState(() => _failed = true);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.library.isLoaded) return widget.builder(context);
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(),
      body: Center(
        child: _failed
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.cloud_off_outlined,
                      size: 48,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    const SizedBox(height: 16),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        l10n.appScreenLoadFailed,
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.tonal(
                      onPressed: _load,
                      child: Text(l10n.commonRetry),
                    ),
                  ],
                ),
              )
            : CircularProgressIndicator(semanticsLabel: l10n.appScreenLoading),
      ),
    );
  }
}
