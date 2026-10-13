import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:material_ui/material_ui.dart';

/// Tells screen-reader users about a status change (a finished translation,
/// loaded alternatives, ...) once, without moving their focus.
///
/// Whenever [message] changes to a non-null value it is announced:
/// * with `SemanticsService.sendAnnouncement` where the platform supports
///   announcements (iOS, web, desktop);
/// * otherwise (Android, where announcement events are deprecated) through a
///   one-pixel live region laid over [child] whose label is the message.
///
/// A null [message] (e.g. while a translation is still streaming) announces
/// nothing, so streamed tokens are never read out one by one. The first
/// build announces only when [announceInitial] is true.
class StatusAnnouncer extends StatefulWidget {
  const new({
    required this.message,
    required this.child,
    this.textDirection,
    this.announceInitial = false,
    super.key,
  });

  /// What to say; null for "nothing new".
  final String? message;

  /// Direction of [message] (defaults to the ambient direction).
  final TextDirection? textDirection;

  /// Announce a non-null [message] on the first build too.
  final bool announceInitial;

  final Widget child;

  @override
  State<StatusAnnouncer> createState() => _StatusAnnouncerState();
}

class _StatusAnnouncerState extends State<StatusAnnouncer> {
  /// Message exposed through the live region (fallback mode only).
  String? _live;
  bool _pendingInitial = false;

  @override
  void initState() {
    super.initState();
    _pendingInitial = widget.announceInitial && _hasMessage(widget.message);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_pendingInitial) {
      _pendingInitial = false;
      _announce(widget.message!);
    }
  }

  @override
  void didUpdateWidget(StatusAnnouncer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final message = widget.message;
    if (_hasMessage(message) && message != oldWidget.message) {
      _announce(message!);
    } else if (!_hasMessage(message)) {
      _live = null;
    }
  }

  static bool _hasMessage(String? message) =>
      message != null && message.trim().isNotEmpty;

  void _announce(String message) {
    final direction = widget.textDirection ?? Directionality.of(context);
    if (MediaQuery.supportsAnnounceOf(context)) {
      _live = null;
      unawaited(
        SemanticsService.sendAnnouncement(View.of(context), message, direction),
      );
    } else {
      _live = message;
    }
  }

  @override
  Widget build(BuildContext context) {
    final live = _live;
    if (live == null) {
      return Stack(children: [widget.child]);
    }
    return Stack(
      children: [
        widget.child,
        PositionedDirectional(
          start: 0,
          top: 0,
          width: 1,
          height: 1,
          child: Semantics(
            key: const Key('status_announcer_live_region'),
            container: true,
            liveRegion: true,
            label: live,
            textDirection: widget.textDirection,
            child: const SizedBox.expand(),
          ),
        ),
      ],
    );
  }
}
