import 'package:file/file.dart';
import 'package:path/path.dart' as p;

import 'path_line.dart';

/// The shell the user is in, as far as `$SHELL` can say.
enum ShellKind {
  zsh('zsh'),
  bash('bash'),
  fish('fish'),

  /// Windows' own shell, where PATH is an environment setting rather than a
  /// line in a startup file.
  ///
  /// Chosen on Windows when `$SHELL` says nothing. A Windows user who IS in a
  /// POSIX shell — Git Bash and MSYS both set `$SHELL` — gets the shell they
  /// are actually in, which is the whole reason this is not simply "the host
  /// is Windows".
  powershell('powershell'),

  /// Anything else, including "the environment did not say".
  posix('sh');

  const ShellKind(this.token);

  /// How the shell is spelled in `$SHELL` and in output.
  final String token;
}

/// Why a line in a startup file would win over the shim on PATH.
enum ShadowKind {
  /// `fvm() { ... }` or fish's `function fvm`.
  function('a shell function named fvm'),

  /// `alias fvm=...`.
  alias('a shell alias named fvm'),

  /// Sourcing the older shell-based version manager, which defines the function itself.
  legacySource("a line sourcing a conflicting fvm shell script");

  const ShadowKind(this.description);

  /// A noun phrase that completes "… defines `<description>`".
  final String description;
}

/// One line in a startup file that shadows the `fvm` binary.
class ShellShadow {
  const ShellShadow({
    required this.kind,
    required this.file,
    required this.line,
    required this.text,
  });

  final ShadowKind kind;

  /// The startup file the line is in.
  final File file;

  /// Its 1-based line number, so the user can jump straight to it.
  final int line;

  /// The line itself, trimmed.
  final String text;

  /// `~/.zshrc:12: [ -s "$HOME/.fvm/scripts/fvm" ] && . …`
  String describe() => '${file.path}:$line: $text';
}

/// One line in a startup file that puts the shims directory on PATH.
///
/// Finding one is not by itself good news. A line in a file the running shell
/// never sources has exactly the same text as a line that works, and the whole
/// of this leaf's bug was a check that could not tell them apart. Whether it is
/// IN EFFECT is a separate question, asked of the live `PATH`.
class RcPathLine {
  const RcPathLine({
    required this.file,
    required this.line,
    required this.text,
  });

  /// The startup file the line is in.
  final File file;

  /// Its 1-based line number.
  final int line;

  /// The line itself, trimmed.
  final String text;

  /// `/home/dev/.profile:2`.
  String describe() => '${file.path}:$line';
}

/// What a scan of the startup files found, including what it could not read.
///
/// [unreadable] is separate from an empty [shadows] on purpose: "there is no
/// shadowing function" and "we could not open the file that would have one" are
/// different answers, and reporting the second as the first is how a user ends
/// up being told everything is fine while their shell runs a different fvm.
class ShellScan {
  const ShellScan({
    required this.shadows,
    required this.unreadable,
    this.pathLines = const [],
  });

  final List<ShellShadow> shadows;

  /// Files that exist but could not be read, with the reason.
  final Map<String, String> unreadable;

  /// Every startup file that claims to put the shims directory on PATH.
  ///
  /// Empty unless the scan was given something to match with — see
  /// [ShellFacts.scanForShadows].
  final List<RcPathLine> pathLines;

  bool get isClean => shadows.isEmpty && unreadable.isEmpty;
}

/// The shell facts `setup` and `doctor` both need.
///
/// Everything here is derived from the injected environment and filesystem —
/// no `dart:io` — so a test can put a synthetic `$SHELL` and a fake `.zshrc` in
/// front of it without going near the real one.
class ShellFacts {
  ShellFacts({
    required this.fileSystem,
    required Map<String, String> environment,
  }) : _environment = environment;

  final FileSystem fileSystem;
  final Map<String, String> _environment;

  /// The raw `$SHELL`, or null when it is not set — which is normal in CI and
  /// in a `Process.start` with a hand-built environment.
  String? get shellPath {
    final value = _environment['SHELL']?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  /// Which shell [shellPath] names, defaulting to [ShellKind.posix].
  ShellKind get kind => _detected.kind;

  /// Whether [kind] was ASSUMED rather than read out of the environment.
  ///
  /// True when `$SHELL` is unset, or set to something whose basename matches no
  /// shell fvm knows. In both cases [kind] is [ShellKind.posix] because that is
  /// the safe default for *running* things — but it is not a fact about the
  /// user's shell, and [primaryRcFile] treating it as one is what wrote a PATH
  /// line into a `.profile` that zsh never reads.
  ///
  /// False when `$SHELL` explicitly names a shell, INCLUDING `/bin/sh`,
  /// `/bin/dash` and `/bin/ksh`: those are genuine POSIX shells that genuinely
  /// read `.profile`, and treating a correct answer as a guess would nag a user
  /// whose setup is right.
  ///
  /// Also false on Windows with no `$SHELL`, where the absence IS the answer —
  /// see [ShellKind.powershell].
  bool get kindIsAssumed => _detected.assumed;

  late final ({ShellKind kind, bool assumed}) _detected = _detectKind();

  /// The user's home directory, or null if the environment does not say.
  ///
  /// This is the plain home, not `~/.fvm`: startup files live in it.
  late final Directory? home = _detectHome();

  /// Every startup file fvm knows about, and the shell that reads it.
  ///
  /// ONE table, because the three questions asked of these names have to agree:
  /// which file to WRITE to, which files to SCAN, and — the one this leaf is
  /// about — which files belong to a shell that is not the one detected. A
  /// second list of names is how a file becomes writable but unscanned.
  ///
  /// The first entry for a shell is the one [primaryRcFile] names. Order is
  /// otherwise the order [rcCandidates] reports findings in.
  ///
  /// PowerShell is absent on purpose: it has a profile, but it is not where
  /// PATH belongs and its location differs between Windows PowerShell and
  /// PowerShell 7. The line [pathLine] hands out edits the environment
  /// directly, so there is no file to name and naming one anyway would send
  /// the user to the wrong place.
  static const List<(ShellKind, List<String>)> _rcFiles = [
    (ShellKind.zsh, ['.zshrc']),
    (ShellKind.zsh, ['.zshenv']),
    (ShellKind.zsh, ['.zprofile']),
    (ShellKind.zsh, ['.zlogin']),
    (ShellKind.bash, ['.bashrc']),
    (ShellKind.bash, ['.bash_profile']),
    (ShellKind.bash, ['.bash_login']),
    (ShellKind.posix, ['.profile']),
    (ShellKind.fish, ['.config', 'fish', 'config.fish']),
  ];

  /// The startup file to add the PATH line to, or null with no home.
  ///
  /// One file, named for [kind], because `setup` has to print a single
  /// instruction. It may well not exist yet; that is not an error, a user with
  /// no `.zshrc` still needs to be told to create one.
  ///
  /// It is only as good as [kind]. When [kindIsAssumed] is true this is a
  /// GUESS, and [rcFileIsGuessed] says when the home directory contradicts it —
  /// callers that WRITE must consult that before they do.
  File? get primaryRcFile {
    for (final (owner, names) in _rcFiles) {
      if (owner == kind) return _inHome(names);
    }
    return null;
  }

  /// Every startup file worth scanning for a shadowing definition.
  ///
  /// Deliberately not filtered by [kind]. A `fvm` function left in `.zshrc` is
  /// what breaks a zsh login even if `$SHELL` says something else right now,
  /// and `$SHELL` is exactly the variable that is wrong inside a subshell, an
  /// editor terminal, or a CI runner.
  List<File> get rcCandidates => [
        for (final (_, names) in _rcFiles)
          if (_inHome(names) case final file?) file,
      ];

  /// Startup files that EXIST in this home and belong to a shell other than
  /// [kind].
  ///
  /// The evidence that [primaryRcFile] may be a file nothing reads. A machine
  /// whose `$SHELL` says nothing but whose home holds a `.zshrc` is a machine
  /// where somebody uses zsh, and zsh does not read `.profile`.
  /// Each is paired with the shell it belongs to, so a caller can name that
  /// shell in the one command that resolves the ambiguity.
  List<({ShellKind shell, File file})> get otherShellRcFiles => [
        for (final (owner, names) in _rcFiles)
          if (owner != kind)
            if (_inHome(names) case final file? when file.existsSync())
              (shell: owner, file: file),
      ];

  /// Whether [primaryRcFile] is a guess the home directory contradicts.
  ///
  /// Both halves are needed. [kindIsAssumed] alone is the ordinary CI case,
  /// where there is no startup file at all and `.profile` is as good an answer
  /// as any; [otherShellRcFiles] alone is the ordinary developer case, where
  /// `$SHELL` said zsh and a stale `.bashrc` is none of fvm's business.
  /// Together they are the state that wrote a PATH line nothing would ever
  /// read.
  bool get rcFileIsGuessed => kindIsAssumed && otherShellRcFiles.isNotEmpty;

  /// The single line to add to [primaryRcFile] so [directories] are on PATH,
  /// ahead of everything already there.
  ///
  /// Prepending is the whole contract: a `flutter` earlier on PATH is found first
  /// and the shim never runs. [directories] keep the order they are given, so
  /// the caller passes the shims directory first — it is the one with a
  /// precedence requirement.
  ///
  /// ONE line covering several directories rather than one line each. Two
  /// lines is two things for the user to paste and two chances to paste only
  /// the first, which is the three-step setup this exists to collapse.
  ///
  /// `\$PATH` on the right-hand side stays LITERAL — see [_posixPathLine].
  String pathLine(List<Directory> directories) {
    final entries = [for (final directory in directories) directory.path];
    return switch (kind) {
      // fish_add_path is idempotent and does the right thing with the
      // universal path variable, which a bare `set -gx` does not. It takes
      // several paths, and prepends them in the order given.
      ShellKind.fish => 'fish_add_path --prepend ${entries.join(' ')}',
      ShellKind.powershell => _powerShellPathLine(entries),
      _ => _posixPathLine(entries),
    };
  }

  /// `export PATH="<a>:<b>:\$PATH"`.
  ///
  /// The `\$PATH` is written literally into the startup file and is expanded
  /// by the shell, every login, at the point the line runs. Writing the
  /// EXPANDED value instead would freeze the PATH this process happens to see
  /// and assign it back — discarding whatever the user's own earlier lines had
  /// added, silently, on every shell they open. `shell_test.dart` pins the
  /// literal with a raw string for exactly that reason.
  String _posixPathLine(List<String> entries) =>
      'export PATH="${entries.join(':')}:\$PATH"';

  /// How the user makes [pathLine] take effect, as the start of a sentence.
  ///
  /// A POSIX shell reads a startup file, so the line goes IN one. PowerShell
  /// takes PATH from the user's environment, so the line is a command that
  /// EDITS it, and telling someone to paste a command into a file they do not
  /// have is how a working tool looks broken.
  String get pathLineAction => kind == ShellKind.powershell
      ? 'Run this once in PowerShell'
      : 'Add it to your shell startup file';

  /// Prepends [entries] to the user's persistent PATH.
  ///
  /// The `User` scope rather than `Machine`: fvm installs per user and this
  /// needs no elevation. `setx` would be shorter and is the usual advice, but
  /// it truncates the value at 1024 characters, which silently destroys a PATH
  /// that has grown past it.
  ///
  /// The existing PATH is READ at run time and concatenated, which is the
  /// PowerShell spelling of keeping `\$PATH` literal: the value that gets
  /// stored is the current one plus fvm's, never fvm's alone.
  String _powerShellPathLine(List<String> entries) {
    // Doubling is PowerShell's escape for a quote inside a single-quoted
    // string. A path is unlikely to contain one and a mangled PATH line is a
    // bad way to find out.
    final path = entries.join(';').replaceAll("'", "''");
    return "[Environment]::SetEnvironmentVariable('Path', '$path;' + "
        "[Environment]::GetEnvironmentVariable('Path', 'User'), 'User')";
  }

  /// Whether [directory] is already an entry in this environment's `PATH`.
  ///
  /// The ENVIRONMENT, not the startup file. They answer different questions
  /// and both are worth asking: `PathLineEditor` asks whether the FILE already
  /// carries the line, while this asks whether the directory is already in
  /// effect in the shell the user is standing in. Telling somebody to add a
  /// line that is already working is the kind of instruction that makes a tool
  /// look like it is not paying attention.
  bool isOnPath(Directory directory) {
    final raw = _environment['PATH'] ?? _environment['Path'];
    if (raw == null || raw.isEmpty) return false;

    final context = fileSystem.path;
    // `;` on Windows, `:` everywhere else — and the FILESYSTEM's style again,
    // for the same reason [FvmPaths.isWindows] uses it.
    final separator = context.style == p.Style.windows ? ';' : ':';
    final wanted = context.normalize(directory.path);

    for (final entry in raw.split(separator)) {
      final trimmed = entry.trim();
      // An empty entry means "the current directory" to a POSIX shell, not
      // "no entry", but it is never the directory being asked about.
      if (trimmed.isEmpty) continue;
      if (context.equals(wanted, context.normalize(trimmed))) return true;
    }
    return false;
  }

  /// Reads every candidate startup file, looking for something that would win
  /// over the `fvm` binary on PATH.
  ///
  /// Pass [shimsLine] to have the same pass also collect the files that claim
  /// to put the shims directory on PATH. One pass and one matcher: a file fvm
  /// reads for a shadow is a file fvm reads for a misfiled PATH line, and the
  /// alternative is two scans that can disagree about which files exist.
  ShellScan scanForShadows({ShimsPathLine? shimsLine}) {
    final shadows = <ShellShadow>[];
    final unreadable = <String, String>{};
    final pathLines = <RcPathLine>[];

    for (final file in rcCandidates) {
      if (!file.existsSync()) continue;

      final List<String> lines;
      try {
        lines = file.readAsLinesSync();
      } on FileSystemException catch (error) {
        unreadable[file.path] = error.message;
        continue;
      }

      for (var index = 0; index < lines.length; index++) {
        final text = lines[index].trim();
        // A commented-out definition is what a user leaves behind after
        // fixing this, and reporting it would send them back to a file that
        // is already correct.
        if (text.isEmpty || text.startsWith('#')) continue;

        if (shimsLine != null && shimsLine.matches(text)) {
          pathLines.add(RcPathLine(file: file, line: index + 1, text: text));
        }

        final kind = _classify(text);
        if (kind == null) continue;
        shadows.add(
          ShellShadow(
            kind: kind,
            file: file,
            line: index + 1,
            text: text,
          ),
        );
      }
    }

    return ShellScan(
      shadows: shadows,
      unreadable: unreadable,
      pathLines: pathLines,
    );
  }

  /// Which kind of shadow [line] is, or null if it is an ordinary line.
  ShadowKind? _classify(String line) {
    if (_legacyScriptPattern.hasMatch(line)) return ShadowKind.legacySource;
    if (_aliasPattern.hasMatch(line)) return ShadowKind.alias;
    if (_functionPattern.hasMatch(line) ||
        _fishFunctionPattern.hasMatch(line)) {
      return ShadowKind.function;
    }
    return null;
  }

  /// `fvm() {`, `fvm ()`, and the `{` on the next line variant.
  static final RegExp _functionPattern = RegExp(r'^fvm\s*\(\s*\)');

  /// ksh/bash/fish `function fvm`.
  static final RegExp _fishFunctionPattern = RegExp(r'^function\s+fvm\b');

  static final RegExp _aliasPattern = RegExp(r'^alias\s+fvm\s*=');

  /// Any mention of the older tool's shell script, however it is sourced —
  /// `. "$HOME/.fvm/scripts/fvm"`, `source ~/.fvm/scripts/fvm`, and the
  /// `[ -s … ] &&` guard the old README hands out.
  static final RegExp _legacyScriptPattern =
      RegExp(r'\.fvm[/\\]scripts[/\\]fvm\b');

  ({ShellKind kind, bool assumed}) _detectKind() {
    final path = shellPath;
    if (path == null) {
      // On Windows the absence of $SHELL is itself the answer: cmd and
      // PowerShell do not set it, and both take PATH from the environment
      // rather than from a startup file. Everywhere else it is an absence and
      // nothing more, so the posix fallback is flagged as the guess it is.
      return fileSystem.path.style == p.Style.windows
          ? (kind: ShellKind.powershell, assumed: false)
          : (kind: ShellKind.posix, assumed: true);
    }
    // Basename, because $SHELL is a path: /bin/zsh, /opt/homebrew/bin/fish.
    final name = p.posix.basename(path).toLowerCase();
    for (final kind in ShellKind.values) {
      if (name == kind.token || name.endsWith(kind.token)) {
        return (kind: kind, assumed: false);
      }
    }
    return (kind: ShellKind.posix, assumed: true);
  }

  Directory? _detectHome() {
    for (final variable in const ['HOME', 'USERPROFILE']) {
      final value = _environment[variable]?.trim();
      if (value != null && value.isNotEmpty) {
        return fileSystem.directory(value);
      }
    }
    return null;
  }

  File? _inHome(List<String> names) {
    final directory = home;
    if (directory == null) return null;
    return fileSystem.file(
      fileSystem.path.joinAll([directory.path, ...names]),
    );
  }
}
