import '../core/style.dart';

/// Progress for a long step, in whichever of two shapes the sink can read.
///
/// A terminal gets one line repainted with `\r`: a 225MB download is thousands
/// of chunks, and a scrollback full of percentages is worse than no progress at
/// all. Anything else — a redirected file, a CI log — gets discrete
/// newline-terminated lines every [_stepPercent]%, because a carriage return
/// there does not repaint anything: it concatenates all 101 states into a
/// single unreadable ~20KB line.
///
/// Shared by the download and the extraction rather than written twice. Both
/// are long steps in one command, so a second implementation would be a second
/// STYLE — and the redraw-storm guard above is the part that must not be
/// reimplemented slightly differently.
class ProgressBar {
  ProgressBar({
    required this.sink,
    required this.label,
    required this.total,
    required this.isTerminal,
    Styles? styles,
  }) : styles = styles ?? Styles();

  final StringSink sink;
  final String label;
  final int? total;
  final bool isTerminal;

  /// Percentages and megabyte counts are supporting detail: they say a long
  /// step is moving, and they are not what the reader scrolls back for. Dimmed
  /// so the `Installed Flutter 3.13.2 to …` above and below them carries the eye.
  final Styles styles;

  /// How far the work has to move before a non-terminal sink is told again.
  /// Eleven lines describe a download; a thousand bury the log.
  static const int _stepPercent = 10;

  int _lastPercent = -1;

  void update(int received) {
    if (total == null || total == 0) return;
    final percent = _percentOf(received);

    if (isTerminal) {
      if (percent == _lastPercent) return;
      _lastPercent = percent;
      // The carriage return stays OUTSIDE the styled span: it is a cursor
      // movement, not part of the text being painted.
      sink.write('\r${styles.detail(_line(received, percent))}');
      return;
    }

    // The first update always prints, so a log says the step started even if
    // it is then interrupted.
    if (_lastPercent >= 0 && percent - _lastPercent < _stepPercent) return;
    _lastPercent = percent;
    sink.writeln(styles.detail(_line(received, percent)));
  }

  void finish(int received) {
    if (total == null || total == 0) {
      sink.writeln(styles.detail('  $label  ${_mb(received)} MB'));
      return;
    }

    if (isTerminal) {
      update(received);
      // Ends the line the repaints have been rewriting, so whatever prints
      // next starts on its own.
      sink.writeln();
      return;
    }

    // The throttle must not be what decides whether the log records that the
    // step completed, so the last line is written regardless of step.
    final percent = _percentOf(received);
    if (percent == _lastPercent) return;
    _lastPercent = percent;
    sink.writeln(styles.detail(_line(received, percent)));
  }

  int _percentOf(int received) => (received * 100 ~/ total!).clamp(0, 100);

  String _line(int received, int percent) =>
      '  $label  $percent%  (${_mb(received)} / ${_mb(total!)} MB)';

  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);
}
