// An end-to-end smoke test for a COMPILED fvm on a REAL filesystem.
//
// `dart test` drives fvm against a `MemoryFileSystem`, which answers questions
// about path spelling and nothing else. A memory filesystem has no PATHEXT, no
// ACLs, no junctions, no `cmd.exe`, and it creates a symlink wherever it is
// asked to — so every question that is actually about the operating system is
// invisible to it. This script asks those questions instead: it compiles the
// binary, installs a real SDK from the archive, and runs the commands a person
// runs, checking what appeared on the console.
//
// Run it from the repository root:
//
//     dart run packages/fvm/tool/smoke_test.dart [--sdk-version 3.44.0]
//
// Every check runs even after an earlier one fails, and the summary at the end
// lists them all. One red CI job then reports every broken thing on that
// platform rather than only the first, which is the difference between one
// round trip to a Windows runner and six.
import 'dart:async';
import 'dart:io';

/// The SDK this installs when `--sdk-version` is not given.
///
/// Pinned rather than `stable`: the assertions quote the version back, and a
/// moving target would make a failure ambiguous between "fvm is broken" and
/// "the channel moved".
const String defaultSdkVersion = '3.44.0';

Future<void> main(List<String> arguments) async {
  final sdkVersion =
      _optionValue(arguments, '--sdk-version') ?? defaultSdkVersion;
  final repoRoot = Directory.current;
  final scratch = Directory.systemTemp.createTempSync('fvm-smoke-');
  final fvmHome = Directory('${scratch.path}${Platform.pathSeparator}home');
  final project = Directory('${scratch.path}${Platform.pathSeparator}project')
    ..createSync(recursive: true);

  final smoke = _Smoke(
    fvmHome: fvmHome,
    project: project,
    sdkVersion: sdkVersion,
  );

  stdout.writeln('== fvm smoke test ==');
  stdout.writeln('platform    ${Platform.operatingSystem} '
      '(${Platform.operatingSystemVersion})');
  stdout.writeln('dart        ${Platform.version}');
  stdout.writeln('scratch     ${scratch.path}');
  stdout.writeln('sdk version $sdkVersion');
  stdout.writeln('');

  try {
    final binary = await smoke.compile(repoRoot, scratch);
    if (binary == null) {
      stdout.writeln('Compiling fvm failed, so nothing else could be run.');
    } else {
      await smoke.runChecks(binary);
    }
  } finally {
    smoke.report();
    _deleteQuietly(scratch);
  }

  // `exitCode`, not `return`: the Dart VM ignores what `main` returns, so a
  // script that returned 1 here would report every failure it found and then
  // exit 0, and CI would go green on a red smoke test. That is exactly what
  // this script did on its first run.
  exitCode = smoke.failed ? 1 : 0;
}

/// The checks, and what each of them observed.
class _Smoke {
  _Smoke({
    required this.fvmHome,
    required this.project,
    required this.sdkVersion,
  });

  final Directory fvmHome;
  final Directory project;
  final String sdkVersion;

  final List<_Result> _results = <_Result>[];

  bool get failed => _results.any((result) => !result.ok);

  /// `fvm.exe` on Windows, `fvm` everywhere else.
  static String get _fvmName => Platform.isWindows ? 'fvm.exe' : 'fvm';

  /// Builds the binary under test. Returns null when the build itself failed.
  Future<File?> compile(Directory repoRoot, Directory scratch) async {
    final output = File('${scratch.path}${Platform.pathSeparator}$_fvmName');
    final result = await _run(
      'compile fvm',
      Platform.resolvedExecutable,
      <String>[
        'compile',
        'exe',
        'packages/fvm/bin/fvm.dart',
        '-o',
        output.path,
      ],
      workingDirectory: repoRoot.path,
    );
    if (!result.ok || !output.existsSync()) return null;
    return output;
  }

  Future<void> runChecks(File fvm) async {
    _reportSymlinkPrivilege();
    await _version(fvm);
    await _setup(fvm);
    final installed = await _install(fvm);
    await _unknownVersion(fvm);
    await _list(fvm);
    await _use(fvm);
    await _which(fvm);
    await _flutter(fvm);
    await _exec(fvm);
    await _shim(fvm);
    await _replaceRunningBinary(fvm);
    await _doctor(fvm);
    // Last of all, because it deletes the SDK every check above needs.
    await _remove(fvm);
    if (!installed) {
      stdout.writeln(
        'NOTE: the SDK install failed, so every check after it was asking a '
        'question that could not be answered. Read the install failure first.',
      );
    }
  }

  /// Says whether THIS machine can create a plain directory symlink.
  ///
  /// Reported rather than asserted, and it is the reason `fvm use` does not
  /// simply call `Link.createSync` on Windows. Creating a symlink there needs
  /// either Developer Mode or an elevated process, and a CI runner is not
  /// evidence about a stock machine in either direction: an elevated runner
  /// would go green on a call that fails for the user, and an unelevated one
  /// would go red on a call that works for a developer with Developer Mode on.
  /// So this line exists to say WHICH kind of machine produced the log below.
  void _reportSymlinkPrivilege() {
    final target = Directory(
      '${project.path}${Platform.pathSeparator}symlink-probe-target',
    )..createSync(recursive: true);
    final link = Link(
      '${project.path}${Platform.pathSeparator}symlink-probe',
    );
    String verdict;
    try {
      link.createSync(target.path);
      verdict = 'yes';
      link.deleteSync();
    } on FileSystemException catch (error) {
      verdict = 'no (${error.osError?.message ?? error.message})';
    }
    target.deleteSync(recursive: true);
    stdout.writeln('--- can this machine create a plain directory symlink?');
    stdout.writeln(verdict);
    stdout.writeln('');
  }

  Future<void> _version(File fvm) async {
    final result = await _fvm(fvm, 'fvm --version', <String>['--version']);
    _expect(result, contains: 'fvm ');
  }

  Future<void> _setup(File fvm) async {
    // The exit code is deliberately not asserted. `setup` returns 1 when
    // something on THIS machine will shadow the shim -- a `fvm` shell function
    // in a startup file, an older cbracken/fvm in the same home -- which is a
    // fact about the machine, not about fvm. A clean runner exits 0; the
    // maintainer's own laptop exits 1 and is right to.
    final result = await _fvm(
      fvm,
      'fvm setup',
      <String>['setup', '--fvm-path', fvm.path],
      expectedExitCode: null,
    );
    _expect(result, contains: 'Wrote ');

    // The shim is the whole PATH integration, and its NAME is platform
    // specific: a `flutter` with no extension is not executable on Windows.
    final shim = File(
      <String>[
        fvmHome.path,
        'shims',
        Platform.isWindows ? 'flutter.bat' : 'flutter',
      ].join(Platform.pathSeparator),
    );
    _record(
      'the shim exists at ${shim.path}',
      shim.existsSync(),
      shim.existsSync() ? shim.readAsStringSync() : 'no such file',
    );
  }

  Future<bool> _install(File fvm) async {
    final result = await _fvm(
      fvm,
      'fvm install $sdkVersion',
      <String>['install', sdkVersion],
    );
    return _expect(result, contains: sdkVersion);
  }

  Future<void> _list(File fvm) async {
    final result = await _fvm(fvm, 'fvm list', <String>['list']);
    _expect(result, contains: sdkVersion);
  }

  Future<void> _use(File fvm) async {
    final result = await _fvm(
      fvm,
      'fvm use $sdkVersion',
      <String>['use', sdkVersion],
      workingDirectory: project.path,
    );
    _expect(result, contains: 'Pinned Flutter $sdkVersion');

    // The canonical form is `{"flutter": "<version>"}`; a bare version is only
    // ever ACCEPTED on read, never written.
    final rc = File('${project.path}${Platform.pathSeparator}.fvmrc');
    final written = rc.existsSync() ? rc.readAsStringSync() : '';
    _record(
      '.fvmrc pins $sdkVersion',
      written.contains('"flutter"') && written.contains('"$sdkVersion"'),
      rc.existsSync() ? written.trim() : 'no .fvmrc',
    );

    // Reached THROUGH the link, which is the only thing an IDE does with it.
    // A symlink and a junction are indistinguishable from here, and that is
    // the point: what matters is that the SDK is reachable at this path.
    final linked = File(
      <String>[
        project.path,
        '.fvm',
        'flutter_sdk',
        'bin',
        Platform.isWindows ? 'flutter.bat' : 'flutter',
      ].join(Platform.pathSeparator),
    );
    _record(
      '.fvm/flutter_sdk reaches the SDK',
      linked.existsSync(),
      linked.existsSync() ? linked.path : 'nothing at ${linked.path}',
    );

    // Again, over the link that is already there. Replacing a link is a
    // different operation from creating one, and on Windows the thing being
    // replaced may be a junction rather than a symlink.
    final again = await _fvm(
      fvm,
      'fvm use $sdkVersion, over the link already there',
      <String>['use', sdkVersion],
      workingDirectory: project.path,
    );
    _expect(again, contains: 'Pinned Flutter $sdkVersion');
    _record(
      '.fvm/flutter_sdk still reaches the SDK after a second pin',
      linked.existsSync(),
      linked.existsSync() ? linked.path : 'nothing at ${linked.path}',
    );
  }

  Future<void> _which(File fvm) async {
    final result = await _fvm(
      fvm,
      'fvm which',
      <String>['which'],
      workingDirectory: project.path,
    );
    _expect(result, contains: sdkVersion);

    final path = await _fvm(
      fvm,
      'fvm which --path',
      <String>['which', '--path'],
      workingDirectory: project.path,
    );
    final named = path.stdout.trim();
    _record(
      'fvm which --path names a file that exists',
      named.isNotEmpty && File(named).existsSync(),
      named.isEmpty ? '(printed nothing)' : named,
    );
  }

  Future<void> _flutter(File fvm) async {
    final result = await _fvm(
      fvm,
      'fvm flutter --version',
      <String>['flutter', '--version'],
      workingDirectory: project.path,
    );
    _expect(result, contains: 'Flutter $sdkVersion');
  }

  Future<void> _exec(File fvm) async {
    final result = await _fvm(
      fvm,
      'fvm exec flutter --version',
      <String>['exec', 'flutter', '--version'],
      workingDirectory: project.path,
    );
    _expect(result, contains: 'Flutter $sdkVersion');

    // A launcher has to answer the way the thing it stands in for answers.
    final missing = await _fvm(
      fvm,
      'fvm exec no-such-command',
      <String>['exec', 'definitely-not-a-real-command'],
      workingDirectory: project.path,
      expectedExitCode: 127,
    );
    _record(
      'fvm exec returns 127 for a command that is not there',
      missing.exitCode == 127,
      'exit ${missing.exitCode}',
    );

    // The exit code of the CHILD, not of fvm. A version manager that turns a
    // failing build into a passing one breaks every CI downstream of it.
    final failing = await _fvm(
      fvm,
      'fvm flutter (a script that exits 3)',
      <String>['dart', 'run', _exitScript().path],
      workingDirectory: project.path,
      expectedExitCode: 3,
    );
    _record(
      'the child exit code is forwarded',
      failing.exitCode == 3,
      'exit ${failing.exitCode}',
    );
  }

  /// Runs the shim the way a shell resolves it, with the shims directory on
  /// PATH and only the bare word `flutter` typed.
  Future<void> _shim(File fvm) async {
    final shims = '${fvmHome.path}${Platform.pathSeparator}shims';
    final separator = Platform.isWindows ? ';' : ':';
    final path = '$shims$separator${Platform.environment['PATH'] ?? ''}';
    // FVM_HOME travels WITH the PATH override. Without it the shim's fvm reads
    // the real ~/.fvm, finds nothing installed, and reports the pin as
    // uninstalled -- a failure that looks like a resolution bug and is really
    // the harness handing the child half an environment.
    final environment = <String, String>{
      'PATH': path,
      if (Platform.isWindows) 'Path': path,
      'FVM_HOME': fvmHome.path,
    };

    if (Platform.isWindows) {
      // cmd.exe finds `flutter.bat` through PATHEXT; nothing on the command line
      // says `.bat`, which is the whole question.
      final viaCmd = await _run(
        'flutter --version through cmd.exe',
        'cmd.exe',
        <String>['/c', 'flutter', '--version'],
        workingDirectory: project.path,
        environment: environment,
      );
      _expect(viaCmd, contains: 'Flutter $sdkVersion');

      final viaPowerShell = await _run(
        'flutter --version through PowerShell',
        'powershell.exe',
        <String>['-NoProfile', '-Command', 'flutter --version'],
        workingDirectory: project.path,
        environment: environment,
      );
      _expect(viaPowerShell, contains: 'Flutter $sdkVersion');
      return;
    }

    final viaSh = await _run(
      'flutter --version through sh',
      'sh',
      <String>['-c', 'flutter --version'],
      workingDirectory: project.path,
      environment: environment,
    );
    _expect(viaSh, contains: 'Flutter $sdkVersion');
  }

  /// Puts ARCHITECTURE.md's claim about `fvm update` in front of the OS.
  ///
  /// It says POSIX can `rename` over a running executable because the inode
  /// stays alive, and that Windows cannot replace a running `.exe` and needs
  /// the old one renamed aside first. `Updater` is built entirely on that
  /// distinction and it had never been executed on either platform -- the
  /// updater's own tests run against a memory filesystem, where nothing is
  /// ever really running.
  ///
  /// So this runs a copy of fvm, keeps it running, and tries both.
  Future<void> _replaceRunningBinary(File fvm) async {
    final directory = Directory(
      '${project.path}${Platform.pathSeparator}update',
    )..createSync(recursive: true);
    final running = fvm.copySync(
      '${directory.path}${Platform.pathSeparator}$_fvmName',
    );

    // A child that stays alive long enough to be replaced underneath, waits to
    // be told to go, and exits on its own after thirty seconds if anything
    // here goes wrong.
    //
    // Told rather than timed, because being told is what lets the check that
    // follows this one KNOW the child is gone. It runs `flutter` out of the SDK
    // that `_remove` deletes a few checks later, and Windows will not delete a
    // file a program is running -- so a child that merely sleeps for a fixed
    // half-minute fails `fvm remove` for a reason that has nothing to do with
    // `fvm remove`. It did: CI run 33284815252 on windows-latest, where all
    // five `fvm remove` checks failed on ERROR_ACCESS_DENIED.
    final ready = '${directory.path}${Platform.pathSeparator}ready';
    final stop = '${directory.path}${Platform.pathSeparator}stop';
    final done = '${directory.path}${Platform.pathSeparator}done';
    final sleeper = File('${directory.path}${Platform.pathSeparator}wait.dart')
      ..writeAsStringSync(
        "import 'dart:io';\n\n"
        'Future<void> main() async {\n'
        "  File(r'$ready').writeAsStringSync('up');\n"
        "  final stop = File(r'$stop');\n"
        '  for (var i = 0; i < 300 && !stop.existsSync(); i++) {\n'
        '    await Future<void>.delayed(const Duration(milliseconds: 100));\n'
        '  }\n'
        "  File(r'$done').writeAsStringSync('out');\n"
        '}\n',
      );

    stdout.writeln('--- replacing a RUNNING fvm binary');
    final process = await Process.start(
      running.path,
      <String>['dart', 'run', sleeper.path],
      workingDirectory: project.path,
      environment: <String, String>{'FVM_HOME': fvmHome.path},
      mode: ProcessStartMode.detachedWithStdio,
    );
    // Drained rather than read: a child whose pipe fills up stops, and this
    // one is meant to sit still until it is replaced underneath.
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());

    final readyFile = File(ready);
    for (var i = 0; i < 300 && !readyFile.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!readyFile.existsSync()) {
      await _stopTheRunningCopy(process, stop: stop, done: done);
      _record(
        'a copy of fvm was running to be replaced',
        false,
        'the child never came up',
      );
      return;
    }

    // The way an unaware updater would do it.
    String? overwriteFailure;
    try {
      running.writeAsBytesSync(const <int>[0], flush: true);
    } on FileSystemException catch (error) {
      overwriteFailure = error.osError?.message ?? error.message;
    }
    // REPORTED, not asserted, and the reason is that the three platforms give
    // three different answers: Linux refuses with "Text file busy", Windows
    // refuses with "being used by another process", and macOS allows it. An
    // updater that wrote in place would therefore work on the machine of
    // whoever wrote it and fail for two thirds of its users -- which is why
    // `Updater` renames on every platform instead, and why the check below is
    // the one that has to pass.
    stdout.writeln(
      'overwriting it in place: ${overwriteFailure ?? 'allowed'}',
    );

    // The way Updater does it: aside, then into place.
    final incoming = File('${running.path}.new');
    fvm.copySync(incoming.path);
    String? replaceFailure;
    try {
      if (Platform.isWindows) {
        running.renameSync('${running.path}.old');
      }
      incoming.renameSync(running.path);
    } on FileSystemException catch (error) {
      replaceFailure = error.osError?.message ?? error.message;
    }
    stdout.writeln('renaming a new one into place: '
        '${replaceFailure ?? 'ok'}');
    _record(
      'a new binary can be renamed into place while the old one runs',
      replaceFailure == null,
      replaceFailure ?? 'ok',
    );

    await _stopTheRunningCopy(process, stop: stop, done: done);

    // The point of all of it: what is at that path now has to RUN.
    final replaced = await _fvm(
      File(running.path),
      'the replaced binary runs',
      <String>['--version'],
    );
    _expect(replaced, contains: 'fvm ');
    stdout.writeln('');
  }

  /// Stops the child [_replaceRunningBinary] started, and everything it
  /// started.
  ///
  /// [process] is the fvm copy. The `flutter` it spawned out of the installed SDK
  /// is a GRANDCHILD, and killing a parent does not kill a grandchild on any
  /// platform -- so `process.kill()` on its own leaves an SDK binary running.
  /// That is what broke `fvm remove` on windows-latest in CI run 33284815252:
  /// Windows will not delete a file a program is running, so `remove` came
  /// back with ERROR_ACCESS_DENIED on a `flutter.bat` this check had orphaned,
  /// half a second earlier, and every one of its five assertions failed.
  ///
  /// So the child is asked to leave and then WAITED FOR. `Process.exitCode` is
  /// no help here: a process started detached has no parent left to report it
  /// to, so the handshake goes through files.
  Future<void> _stopTheRunningCopy(
    Process process, {
    required String stop,
    required String done,
  }) async {
    File(stop).writeAsStringSync('stop');

    final left = File(done);
    for (var i = 0; i < 100 && !left.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    // Belt and braces, and the only thing that helps if the child never read
    // its stop file.
    process.kill();

    // `done` is written just BEFORE the VM shuts down, so the executable can
    // still be mapped for a moment after it appears -- and being mapped is the
    // entire problem. Neither Windows nor Linux will open a running executable
    // for writing, so a write handle that opens is that `flutter` really being
    // finished with. Append mode, so the probe cannot alter a byte of the SDK
    // the checks below run against.
    final sdkFlutter = File(
      <String>[
        fvmHome.path,
        'versions',
        sdkVersion,
        'bin',
        Platform.isWindows ? 'flutter.bat' : 'flutter',
      ].join(Platform.pathSeparator),
    );
    if (!sdkFlutter.existsSync()) return;
    for (var i = 0; i < 100; i++) {
      try {
        sdkFlutter.openSync(mode: FileMode.append).closeSync();
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    stdout.writeln(
      'NOTE: ${sdkFlutter.path} was still held ten seconds after the child was '
      'told to stop, so the checks below run against an SDK something else is '
      'using.',
    );
  }

  /// The failure path: a version that is not published anywhere.
  ///
  /// Every other check here asks whether fvm works when handed something it
  /// can do. This one asks what a user sees when they typo a version, which is
  /// the more common experience and the easiest one to regress -- an unhandled
  /// exception here would print a stack trace and exit 255, and no check that
  /// only ever passes good input would notice.
  ///
  /// The unit suite covers this ground against a fake archive server. What it
  /// cannot cover is that the REAL archive still answers 404 for an absent
  /// version: if it ever served a friendly HTML page instead, `channelFor`
  /// would take its non-404 branch and the message below would change without
  /// a line of fvm changing. Costs three 404s and no download.
  Future<void> _unknownVersion(File fvm) async {
    const absent = '99.99.99';
    final result = await _fvm(
      fvm,
      'fvm install $absent',
      <String>['install', absent],
      expectedExitCode: 1,
    );
    // Both halves, deliberately. What makes an error actionable is the
    // sentence saying what to do next, and that is the half most likely to be
    // lost to a well-meaning rewording of the first.
    _expect(result, contains: 'Flutter $absent is not published for');
    _expect(
      result,
      contains: 'Run `fvm list-remote` to see what is available.',
    );
    _record(
      'fvm install $absent exits 1 rather than crashing',
      result.exitCode == 1,
      'exit ${result.exitCode}',
    );
  }

  /// `fvm remove`, against a real cache directory.
  ///
  /// Deleting a tree in a `MemoryFileSystem` cannot fail the way deleting a
  /// real one can. This SDK was extracted from an archive and then EXECUTED a
  /// few checks ago, so on Windows the question is whether anything still
  /// holds a handle on a binary that just ran -- which is precisely the case a
  /// memory filesystem has no way to represent.
  Future<void> _remove(File fvm) async {
    final result = await _fvm(
      fvm,
      'fvm remove $sdkVersion',
      <String>['remove', sdkVersion],
      workingDirectory: project.path,
    );
    _expect(result, contains: 'Removed Flutter $sdkVersion');

    // A `.fvmrc` is project data, not machine state, so it never blocks the
    // removal -- but the user is about to hit an error in this very directory,
    // and hearing it from the command that caused it is part of the contract.
    _expect(result, contains: 'pins the version just removed');

    // Really gone, not merely reported gone. `remove` printing its success
    // line is an assertion about fvm's control flow; this is one about disk.
    final versionDir = Directory(
      <String>[
        fvmHome.path,
        'versions',
        sdkVersion,
      ].join(Platform.pathSeparator),
    );
    _record(
      'the SDK directory is gone from the cache',
      !versionDir.existsSync(),
      versionDir.existsSync() ? 'still at ${versionDir.path}' : 'gone',
    );

    // And fvm agrees with the disk. A delete that left fvm still offering the
    // version would pass the check above and strand the next `fvm use`.
    final list = await _fvm(
      fvm,
      'fvm list, after the remove',
      <String>['list'],
    );
    _record(
      'fvm list no longer offers $sdkVersion',
      !list.output.contains(sdkVersion),
      list.output.trim().isEmpty ? '(printed nothing)' : list.output.trim(),
    );
  }

  Future<void> _doctor(File fvm) async {
    // Doctor reports, so its exit code is a verdict about the machine rather
    // than about fvm. What is asserted is that it ran and said something.
    final result = await _fvm(
      fvm,
      'fvm doctor',
      <String>['doctor'],
      workingDirectory: project.path,
      expectedExitCode: null,
    );
    _record(
      'fvm doctor produced a report',
      result.output.trim().isNotEmpty,
      'exit ${result.exitCode}',
    );
  }

  /// A tiny Dart program whose only job is to exit non-zero.
  File _exitScript() {
    final file = File('${project.path}${Platform.pathSeparator}exit3.dart');
    if (!file.existsSync()) {
      file.writeAsStringSync(
        "import 'dart:io';\n\nvoid main() => exit(3);\n",
      );
    }
    return file;
  }

  /// Runs fvm with the scratch home, never the real `~/.fvm`.
  Future<_Result> _fvm(
    File fvm,
    String label,
    List<String> arguments, {
    String? workingDirectory,
    int? expectedExitCode = 0,
  }) =>
      _run(
        label,
        fvm.path,
        // The update check is a network round trip to GitHub that says nothing
        // about the platform and can fail for reasons of its own.
        <String>[...arguments, '--no-version-check'],
        workingDirectory: workingDirectory,
        environment: <String, String>{'FVM_HOME': fvmHome.path},
        expectedExitCode: expectedExitCode,
      );

  Future<_Result> _run(
    String label,
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    int? expectedExitCode = 0,
  }) async {
    stdout.writeln('--- $label');
    stdout.writeln('\$ $executable ${arguments.join(' ')}');
    final ProcessResult process;
    try {
      process = await Process.run(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        runInShell: false,
      );
    } on ProcessException catch (error) {
      stdout.writeln('could not start: ${error.message}');
      final result = _Result(label, -1, '', 'could not start: $error');
      _record(label, false, 'could not start: ${error.message}');
      return result;
    }

    final result = _Result(
      label,
      process.exitCode,
      '${process.stdout}',
      '${process.stderr}',
    );
    stdout.writeln(result.output.trimRight());
    stdout.writeln('exit ${result.exitCode}');
    stdout.writeln('');

    if (expectedExitCode != null && result.exitCode != expectedExitCode) {
      _record(
        '$label exits $expectedExitCode',
        false,
        'exit ${result.exitCode}',
      );
    }
    return result;
  }

  /// Asserts on what the command PRINTED. An exit code of zero says a process
  /// ended; it does not say it did the thing.
  bool _expect(_Result result, {required String contains}) {
    final ok = result.output.contains(contains);
    _record(
      '${result.label} says "$contains"',
      ok,
      ok ? 'found' : 'not in ${result.output.length} bytes of output',
    );
    return ok;
  }

  void _record(String what, bool ok, String detail) {
    _results.add(_Result.check(what, ok, detail));
  }

  void report() {
    stdout.writeln('');
    stdout.writeln('== summary (${Platform.operatingSystem}) ==');
    for (final result in _results) {
      stdout.writeln('${result.ok ? 'ok  ' : 'FAIL'}  ${result.label}'
          '${result.ok ? '' : '  <- ${result.detail}'}');
    }
    final bad = _results.where((result) => !result.ok).length;
    stdout.writeln('');
    stdout.writeln(
      bad == 0
          ? '${_results.length} checks, all passed.'
          : '${_results.length} checks, $bad failed.',
    );
  }
}

/// One command that ran, or one check that was made about the result.
class _Result {
  _Result(this.label, this.exitCode, this.stdout, this.stderr)
      : ok = true,
        detail = '';

  _Result.check(this.label, this.ok, this.detail)
      : exitCode = 0,
        stdout = '',
        stderr = '';

  final String label;
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool ok;
  final String detail;

  /// Both streams. `flutter --version` has moved between them across SDKs, and a
  /// check that read only one would pass or fail on that alone.
  String get output => '$stdout$stderr';
}

String? _optionValue(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index == -1 || index + 1 >= arguments.length) return null;
  return arguments[index + 1];
}

void _deleteQuietly(Directory directory) {
  try {
    directory.deleteSync(recursive: true);
  } on FileSystemException {
    // A leftover temp directory on a CI runner costs nothing, and failing the
    // smoke test on cleanup would report a problem that is not there.
  }
}
