import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/shared_files.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Reads the shared file of [token] ([SharedFiles.take], [keep] as there)
/// and then builds [builder] with it, or with null when there is none. A
/// small loading screen is shown meanwhile. [take] replaces
/// [SharedFiles.take] (tests).
class SharedFileLoader extends StatefulWidget {
  const new({
    required this.token,
    required this.builder,
    this.keep = false,
    this.take = SharedFiles.take,
    super.key,
  });

  final String token;
  final bool keep;
  final Widget Function(BuildContext context, SharedFile? file) builder;
  final Future<SharedFile?> Function(String? token, {bool keep}) take;

  @override
  State<SharedFileLoader> createState() => _SharedFileLoaderState();
}

class _SharedFileLoaderState extends State<SharedFileLoader> {
  var _loaded = false;
  SharedFile? _file;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    SharedFile? file;
    try {
      file = await widget.take(widget.token, keep: widget.keep);
    } on Object {
      file = null;
    }
    if (!mounted) return;
    setState(() {
      _loaded = true;
      _file = file;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loaded) return widget.builder(context, _file);
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
