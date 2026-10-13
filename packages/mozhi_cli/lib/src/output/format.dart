/// `850 ms`, `2.4 s`.
String formatDuration(Duration duration) {
  final ms = duration.inMilliseconds;
  return ms < 1000 ? '$ms ms' : '${(ms / 1000).toStringAsFixed(1)} s';
}
