import 'dart:async';
import 'dart:io';

import 'package:file/file.dart';
import 'package:path/path.dart' as p;

import 'process.dart';
import 'resolver.dart';
import 'verbose.dart';

/// The real [ProcessRunner]: the code path every `flutter` invocation on the
/// machine goes through once the shim is installed.
///
/// Flutter has no `exec()`, so fvm cannot replace itself with the child and has to
/// impersonate it instead. Three things make that impersonation convincing, and
/// all three are load-bearing:
///
/// * `inheritStdio` hands the child fvm's own file descriptors, so the child is
///   talking to the real terminal. Anything that asks "am I a tty?" — `flutter
///   run` with a prompt, progress bars, colour — gets the right answer, and
///   fvm never sits between the two copying bytes.
/// * the child's exit code becomes fvm's. A version manager that turns a failing
///   `dart test` into a success breaks CI for everyone downstream of it.
/// * SIGINT and SIGTERM are forwarded. Ctrl-C at a terminal already reaches the
///   whole foreground process group, but a `kill` aimed at fvm by a supervisor
///   or a script does not; without forwarding that kills the wrapper and leaves
///   the real work orphaned.
class OsProcessRunner implements ProcessRunner {
  const OsProcessRunner({VerboseLog? verbose}) : _verbose = verbose;

  /// Where the spawn is described, when anything asked. Nullable rather than a
  /// disabled instance so that `const OsProcessRunner()` stays const.
  final VerboseLog? _verbose;

  /// The signals a wrapper is expected to pass on, on THIS platform.
  ///
  /// SIGKILL is deliberately absent: it cannot be caught, so there is nothing
  /// to forward.
  ///
  /// SIGTERM is absent on Windows, and asking for it there is not a harmless
  /// no-op. `ProcessSignal.sigterm.watch()` fails with "The request is not
  /// supported", and the [SignalException] below never catches it: dart:io
  /// runs the stream's onListen through the zone, so the failure arrives as an
  /// UNHANDLED ASYNCHRONOUS error rather than a throw at the call site. The
  /// observed effect on windows-latest was that `fvm flutter --version` printed
  /// the SDK's answer, then printed `Unhandled exception: SignalException` and
  /// exited 255 — so every `flutter` on the machine ran correctly and reported the
  /// wrong exit code, which is the one failure mode a launcher must not have.
  ///
  /// Asked per platform rather than filtered by catching, because a handler
  /// that cannot be installed is a fact about the OS and is known before the
  /// attempt.
  static List<ProcessSignal> get _signals => Platform.isWindows
      ? const [ProcessSignal.sigint]
      : const [ProcessSignal.sigint, ProcessSignal.sigterm];

  @override
  Future<int> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    final verbose = _verbose;
    verbose?.log(
      VerboseArea.proc,
      () => 'spawn $executable ${arguments.join(' ')}',
    );
    verbose?.log(
      VerboseArea.proc,
      // Null means "inherit fvm's own", which `Process.start` does.
      () => '  cwd: ${workingDirectory ?? '(inherited)'}',
    );
    verbose?.logAll(
      VerboseArea.proc,
      () => [
        for (final entry in (environment ?? const <String, String>{}).entries)
          // The OVERLAY only. `Process.start` merges these over the real
          // environment, so this is exactly what fvm changed and nothing else.
          '  env override: ${entry.key}=${entry.value}',
      ],
    );
    final elapsed = verbose?.stopwatch();

    final process = await Process.start(
      executable,
      arguments,
      environment: environment,
      workingDirectory: workingDirectory,
      mode: ProcessStartMode.inheritStdio,
    );
    verbose?.log(VerboseArea.proc, () => '  pid ${process.pid}');

    final forwarding = <StreamSubscription<ProcessSignal>>[];
    for (final signal in _signals) {
      final subscription = _forward(signal, process);
      if (subscription != null) forwarding.add(subscription);
    }

    try {
      final code = await process.exitCode;
      verbose?.log(
        VerboseArea.proc,
        () => '  pid ${process.pid} exited $code '
            'after ${elapsed!.elapsedMilliseconds}ms',
      );
      return code;
    } finally {
      // Cancelling puts the default disposition back. It matters because
      // watching SIGINT is what stopped Ctrl-C from killing fvm itself while
      // the child was running; leaving the watch in place would make a fvm
      // that outlived its child unkillable by Ctrl-C.
      for (final subscription in forwarding) {
        await subscription.cancel();
      }
    }
  }

  StreamSubscription<ProcessSignal>? _forward(
    ProcessSignal signal,
    Process process,
  ) {
    try {
      return signal.watch().listen((received) {
        // The child may already have exited between the signal arriving and
        // this line; killing a dead process is a false, not a throw, but the
        // platform is entitled to complain and it must not become fvm's
        // problem.
        try {
          process.kill(received);
        } on Object {
          // Nothing useful to say: the child is gone, which is the outcome the
          // signal was asking for anyway.
        }
      });
    } on SignalException {
      // Kept as a backstop for a platform that refuses a signal [_signals]
      // expects to work — a container with a restricted seccomp profile, say.
      // It is NOT what handles Windows: see [_signals] for why a catch here
      // cannot see that one.
      return null;
    }
  }
}

/// How a child process sees the SDK that fvm resolved for it.
///
/// `fvm flutter` and `fvm exec` differ only in what they run, never in what the
/// child's world looks like, so the environment is built here rather than in
/// either command: a difference between them would be a bug that only shows up
/// in whichever one was written second.
class SdkInvocation {
  SdkInvocation({
    required this.fileSystem,
    required this.sdk,
    required Map<String, String> environment,
    VerboseLog? verbose,
  })  : _parent = environment,
        _verbose = verbose ?? VerboseLog.disabled;

  final FileSystem fileSystem;
  final ResolvedSdk sdk;
  final Map<String, String> _parent;
  final VerboseLog _verbose;

  /// The directory holding the resolved `flutter`.
  ///
  /// Taken from the executable rather than composed as `sdkDir/bin`, because
  /// resolution rule 4 picks up an SDK fvm did not lay out and reaches it
  /// through whatever symlinks the machine happens to have.
  late final String binDir = fileSystem.path.dirname(sdk.executable.path);

  /// The PATH the child gets: [binDir] first, then everything the parent had.
  ///
  /// First is the whole point. `fvm exec melos bootstrap` only means anything
  /// if the `flutter` that melos goes on to spawn is the pinned one.
  late final String path = _prefixed();

  /// What to change about the parent environment for the child.
  ///
  /// Overrides only — `Process.start` merges these over the real environment,
  /// and a child handed a hand-built environment instead of the user's own
  /// would be missing HOME, TERM and everything else it needs.
  late final Map<String, String> environment = {
    _pathKey: path,
    // Absent under rule 4, where the SDK is not fvm-managed and pinning a
    // version fvm did not choose would be a lie a nested fvm then acts on.
    if (sdk.version case final version?)
      VersionResolver.versionVariable: version,
  };

  /// Where [command] resolves on the child's [path], or null if nothing there
  /// matches.
  ///
  /// fvm does the lookup itself rather than handing a bare name to
  /// `Process.start`, because the point of `exec` is to search the PATH the
  /// *child* is about to get, and the platform would search the one fvm has.
  File? lookup(String command) {
    if (command.isEmpty) return null;

    // The shell's rule: a name with a separator in it is a path, and is used
    // as given rather than searched for.
    if (_isPathLike(command)) {
      final file = fileSystem.file(command);
      final found = file.existsSync();
      _verbose.log(
        VerboseArea.exec,
        () => '"$command" contains a separator, so it is used as a path '
            '(${found ? 'exists' : 'does not exist'})',
      );
      return found ? file : null;
    }

    _verbose.log(
      VerboseArea.exec,
      () => 'looking for "$command" on the CHILD PATH: $path',
    );
    for (final entry in path.split(_separator)) {
      final directory = entry.trim();
      if (directory.isEmpty) continue;
      for (final name in _candidateNames(command)) {
        final candidate = fileSystem.file(
          fileSystem.path.join(directory, name),
        );
        if (candidate.existsSync()) {
          _verbose.log(
            VerboseArea.exec,
            () => '  found at ${candidate.path}',
          );
          return candidate;
        }
      }
    }
    _verbose.log(
      VerboseArea.exec,
      () => '  "$command" is on none of those directories',
    );
    return null;
  }

  /// The parent's own spelling of PATH.
  ///
  /// Windows environment variables are case-insensitive and real ones arrive as
  /// `Path`; writing `PATH` back would leave the child with the old value under
  /// the old name on any platform that disagrees.
  String get _pathKey {
    for (final key in _parent.keys) {
      if (key.toLowerCase() == 'path') return key;
    }
    return 'PATH';
  }

  String _prefixed() {
    final existing = _parent[_pathKey];
    if (existing == null || existing.isEmpty) return binDir;

    // A nested invocation inherits a PATH this function already prefixed. Left
    // alone, `fvm exec` inside `fvm exec` inside a build script grows PATH by
    // one entry per level for the whole tree.
    final first = existing.split(_separator).first.trim();
    if (fileSystem.path.equals(first, binDir)) return existing;

    return '$binDir$_separator$existing';
  }

  List<String> _candidateNames(String command) {
    if (!_isWindows) return [command];
    // Windows resolves a bare name through PATHEXT; a name that already has an
    // extension is used as written.
    if (fileSystem.path.extension(command).isNotEmpty) return [command];
    return ['$command.exe', '$command.bat', '$command.cmd', command];
  }

  bool _isPathLike(String command) =>
      command.contains('/') || (_isWindows && command.contains(r'\'));

  String get _separator => _isWindows ? ';' : ':';

  bool get _isWindows => fileSystem.path.style == p.Style.windows;
}
