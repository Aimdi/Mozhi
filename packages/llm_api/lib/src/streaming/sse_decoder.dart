import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

/// One server-sent event.
@immutable
class SseEvent {
  const SseEvent(this.data, {this.event});

  /// The `data:` lines of the event joined with `\n`.
  final String data;

  /// The `event:` field, or null when the event had none (which the SSE
  /// spec treats as type `message`).
  final String? event;

  @override
  bool operator ==(Object other) =>
      other is SseEvent && other.data == data && other.event == event;

  @override
  int get hashCode => Object.hash(data, event);

  @override
  String toString() => 'SseEvent(${event ?? 'message'}: $data)';
}

/// Decodes a `text/event-stream` body into [SseEvent]s.
///
/// The input is decoded text in chunks of any size: lines (and even `\r\n`
/// pairs) may be split across chunks. Follows the WHATWG parsing rules:
/// `\n`, `\r\n` and `\r` end lines, a blank line dispatches the event,
/// lines starting with `:` are comments, the single space after `field:` is
/// optional, and `id` / `retry` / unknown fields are ignored. Unlike a
/// browser, an event that is still pending when the stream ends is
/// dispatched, because some servers close the connection without the final
/// blank line.
class SseDecoder extends StreamTransformerBase<String, SseEvent> {
  const SseDecoder();

  @override
  Stream<SseEvent> bind(Stream<String> stream) =>
      Stream<SseEvent>.eventTransformed(
        stream.transform(const LineSplitter()),
        _SseSink.new,
      );
}

class _SseSink implements EventSink<String> {
  _SseSink(this._output);

  final EventSink<SseEvent> _output;
  final StringBuffer _data = StringBuffer();
  bool _hasData = false;
  String? _event;
  bool _isFirstLine = true;

  @override
  void add(String line) {
    var text = line;
    if (_isFirstLine) {
      _isFirstLine = false;
      // A byte order mark at the start of the stream is not content.
      if (text.startsWith('﻿')) text = text.substring(1);
    }
    if (text.isEmpty) {
      _dispatch();
      return;
    }
    if (text.startsWith(':')) return;

    final colon = text.indexOf(':');
    final field = colon < 0 ? text : text.substring(0, colon);
    var value = colon < 0 ? '' : text.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'data':
        if (_hasData) _data.write('\n');
        _data.write(value);
        _hasData = true;
      case 'event':
        _event = value;
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _output.addError(error, stackTrace);

  @override
  void close() {
    _dispatch();
    _output.close();
  }

  void _dispatch() {
    if (_hasData) {
      final event = _event;
      _output.add(
        SseEvent(
          _data.toString(),
          event: event == null || event.isEmpty ? null : event,
        ),
      );
    }
    _data.clear();
    _hasData = false;
    _event = null;
  }
}
