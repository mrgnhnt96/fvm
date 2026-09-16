/// The diagnostic channel: what fvm decided, and why.
///
/// fvm is silent by design — `fvm which` and `fvm list` are read by scripts,
/// and the PATH shim sits in front of every `flutter` on the machine — so when it
/// misbehaves the only recourse used to be reading the source. This is the way
/// out of that: one sink, off by default, that every layer writes its working
/// to when it is on.
///
/// Two things turn it on, and they are an OR rather than a precedence puzzle:
/// the top-level `fvm -v` / `--verbose` flag, and [variable] in the
/// environment. The flag is discoverable from `fvm --help`; the environment
/// variable is the one that reaches fvm *through the shim*, where nobody is
/// typing a fvm command line at all and a CI log is the only witness.
///
/// It is an injected object rather than a global logger because
/// ARCHITECTURE.md rules out service locators and singletons, and because a
/// test has to be able to read a verbose run off a buffer instead of the
/// process's stderr.
class VerboseLog {
  VerboseLog({StringSink? sink, bool enabled = false})
      : _sink = sink,
        // A log with nowhere to write is off whatever it was asked for, so
        // [enabled] can never be true while [_sink] is null.
        _enabled = enabled && sink != null;

  /// The environment variable that turns verbose output on.
  static const String variable = 'FVM_VERBOSE';

  /// A log that writes nowhere and cannot be turned on.
  ///
  /// The default for anything constructed outside `lib/fvm.dart` — chiefly
  /// tests, which build collaborators directly. New rather than shared because
  /// a default value has to be a constant and this class carries state.
  static VerboseLog get disabled => VerboseLog();

  /// Whether [environment] asks for verbose output.
  ///
  /// Any non-empty value counts except `0` and `false`, so `FVM_VERBOSE=1`,
  /// `FVM_VERBOSE=true` and a bare `FVM_VERBOSE=yes` all work while
  /// `FVM_VERBOSE=0` and an empty `FVM_VERBOSE=` do not. Exporting the
  /// variable empty is how a shell profile *unsets* an inherited one, and it
  /// must not read as "on".
  static bool enabledIn(Map<String, String> environment) {
    final raw = environment[variable]?.trim().toLowerCase();
    if (raw == null || raw.isEmpty) return false;
    return raw != '0' && raw != 'false';
  }

  /// Where lines go. Always stderr in production — see [log].
  final StringSink? _sink;

  bool _enabled;

  /// Whether anything written here will actually be seen.
  bool get enabled => _enabled;

  /// Turns the log on for the rest of the process.
  ///
  /// One-way on purpose. The top-level `--verbose` flag is not parsed until
  /// after [FvmContext] has been wired — every collaborator already holds this
  /// object by then — so the flag flips the instance rather than choosing a
  /// different one. Nothing turns it back off, so no command can silence a
  /// diagnostic the user asked for.
  void enable() => _enabled = _sink != null;

  /// Writes one diagnostic line, tagged [area], if the log is on.
  ///
  /// [message] is a callback rather than a string because this is the hot
  /// path: the PATH shim runs resolution on every `flutter` invocation on the
  /// machine, and a non-verbose run must not pay to build a message it throws
  /// away. Nothing inside [message] runs while the log is off.
  ///
  /// Output always goes to **stderr**, never stdout. `fvm which`, `fvm list`
  /// and everything behind the shim have stdout consumed by other programs; a
  /// tool parsing `flutter --version` must not receive fvm's chatter.
  void log(String area, String Function() message) {
    if (!_enabled) return;
    _sink!.writeln('[fvm $area] ${message()}');
  }

  /// Writes one tagged line per entry of [messages], if the log is on.
  ///
  /// For the cases that are naturally a list — a PATH scan, an environment
  /// overlay — so the caller neither joins strings the log may discard nor
  /// repeats the tag by hand.
  void logAll(String area, Iterable<String> Function() messages) {
    if (!_enabled) return;
    for (final message in messages()) {
      _sink!.writeln('[fvm $area] $message');
    }
  }

  /// A started [Stopwatch] when the log is on, and null when it is off.
  ///
  /// Timings are only interesting in a verbose run, and the null is what keeps
  /// a silent one from paying for them. A `log` callback that reads the result
  /// only ever runs while this is non-null, so `!` is safe inside one.
  Stopwatch? stopwatch() => _enabled ? (Stopwatch()..start()) : null;
}

/// The tags [VerboseLog.log] lines are grouped under.
///
/// Constants rather than free strings so that `grep '\[fvm resolve\]'` finds
/// every line of a walk and not most of them.
abstract final class VerboseArea {
  /// Which SDK applies, and which of the five rules said so.
  static const String resolve = 'resolve';

  /// The command line fvm itself was given.
  static const String cli = 'cli';

  /// Handing off to the SDK — the shim's own path.
  static const String exec = 'exec';

  /// HTTP against the Flutter archive and fvm's own releases.
  static const String net = 'net';

  /// Files read, written, linked and deleted.
  static const String fs = 'fs';

  /// Child processes: argv, working directory, environment, exit code.
  static const String proc = 'proc';

  /// Downloading, extracting and publishing an SDK.
  static const String install = 'install';
}
