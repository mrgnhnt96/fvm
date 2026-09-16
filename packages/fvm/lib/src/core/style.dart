/// When fvm is allowed to put ANSI escape sequences in its output.
///
/// The `--color` flag, spelled the way `ls`, `grep` and `git` spell it, so
/// nobody has to look it up.
enum ColorMode {
  /// Colour when the output is a terminal that has not asked to be left alone.
  auto,

  /// Colour whatever the output is. This is what somebody piping into
  /// `less -R` is asking for, and it is allowed to override `NO_COLOR`.
  always,

  /// Never colour.
  never;

  /// The flag's name, so the parser and the reader agree in one place.
  static const String flag = 'color';

  /// The accepted values, in the order `--help` should list them.
  static List<String> get tokens => [for (final mode in values) mode.name];
}

/// The one place that decides what fvm's output LOOKS like.
///
/// A helper per semantic ROLE rather than per colour. `ok` being green is a
/// decision this file gets to change later; if commands reached for
/// `green(...)` directly, the palette would live in twenty files and `ok` would
/// end up green in one command and bold-green in the next.
///
/// Mutable in exactly one respect, and for the same reason `VerboseLog` is: the
/// `--color` flag is owned by the command runner's parser, which does not exist
/// yet when the composition root builds this. So the environment answer is
/// baked in at construction and [setMode] applies the flag afterwards.
///
/// Nothing here imports `dart:io`. Whether the sink is a terminal is a fact
/// only `lib/fvm.dart` can answer, and it is passed in.
class Styles {
  /// Builds the styling policy for a run.
  ///
  /// The defaults are the safe ones: an empty environment and a sink that is
  /// not a terminal produce no colour at all, which is what a test with an
  /// injected sink gets without saying anything.
  Styles({
    Map<String, String> environment = const {},
    bool outIsTerminal = false,
  })  : _environment = environment,
        _outIsTerminal = outIsTerminal;

  final Map<String, String> _environment;
  final bool _outIsTerminal;

  ColorMode _mode = ColorMode.auto;

  /// Applies `--color`, once the parser that owns the flag has run.
  void setMode(ColorMode mode) => _mode = mode;

  /// Whether escape sequences may be written right now.
  ///
  /// PRECEDENCE, and it is deliberate rather than incidental:
  ///
  ///  1. `--color=always` beats everything, including `NO_COLOR` and
  ///     `TERM=dumb`. The user asked for colour in THIS run, on this command
  ///     line, and is entitled to be obeyed — that is the whole point of a flag
  ///     that overrides an ambient setting, and it is how somebody gets colour
  ///     through a pipe into `less -R`.
  ///  2. `--color=never` likewise beats everything the other way.
  ///  3. `NO_COLOR` (https://no-color.org/) and `TERM=dumb`/unset beat `auto`.
  ///     They are the environment saying "not here", and `auto` is fvm saying
  ///     "unless told otherwise".
  ///  4. Otherwise: colour only when stdout is a terminal a human is watching.
  ///
  /// The terminal fact is the one about STDOUT. fvm asks the question once, in
  /// `lib/fvm.dart`, and stderr follows the same answer: the two are a terminal
  /// together or neither in every ordinary invocation, and asking twice would
  /// buy a case nobody has reported at the cost of two policies that can
  /// disagree.
  bool get enabled => switch (_mode) {
        ColorMode.always => true,
        ColorMode.never => false,
        ColorMode.auto =>
          _outIsTerminal && !_noColorRequested && _termSpeaksAnsi,
      };

  /// https://no-color.org/: set to anything non-empty means no colour.
  ///
  /// Present-but-empty is explicitly NOT a request, per the spec, and that
  /// matters in practice — a shell that exports every variable it has seen
  /// hands on `NO_COLOR=`.
  bool get _noColorRequested {
    final value = _environment['NO_COLOR'];
    return value != null && value.isNotEmpty;
  }

  /// Whether `TERM` names a terminal that can render escape sequences.
  ///
  /// `dumb` is the historical "no capabilities" value, and an UNSET `TERM` is
  /// treated the same way: it is what a bare `cron` job and some CI runners
  /// have, and neither is a place to start emitting escapes on a guess.
  bool get _termSpeaksAnsi {
    final term = _environment['TERM'];
    return term != null && term.isNotEmpty && term != 'dumb';
  }

  // ---------------------------------------------------------------------
  // The roles. Everything the CLI prints picks one of these or none.
  // ---------------------------------------------------------------------

  /// A passing check. `doctor`'s `ok` marker, and "Everything checks out."
  String ok(String text) => _wrap(text, _green);

  /// Something that is not wrong yet but will be. `doctor`'s `warn` marker and
  /// the `WARNING:` lines `setup` writes to stderr.
  String warn(String text) => _wrap(text, _yellow);

  /// The thing that is actually broken — `doctor`'s `FAIL`, and the count line
  /// that says how many there were.
  String fail(String text) => _wrap(text, _red);

  /// A section heading or a result line: `fvm doctor`, `Wrote …/shims/flutter`,
  /// `Installed Flutter 3.13.2 to …`. What somebody scrolling back is looking for.
  String heading(String text) => _wrap(text, _bold);

  /// Something the user is meant to TYPE or paste — `fvm setup`, the `export
  /// PATH=…` line. The one span on the screen that is an instruction rather
  /// than a description.
  String command(String text) => _wrap(text, _cyan);

  /// Supporting detail: the `-> Run:` lead-ins, the file lists under a finding,
  /// sizes, percentages and timings.
  ///
  /// This is the load-bearing half. What makes output skimmable is pushing
  /// context BACK, not adding more colours to look at, so when in doubt this is
  /// the role to reach for.
  String detail(String text) => _wrap(text, _dim);

  /// Wraps [text] unless colour is off — and never wraps an empty string, so a
  /// styled-but-absent fragment costs no bytes rather than an empty escape
  /// pair.
  String _wrap(String text, String code) =>
      !enabled || text.isEmpty ? text : '$code$text$_reset';

  static const String _reset = '\x1B[0m';
  static const String _bold = '\x1B[1m';
  static const String _dim = '\x1B[2m';
  static const String _red = '\x1B[31m';
  static const String _green = '\x1B[32m';
  static const String _yellow = '\x1B[33m';
  static const String _cyan = '\x1B[36m';
}
