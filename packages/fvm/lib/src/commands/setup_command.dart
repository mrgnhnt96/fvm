import 'dart:io' as io;

import 'package:args/command_runner.dart';
import 'package:file/file.dart';

import '../core/context.dart';
import '../core/exceptions.dart';
import '../core/path_line.dart';
import '../core/shell.dart';
import '../core/shims.dart';

/// `fvm setup` — Install the shims and print the PATH line to add.
///
/// Writes the shim, then tells the user the one line to add to their shell's
/// startup file. By default it deliberately does **not** edit that file: a
/// version manager that rewrites `.zshrc` behind someone's back is a version
/// manager people stop trusting, and the line differs enough between shells
/// and setups that getting it wrong silently breaks their login shell.
///
/// `--write-path-line` is the escape hatch for a user who would rather fvm did
/// it: it backs the file up, writes the line between markers so it can be
/// found again, and `--remove-path-line` takes it back out.
class SetupCommand extends Command<int> {
  SetupCommand({
    required this.context,
    String Function()? fvmExecutable,
    DateTime Function()? now,
  })  : _fvmExecutable = fvmExecutable ?? _resolvedExecutable,
        _now = now ?? DateTime.now {
    argParser
      ..addOption(
        'fvm-path',
        valueHelp: 'path',
        help: 'The fvm binary to bake into the shim. Defaults to the running '
            'one; needed when running from source.',
      )
      ..addFlag(
        'write-path-line',
        negatable: false,
        help: 'Add the PATH line to your shell startup file instead of just '
            'printing it. Backs the file up first, and does nothing if the '
            'line is already there. Not available for PowerShell, which takes '
            'PATH from your environment rather than a startup file.',
      )
      ..addFlag(
        'remove-path-line',
        negatable: false,
        help: 'Take the PATH line --write-path-line added back out, leaving '
            'the shims in place. A line you added by hand is left alone.',
      );
  }

  final FvmContext context;

  /// Where the running fvm binary is. Injected so a test can drive `setup`
  /// without the answer depending on how the test runner was launched.
  final String Function() _fvmExecutable;

  /// The clock behind the backup file's name, injected so a test can assert on
  /// the exact path the user is told about.
  final DateTime Function() _now;

  static String _resolvedExecutable() => io.Platform.resolvedExecutable;

  @override
  String get name => 'setup';

  @override
  String get description => 'Install the shims and print the PATH line to add.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final write = results.flag('write-path-line');
    final remove = results.flag('remove-path-line');
    if (write && remove) {
      throw ConfigException(
        '--write-path-line and --remove-path-line ask for opposite things. '
        'Pass one of them.',
      );
    }

    // Removal is the inverse of the flag and nothing else: it does not write
    // shims, so it does not need a fvm binary to point them at, and it works
    // from a source checkout the way an undo should.
    if (remove) return _removePathLine();

    return _setup(_resolveFvmBinary(), write: write);
  }

  Future<int> _setup(File binary, {required bool write}) async {
    final writer = ShimWriter(
      fileSystem: context.fileSystem,
      paths: context.paths,
      verbose: context.verbose,
    );
    final shim = await writer.write(binary.path);

    // The RESULT line, then what it points at. The second is detail: somebody
    // re-running `setup` is checking that the first one happened.
    context.out
      ..writeln(context.styles.heading('Wrote ${shim.path}'))
      ..writeln(context.styles.detail('  -> ${binary.path} exec flutter'))
      ..writeln();

    final shell = _shell();
    final scan = shell.scanForShadows();

    // A shadow beats PATH outright and an unreadable startup file may be the
    // one holding it, so writing would look like success while changing
    // nothing. `_reportConflicts` prints the specifics just below.
    //
    // Both branches read the same value on purpose: the branch that *offers*
    // `--write-path-line` must not offer it in the situation where the branch
    // that *performs* it would refuse, or the user is sent to a flag that is
    // guaranteed to decline.
    final blocked = scan.shadows.isNotEmpty || scan.unreadable.isNotEmpty;

    // What the PATH line has to cover. Worked out from the binary that was
    // just baked into the shim, so the line and the shim agree about which
    // fvm this install is.
    final directories = _pathDirectories(binary);

    var declined = false;
    if (write) {
      declined = !_writePathLine(shell, directories, binary, blocked: blocked);
    } else {
      _printPathInstructions(shell, directories, binary, blocked: blocked);
    }

    final conflicts = _reportConflicts(scan);

    context.out
      ..writeln()
      ..writeln('${context.styles.detail('Then check it with: ')}'
          '${context.styles.command('fvm doctor')}');

    // A conflict makes the shim inert, so `setup` reporting success would be
    // a lie the user only finds out about the next time they run `flutter`. A
    // `--write-path-line` that declined to write fails for the same reason:
    // the user asked for the line to be there and it is not.
    return conflicts || declined ? 1 : 0;
  }

  /// The fvm binary to bake into the shim.
  ///
  /// `--fvm-path` wins, then the running executable. Running from source is
  /// refused rather than guessed at: under `dart run bin/fvm.dart`, the
  /// resolved executable is the *Dart VM*, and a shim reading `exec /…/flutter
  /// exec flutter "$@"` would hand `exec flutter` to the SDK as arguments on every
  /// `flutter` invocation on the machine.
  File _resolveFvmBinary() {
    final override = argResults!.option('fvm-path')?.trim();
    if (override != null && override.isNotEmpty) {
      final file = context.fileSystem.file(_absolute(override));
      if (!file.existsSync()) {
        throw ConfigException(
          '--fvm-path names ${file.path}, which does not '
          'exist.',
        );
      }
      return file;
    }

    final resolved = _fvmExecutable();
    if (_isFlutterVm(resolved)) {
      throw ConfigException(
        'fvm is running from source (via $resolved), so it cannot tell where '
        'a fvm binary lives, and a shim pointing at the Dart VM would break '
        'every `flutter` on this machine.\n'
        'Compile it first:  dart compile exe bin/fvm.dart -o /usr/local/bin/fvm\n'
        'Or name the binary: fvm setup --fvm-path <path to fvm>',
      );
    }
    return context.fileSystem.file(resolved);
  }

  /// The directories the PATH line has to cover, in the order they go on PATH.
  ///
  /// The shims directory is always in it and always first: it is what makes
  /// `flutter` resolve to the shim, and it has to beat anything else on PATH that
  /// provides a `flutter`.
  ///
  /// The directory holding the fvm binary is added only when it is
  /// [FvmPaths.binDir] — the one place `install.sh` puts it. That single rule
  /// is the whole guard, and it is deliberately narrower than "wherever fvm
  /// happens to be running from":
  ///
  ///  * A checkout build, a copy in `/tmp`, a colleague's `~/Downloads` — fvm
  ///    cannot tell any of those from an install, and a startup file is not
  ///    the place to guess. A wrong entry there is permanent and silent.
  ///  * A package manager's prefix (`/opt/homebrew/bin`, `/usr/local/bin`) is
  ///    already on PATH for its own reasons; fvm adding it again would be a
  ///    duplicate at best and would reorder somebody's PATH at worst.
  ///
  /// It subsumes [kIsCompiled] rather than adding to it. Running from source
  /// with no `--fvm-path` never reaches here — [_resolveFvmBinary] refuses it
  /// first. Running from source WITH `--fvm-path` naming the installed binary
  /// names a real install whose directory belongs on PATH no matter what is
  /// driving it, and gating that on "was this process AOT-compiled" would
  /// answer a question nobody asked.
  List<Directory> _pathDirectories(File binary) => [
        context.paths.shimsDir,
        if (_isInstalledBinary(binary)) context.paths.binDir,
      ];

  /// Whether [binary] sits where an install puts it.
  ///
  /// Compared through the injected filesystem's path context. [binary] may be
  /// spelled the way the HOST spells paths while the context is styled
  /// differently — under test it always is — and the honest answer when the
  /// two cannot be compared is "no", which costs the user the `bin` half of
  /// one line rather than a nonsense PATH entry.
  bool _isInstalledBinary(File binary) {
    final path = context.fileSystem.path;
    return path.equals(path.dirname(binary.path), context.paths.binDir.path);
  }

  /// Says, when the line covers the shims alone, that `fvm` itself is not
  /// being put on PATH and why.
  ///
  /// Silent when [directories] already covers it. This is the half of the
  /// guard the user can see: a line that quietly did less than they expected
  /// is how somebody concludes the flag is broken.
  void _explainOmittedBinDir(List<Directory> directories, File binary) {
    if (directories.length > 1) return;
    final styles = context.styles;
    context.out
      ..writeln()
      ..writeln(styles.detail(
        'That line puts the shims on PATH, not `fvm` itself. The fvm '
        'running now is ${binary.path}, which is not '
        '${context.paths.binDir.path}, so fvm cannot tell '
        'whether that directory is an install worth adding — a guess would '
        'go into your startup file permanently.',
      ))
      ..writeln(styles.detail(
        'If you want the `fvm` command on PATH from there, add it '
        'yourself.',
      ));
  }

  /// Whether [path] names the Dart VM rather than a fvm binary.
  ///
  /// The last segment after EITHER separator, rather than
  /// `context.fileSystem.path.basename`. [path] comes from
  /// `Platform.resolvedExecutable`, so it is always spelled the way the host
  /// spells paths, while the injected filesystem may be a memory one with a
  /// style of its own. Asking a posix-style context for the basename of
  /// `C:\...\bin\flutter.bat` returns the whole string, this guard does not
  /// fire, and the user gets a confusing complaint about absolute paths from
  /// [ShimWriter] instead of the one sentence that tells them what to do.
  bool _isFlutterVm(String path) {
    final segment = path.split(RegExp(r'[/\\]')).last;
    return segment == 'dart' || segment == 'dart.exe';
  }

  ShellFacts _shell() => ShellFacts(
        fileSystem: context.fileSystem,
        environment: context.environment,
      );

  /// The PATH line, named for the shell the user is actually in.
  ///
  /// [blocked] is the same fact [_writePathLine] refuses on, threaded through
  /// so the offer below cannot point at a flag that would decline.
  void _printPathInstructions(
    ShellFacts shell,
    List<Directory> directories,
    File binary, {
    required bool blocked,
  }) {
    final styles = context.styles;
    // Never hand out an instruction that is already in effect. A directory on
    // PATH right now needs no line, and a user told to add one reasonably
    // concludes fvm did not look. This is the ENVIRONMENT case;
    // [PathLineOutcome.alreadyPresent] is the file-contents one, and the two
    // can be true independently — a line in `.zprofile` puts the directory on
    // PATH without `.zshrc` mentioning it.
    final missing = [
      for (final directory in directories)
        if (!shell.isOnPath(directory)) directory,
    ];
    if (missing.isEmpty) {
      // PROSE about directories, so it is formatted for reading — the same
      // call [PathLineOutcome.alreadyPresent] makes just below. The PATH line
      // itself is built from `directory.path` and never from this.
      final names = directories.map((directory) => directory.path);
      context.out.writeln(
        styles.ok(
          directories.length == 1
              ? '${names.single} is already on your PATH, so there is nothing '
                  'to add.'
              : '${names.join(' and ')} are already on your PATH, so there is '
                  'nothing to add.',
        ),
      );
      return;
    }

    final line = shell.pathLine(missing);
    final rcFile = shell.primaryRcFile;

    if (shell.kind == ShellKind.powershell) {
      final session = missing.map((directory) => directory.path).join(';');
      context.out
        ..writeln(styles.heading('${shell.pathLineAction}:'))
        ..writeln()
        ..writeln('  ${styles.command(line)}')
        ..writeln()
        ..writeln(styles.detail(
          'That edits your user PATH, so it survives a reboot. It has '
          'to go ahead of anything else that puts a flutter on PATH, and it '
          'only takes effect in terminals opened after you run it.',
        ))
        ..writeln()
        ..writeln(styles.heading('For the terminal you are in right now:'))
        ..writeln()
        // ABSOLUTE, like every path this command prints: a relative entry on
        // PATH is resolved against whatever directory each process happens to
        // be in. See the note on [FvmContext.display] — `setup` names PATH
        // entries, startup files and the fvm home, and none of those may be
        // rendered relative to the working directory.
        ..writeln(
            '  ${styles.command("\$env:Path = '$session;' + \$env:Path")}');
      _explainOmittedBinDir(directories, binary);
      return;
    }

    if (rcFile == null) {
      // No HOME and no USERPROFILE: a container, or a hand-built environment.
      // There is no file to name, but the line is still the answer.
      context.out
        ..writeln(styles.heading('Add this to your shell startup file:'))
        ..writeln()
        ..writeln('  ${styles.command(line)}');
      _explainOmittedBinDir(directories, binary);
      return;
    }

    // Naming ONE file here is only honest when fvm knows the shell. When it
    // does not, and the home directory holds another shell's startup files,
    // saying "add this to ~/.profile" is the same wrong instruction
    // `--write-path-line` used to carry out — printed instead of written, and
    // just as certain to change nothing.
    if (shell.rcFileIsGuessed) {
      _printAmbiguousRcFile(shell, rcFile, line);
      _explainOmittedBinDir(directories, binary);
      return;
    }

    final verb = rcFile.existsSync() ? 'Add this line to' : 'Create';
    context.out
      ..writeln(styles.heading('$verb ${rcFile.path} '
          '(${shell.shellPath ?? 'no \$SHELL set, assuming '
              '${shell.kind.token}'}):'))
      ..writeln()
      ..writeln('  ${styles.command(line)}')
      ..writeln()
      ..writeln(styles.detail(
        'It has to go ahead of anything else that puts a flutter on '
        'PATH, and it only takes effect in shells started after you save '
        'the file.',
      ))
      ..writeln();

    // Only for a shell with a startup file fvm can name: the PowerShell and
    // no-rc-file branches above return before here, because `--write-path-line`
    // has nothing to write in either.
    if (blocked) {
      // The flag would refuse in this exact state, so pointing at it as the
      // next step would send the user to a guaranteed no-op. The shadow comes
      // first; the flag is what to run once it is gone.
      context.out
        ..writeln(styles.detail(
          'fvm could add that line for you, but not yet: something in '
          'your startup files would beat it, or fvm could not read a file '
          'that might — see the warnings below.',
        ))
        ..writeln('${styles.detail('Clear that first and start a new shell, '
                'then run: ')}'
            '${styles.command('fvm setup --write-path-line')}');
      _explainOmittedBinDir(directories, binary);
      return;
    }

    context.out
      ..writeln('${styles.detail('Or let fvm add it for you: ')}'
          '${styles.command('fvm setup --write-path-line')}')
      ..writeln(styles.detail('It backs ${rcFile.path} up before touching '
          'it, and '
          'fvm setup --remove-path-line takes the line back out.'));
    _explainOmittedBinDir(directories, binary);
  }

  /// Adds the PATH line to the startup file. Returns whether it got there.
  ///
  /// Unlike [_printPathInstructions] this does NOT drop a directory that is
  /// already on `$PATH` in this shell. The user asked for a line that persists,
  /// and an environment PATH does not: it can come from a shell the user
  /// exported by hand, or from a startup file that is not the one being
  /// edited. The file-contents check inside [PathLineEditor.install] is the
  /// right idempotency guard here, and it is the one that prevents a doubled
  /// entry.
  bool _writePathLine(
    ShellFacts shell,
    List<Directory> directories,
    File binary, {
    required bool blocked,
  }) {
    final styles = context.styles;
    final editor = _editorFor(shell, directories, guardGuessedRcFile: true);
    if (editor == null) return false;

    if (blocked) {
      // A refusal that makes `setup` exit 1: coloured like a doctor FAIL,
      // because it is the same news.
      context.err
        ..writeln(styles.fail(
          'Not writing the PATH line: something in your startup files '
          'would beat it, or fvm could not read a file that might. A shell '
          'function or alias is resolved before PATH is ever searched, so '
          'the line would change nothing while looking like it worked.',
        ))
        ..writeln(styles.detail(
          'Sort out the warnings below, then run this again.',
        ));
      return false;
    }

    final result = editor.install();
    switch (result.outcome) {
      case PathLineOutcome.alreadyPresent:
        context.out.writeln(
          styles.ok('${editor.rcFile.path} already puts '
              '${context.paths.shimsDir.path} on PATH '
              '(line ${result.line}), so there is nothing to add.'),
        );
        _reportPathLineNotInEffect(shell, editor.rcFile);
      case PathLineOutcome.created:
        context.out
          ..writeln(styles.heading('Created ${editor.rcFile.path} with:'))
          ..writeln()
          ..writeln('  ${styles.command(editor.line)}');
        _explainNextShell(editor);
        _explainOmittedBinDir(directories, binary);
      case PathLineOutcome.written:
        context.out
          ..writeln(styles.detail('Backed up ${editor.rcFile.path} '
              '-> ${result.backup!.path}'))
          ..writeln(
            styles.heading('Added this line to ${editor.rcFile.path}:'),
          )
          ..writeln()
          ..writeln('  ${styles.command(editor.line)}');
        _explainNextShell(editor);
        _explainOmittedBinDir(directories, binary);
      case PathLineOutcome.removed:
      case PathLineOutcome.foreign:
      case PathLineOutcome.absent:
        throw StateError('install() cannot report ${result.outcome}');
    }
    return true;
  }

  /// Prints the line without naming a file, when fvm cannot tell which file it
  /// belongs in.
  ///
  /// The line itself is still the answer and is still printed — the user knows
  /// which shell they are in, which is the one fact fvm is missing. What is
  /// withheld is the confident file name and the offer of
  /// `--write-path-line`, which would decline in this state anyway.
  void _printAmbiguousRcFile(ShellFacts shell, File rcFile, String line) {
    final styles = context.styles;
    final said = shell.shellPath;
    context.out
      ..writeln(styles.warn(said == null
          ? '\$SHELL is not set, so fvm cannot tell which startup file your '
              'shell reads.'
          : '\$SHELL says $said, which fvm does not recognise, so it cannot '
              'tell which startup file your shell reads.'))
      ..writeln(styles.detail(
        'These are here, and they belong to different shells:',
      ))
      ..writeln()
      ..writeln(styles.detail(
        '  ${rcFile.path}  (${shell.kind.token}, what fvm would have '
        'assumed)',
      ));
    for (final other in shell.otherShellRcFiles) {
      context.out.writeln(
        styles.detail('  ${other.file.path}  (${other.shell.token})'),
      );
    }
    context.out
      ..writeln()
      ..writeln(
        styles.heading('Add this line to the one your shell actually reads:'),
      )
      ..writeln()
      ..writeln('  ${styles.command(line)}')
      ..writeln()
      ..writeln(styles.detail(
        'It has to go ahead of anything else that puts a flutter on PATH, '
        'and it only takes effect in shells started after you save the file.',
      ))
      ..writeln()
      ..writeln('${styles.detail('Or name your shell and let fvm do it: ')}'
          '${styles.command('SHELL=<your shell> fvm setup '
              '--write-path-line')}');
  }

  /// Refuses to write, because the file fvm would write to is a guess the home
  /// directory contradicts.
  ///
  /// Refusing rather than writing-and-warning, and the difference matters. The
  /// artifact this bug leaves behind — a PATH line in a `.profile` nothing
  /// reads, plus a backup file beside it — is indistinguishable from a working
  /// one, and the NEXT run finds it and reports "there is nothing to add". So
  /// the machine is left clean and the user is left with one decision, spelled
  /// out as one command.
  void _refuseGuessedRcFile(
    ShellFacts shell,
    File rcFile,
    List<Directory> directories,
  ) {
    final styles = context.styles;
    final said = shell.shellPath;
    final others = shell.otherShellRcFiles;
    // The first one is the best suggestion: [ShellFacts] lists a shell's
    // primary file first, so this is `.zshrc` rather than `.zlogin`.
    final suggestion = others.first.shell;

    context.err
      ..writeln(styles.fail(
        'Not writing the PATH line: fvm cannot tell which startup file '
        'your shell reads.',
      ))
      ..writeln()
      ..writeln(styles.detail(said == null
          ? '\$SHELL is not set, so fvm assumed ${shell.kind.token} and would '
              'have written to ${rcFile.path}.'
          : '\$SHELL says $said, which fvm does not recognise, so it assumed '
              '${shell.kind.token} and would have written to ${rcFile.path}.'))
      ..writeln(styles.detail(
        'But these startup files are here too, and they belong to a '
        'shell that does not read it:',
      ))
      ..writeln();
    for (final other in others) {
      context.err.writeln(
        styles.detail('  ${other.file.path}  (${other.shell.token})'),
      );
    }
    context.err
      ..writeln()
      ..writeln(styles.detail(
        'Writing to ${rcFile.path} would look like it worked and put '
        'nothing on your PATH.',
      ))
      ..writeln()
      ..writeln(styles.heading('Name your shell and run this again:'))
      ..writeln()
      ..writeln(
        '  ${styles.command('SHELL=${suggestion.token} fvm setup '
            '--write-path-line')}',
      )
      ..writeln()
      ..writeln(styles.heading(
        'Or add this line to the startup file you actually use:',
      ))
      ..writeln()
      ..writeln('  ${styles.command(shell.pathLine(directories))}');
  }

  /// Says so when a PATH line that is already in the file is not in effect.
  ///
  /// This is the check that makes `setup` and `doctor` agree. `install()`
  /// answers a question about FILE CONTENTS — is the line in this file? — and
  /// on its own that is what turned a line in a `.profile` zsh never sources
  /// into a confident "there is nothing to add". Whether the directory is
  /// actually on PATH is a question about the ENVIRONMENT, and it is the one
  /// `doctor` is about to fail on.
  ///
  /// Deliberately honest about the two readings rather than picking one: fvm
  /// cannot tell "you have not opened a new shell yet" from "your shell does
  /// not read that file", and the second is only a likelihood, not a fact. Both
  /// are named, and the startup files belonging to another shell are listed
  /// when there are any, because that is the evidence pointing at the second.
  void _reportPathLineNotInEffect(ShellFacts shell, File rcFile) {
    final styles = context.styles;
    final shims = context.paths.shimsDir;
    if (shell.isOnPath(shims)) return;

    context.err
      ..writeln()
      ..writeln(styles.warn(
        'WARNING: that line is not in effect. ${shims.path} is not on '
        'the PATH of this shell, so `flutter` does not go through fvm right now '
        'and `fvm doctor` reports it as a problem.',
      ))
      ..writeln(styles.detail(
        'Either no new shell has been started since that line was '
        'added, or your shell does not read ${rcFile.path}.',
      ));
    for (final other in shell.otherShellRcFiles) {
      context.err.writeln(styles.detail('  ${other.file.path} is here too, and '
          '${other.shell.token} does not read ${rcFile.path}.'));
    }
    context.err.writeln('${styles.detail('Check with: ')}'
        '${styles.command('fvm doctor')}');
  }

  void _explainNextShell(PathLineEditor editor) {
    final styles = context.styles;
    context.out
      ..writeln()
      ..writeln('${styles.detail('It takes effect in shells started after '
              'this. For the one you are in: ')}'
          '${styles.command('source ${editor.rcFile.path}')}')
      ..writeln('${styles.detail('Undo it with: ')}'
          '${styles.command('fvm setup --remove-path-line')}');
  }

  /// Takes fvm's PATH line back out. Returns the command's exit code.
  int _removePathLine() {
    final styles = context.styles;
    final shell = _shell();
    // The shims directory alone: removal matches on fvm's markers and on the
    // shims path, never on [PathLineEditor.line], so there is no binary to
    // resolve — which is what lets `--remove-path-line` undo an install from a
    // source checkout.
    final editor = _editorFor(shell, [context.paths.shimsDir]);
    if (editor == null) return 1;

    final result = editor.remove();
    switch (result.outcome) {
      case PathLineOutcome.removed:
        context.out
          ..writeln(styles.detail('Backed up ${editor.rcFile.path} '
              '-> ${result.backup!.path}'))
          ..writeln(styles.heading('Removed fvm\'s PATH line from '
              '${editor.rcFile.path}.'))
          ..writeln(styles.detail(
            'Shells started after this will no longer find the shims. '
            'The shims themselves are still in '
            '${context.paths.shimsDir.path}.',
          ));
      case PathLineOutcome.foreign:
        // Reported rather than removed, and still a success: the file is in
        // the state the user put it in, and the one thing fvm knows for sure
        // is that it did not write this line.
        context.out
          ..writeln(styles.warn('${editor.rcFile.path} puts '
              '${context.paths.shimsDir.path} on PATH at '
              'line ${result.line}, but fvm did not write that line — there '
              'are no fvm markers around it — so it has been left as it is.'))
          ..writeln(
            styles.detail('Remove it by hand if you want it gone.'),
          );
      case PathLineOutcome.absent:
        context.out.writeln(
          styles.ok('There is no fvm PATH line in '
              '${editor.rcFile.path}, '
              'so there is nothing to remove.'),
        );
      case PathLineOutcome.written:
      case PathLineOutcome.created:
      case PathLineOutcome.alreadyPresent:
        throw StateError('remove() cannot report ${result.outcome}');
    }
    return 0;
  }

  /// An editor for the shell's startup file, or null once it has said why
  /// there is no file to edit.
  ///
  /// [guardGuessedRcFile] is for the callers that WRITE. `--remove-path-line`
  /// passes false on purpose: the file it undoes is the one an earlier fvm
  /// picked, and a guard that refuses to clean up the mess it is guarding
  /// against would strand every user who already has one.
  PathLineEditor? _editorFor(
    ShellFacts shell,
    List<Directory> directories, {
    bool guardGuessedRcFile = false,
  }) {
    final styles = context.styles;
    if (shell.kind == ShellKind.powershell) {
      context.err
        ..writeln(styles.detail(
          'PowerShell takes PATH from your environment rather than '
          'from a startup file, so there is no line for fvm to write. Run '
          'this once instead:',
        ))
        ..writeln()
        ..writeln('  ${styles.command(shell.pathLine(directories))}');
      return null;
    }

    final rcFile = shell.primaryRcFile;
    if (rcFile == null) {
      // No HOME and no USERPROFILE: a container, or a hand-built environment.
      // Guessing at a path here is how fvm would write to somewhere nobody
      // reads, so name the line and let the user place it.
      context.err
        ..writeln(styles.warn(
          'Neither \$HOME nor \$USERPROFILE is set, so fvm cannot tell '
          'which startup file is yours. Add this line to it yourself:',
        ))
        ..writeln()
        ..writeln('  ${styles.command(shell.pathLine(directories))}');
      return null;
    }

    if (guardGuessedRcFile && shell.rcFileIsGuessed) {
      _refuseGuessedRcFile(shell, rcFile, directories);
      return null;
    }

    return PathLineEditor(
      fileSystem: context.fileSystem,
      rcFile: rcFile,
      line: shell.pathLine(directories),
      // The shims path is what recognises a line that is already there, and it
      // stays the shims path even when [line] covers the bin directory too: it
      // is the entry every spelling of this instruction has carried, including
      // the ones written by earlier versions of fvm and by hand.
      shimsPath: context.paths.shimsDir.path,
      homePath: shell.home?.path,
      now: _now,
    );
  }

  /// Says loudly when something already on this machine will beat the shim.
  ///
  /// Returns whether anything was found. This is the case the maintainer's own
  /// machine is in: `~/.fvm` belongs to the older shell-based version manager, whose `fvm` is
  /// a *shell function* sourced from `.zshrc`. A function beats every binary on
  /// PATH, so without this warning the user installs fvm, types `fvm`, and gets
  /// the other tool with nothing to explain why.
  bool _reportConflicts(ShellScan scan) {
    final styles = context.styles;
    var found = false;

    if (scan.shadows.isNotEmpty) {
      found = true;
      context.err
        ..writeln()
        ..writeln(styles.warn(
          'WARNING: your shell defines its own `fvm`, which will win '
          'over the binary you just set up — a shell function or alias is '
          'resolved before PATH is ever searched.',
        ));
      for (final shadow in scan.shadows) {
        context.err.writeln(styles.detail('  ${shadow.describe()}'));
      }
      context.err.writeln(
        styles.detail(
          'Remove or comment out the line(s) above, then start a new shell.',
        ),
      );
    }

    for (final entry in scan.unreadable.entries) {
      // Not folded into "nothing found": a file we could not open may be
      // exactly the one with the function in it.
      found = true;
      context.err.writeln(
        styles.warn(
          'WARNING: could not read ${entry.key} (${entry.value}), so fvm '
          'cannot say whether it defines a conflicting `fvm`.',
        ),
      );
    }

    return found;
  }

  String _absolute(String path) {
    final fileSystem = context.fileSystem;
    if (fileSystem.path.isAbsolute(path)) return path;
    return fileSystem.path.normalize(
      fileSystem.path.join(context.workingDirectory.path, path),
    );
  }
}

/// Creates a missing shim after an SDK becomes available, without editing PATH.
Future<void> setupIfMissing(FvmContext context) async {
  final fs = context.fileSystem;
  if (fs.typeSync(context.paths.flutterShim.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    return;
  }
  final executable = context.executablePath;
  final name = executable.split(RegExp(r'[/\\]')).last;
  // A source invocation runs inside the Dart VM, which cannot launch FVM.
  if (executable.isEmpty || name == 'dart' || name == 'dart.exe') return;
  final binary = fs.file(executable);
  if (!fs.path.isAbsolute(executable) || !binary.existsSync()) return;

  await SetupCommand(context: context)._setup(binary, write: false);
}
