import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/shared_files.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Reads the shared file of [token] ([SharedFiles.take], [keep] as there)
/// and then builds [builder] with it and its token, or with null when there
/// is none (no [token]: right away). A small loading screen is shown
/// meanwhile. A new [token] is read the same way, while what the previous
/// one built stays on screen (the screen can then ask before the new file
/// replaces its work). [take] replaces [SharedFiles.take] (tests).
class SharedFileLoader extends StatefulWidget {
  const new({
    required this.token,
    required this.builder,
    this.keep = false,
    this.take = SharedFiles.take,
    super.key,
  });

  final String? token;
  final bool keep;
  final Widget Function(BuildContext context, SharedFile? file, String? token)
  builder;
  final Future<SharedFile?> Function(String? token, {bool keep}) take;

  @override
  State<SharedFileLoader> createState() => _SharedFileLoaderState();
}

class _SharedFileLoaderState extends State<SharedFileLoader> {
  var _loaded = false;
  SharedFile? _file;
  String? _token;

  /// Counts the reads: only the latest one is shown.
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(SharedFileLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.token != oldWidget.token) _start();
  }

  void _start() {
    final request = ++_request;
    final token = widget.token;
    if (token == null) {
      _loaded = true;
      _file = null;
      _token = null;
      return;
    }
    unawaited(_load(token, request));
  }

  Future<void> _load(String token, int request) async {
    SharedFile? file;
    try {
      file = await widget.take(token, keep: widget.keep);
    } on Object {
      file = null;
    }
    if (!mounted || request != _request) return;
    setState(() {
      _loaded = true;
      _file = file;
      _token = token;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loaded) return widget.builder(context, _file, _token);
    return Scaffold(
      appBar: AppBar(),
      body: Center(
        child: CircularProgressIndicator(
          semanticsLabel: context.l10n.appScreenLoading,
        ),
      ),
    );
  }
}

/// Shows "Only the first item is opened" once when [several] items were
/// shared at once (`SharedFiles.sharedSeveral`), and again for a new share
/// ([id]) of several items.
class SharedItemsNotice extends StatefulWidget {
  const new({
    required this.id,
    required this.several,
    required this.child,
    super.key,
  });

  final String? id;
  final bool several;
  final Widget child;

  @override
  State<SharedItemsNotice> createState() => _SharedItemsNoticeState();
}

class _SharedItemsNoticeState extends State<SharedItemsNotice> {
  @override
  void initState() {
    super.initState();
    _maybeShow();
  }

  @override
  void didUpdateWidget(SharedItemsNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.id != oldWidget.id) _maybeShow();
  }

  void _maybeShow() {
    if (!widget.several) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          key: const Key('shared_first_item_only'),
          content: Text(context.l10n.commonSharedFirstItemOnly),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
