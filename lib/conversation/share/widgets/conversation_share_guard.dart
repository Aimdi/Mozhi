import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/share/cubit/conversation_share_cubit.dart';

/// The [ConversationShareCubit] above [context], or null when the
/// conversation cannot be shared here (the web app, tests).
ConversationShareCubit? maybeConversationShare(BuildContext context) {
  try {
    return context.read<ConversationShareCubit>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// Tells the [ConversationShareCubit] above (if any) whether [child], a
/// screen of the conversation, is shown (its tickers run: not covered by
/// another page, not in another tab), and when the app goes to the
/// background and comes back, so sharing stops when the host leaves the
/// conversation or locks the phone for long.
class ConversationShareGuard extends StatefulWidget {
  const new({required this.child, super.key});

  final Widget child;

  @override
  State<ConversationShareGuard> createState() => _ConversationShareGuardState();
}

class _ConversationShareGuardState extends State<ConversationShareGuard> {
  ConversationShareCubit? _cubit;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: () => _cubit?.appHidden(),
      onShow: () => _cubit?.appShown(),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The conversation's cubit, which outlives its screens.
    final cubit = _cubit ??= maybeConversationShare(context);
    if (cubit != null && !cubit.isClosed) {
      cubit.setVisible(this, visible: TickerMode.valuesOf(context).enabled);
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    final cubit = _cubit;
    // Moving between the conversation and the sharing page is covered by
    // the cubit's leave grace.
    if (cubit != null && !cubit.isClosed) {
      cubit.setVisible(this, visible: false);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
