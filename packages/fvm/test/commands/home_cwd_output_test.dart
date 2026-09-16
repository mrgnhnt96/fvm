import 'package:fvm/fvm.dart';
import 'package:test/test.dart';

import 'harness.dart';

/// What `doctor` and `setup` print when the working directory is `$HOME`.
///
/// The case nobody tried. `FvmContext.display` renders a path relative when it
/// lies under the working directory, and that was approved on the reasoning
/// that `~/.fvm/shims` is "never under the working directory". Standing in
/// `$HOME` — which is exactly where people stand to run `fvm setup` and `fvm
/// doctor` — it is, so doctor printed `.fvm/shims is not on PATH` three lines
/// above the absolute `export PATH="/home/dev/.fvm/shims:$PATH"` that fixes it.
///
/// The rule these pin: a path that names a PATH ENTRY, a shell startup file, or
/// anything in the fvm home prints ABSOLUTE, wherever the user is standing.
/// Project files — `.fvmrc`, `.fvm/flutter_sdk` — keep the relative rendering, and
/// the last group here is the guard on that half.
void main() {
  late CommandHarness harness;

  const home = '/home/dev';
  const fvmHome = '$home/.fvm';
  const shims = '$fvmHome/shims';
  const binary = '$fvmHome/bin/fvm';

  /// A machine set up the way `install.sh` leaves one, with `$HOME` as the
  /// working directory and the fvm home inside it.
  void standInHome() {
    harness.environment['FVM_HOME'] = fvmHome;
    harness.environment['SHELL'] = '/bin/zsh';
    harness.fileSystem.directory(home).createSync(recursive: true);
    harness.fileSystem.currentDirectory = home;
    harness.fileSystem.file(binary)
      ..createSync(recursive: true)
      ..writeAsStringSync('a compiled binary');
    harness.fileSystem.file('$shims/flutter')
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\nexec "$binary" exec flutter "\$@"\n');
  }

  setUp(() => harness = CommandHarness());

  group('doctor, standing in \$HOME', () {
    test('names the PATH entry absolutely, in the same spelling as the fix',
        () async {
      standInHome();
      harness.environment['PATH'] = '/usr/bin';

      expect(await harness.run(['doctor']), 1);

      expect(harness.output, contains('$shims is not on PATH'));
      // The bug itself: the summary and the remedy naming one directory two
      // ways, three lines apart. A relative PATH entry is not merely ugly —
      // a shell resolves it against whatever directory each process is in.
      expect(harness.output,
          contains(r'export PATH="/home/dev/.fvm/shims:$PATH"'));
      expect(harness.output, isNot(contains(' .fvm/shims is not on PATH')));
    });

    test('names the shim and the fvm binary absolutely', () async {
      standInHome();
      harness.environment['PATH'] = shims;

      await harness.run(['doctor']);

      expect(harness.output, contains('$shims/flutter runs $binary.'));
      expect(harness.output, isNot(contains(' .fvm/shims/flutter runs')));
    });

    test('names the SDK store and config.json absolutely', () async {
      standInHome();
      harness.environment['PATH'] = shims;
      harness.fileSystem.file('$fvmHome/config.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"global":"3.13.2"}');

      expect(await harness.run(['doctor']), 1);

      expect(
          harness.output, contains('Nothing is at $fvmHome/versions/3.13.2'));
      expect(harness.output, isNot(contains('Nothing is at .fvm/versions')));
    });
  });

  group('setup, standing in \$HOME', () {
    test('names the shim, the binary and the startup file absolutely',
        () async {
      standInHome();

      expect(
        await harness.run(['setup', '--fvm-path', binary, '--write-path-line']),
        0,
      );

      expect(harness.output, contains('Wrote $shims/flutter'));
      expect(harness.output, contains('  -> $binary exec flutter'));
      expect(harness.output, contains('Created $home/.zshrc with:'));
      // `source .zshrc` is a command the user pastes. It happens to work from
      // $HOME and silently does the wrong thing from anywhere else.
      expect(harness.output, contains('source $home/.zshrc'));
      expect(harness.output, isNot(contains('source .zshrc')));
    });

    test('names the backup absolutely', () async {
      standInHome();
      harness.fileSystem.file('$home/.zshrc')
        ..createSync(recursive: true)
        ..writeAsStringSync('export EDITOR=vim\n');

      await harness.run(['setup', '--fvm-path', binary, '--write-path-line']);

      expect(
          harness.output,
          contains('Backed up $home/.zshrc -> $home/.zshrc'
              '.fvm-backup-'));
    });

    test('names both PATH directories absolutely in the line it prints',
        () async {
      standInHome();

      expect(await harness.run(['setup', '--fvm-path', binary]), 0);

      expect(harness.output, contains('Create $home/.zshrc'));
      expect(
        harness.output,
        contains(
            r'export PATH="/home/dev/.fvm/shims:/home/dev/.fvm/bin:$PATH"'),
      );
    });

    test('names the shims absolutely when it says they are already on PATH',
        () async {
      standInHome();
      harness.environment['PATH'] = '$shims:$fvmHome/bin';

      expect(await harness.run(['setup', '--fvm-path', binary]), 0);

      expect(harness.output,
          contains('$shims and $fvmHome/bin are already on your PATH'));
    });
  });

  /// The rest of the audit. `doctor` and `setup` were fixed by not CALLING
  /// `display`, which left the rule resting on every other call site
  /// remembering the same thing — and `install` did not. It printed
  /// `Installed Flutter 3.13.2 to .fvm/versions/3.13.2`, one directory spelled two
  /// ways depending on where the user was standing.
  ///
  /// These pin the rule at the call sites rather than only in
  /// `test/core/display_path_test.dart`, because a unit test of `display`
  /// cannot say whether a command routes a store path through it.
  group('every command names the fvm home absolutely, standing in \$HOME', () {
    test('install says where it put the SDK, absolutely', () async {
      standInHome();

      expect(await harness.run(['install', '3.13.2']), 0);

      // The reported bug, verbatim.
      expect(harness.output,
          contains('Installed Flutter 3.13.2 to $fvmHome/versions/3.13.2'));
      expect(harness.output, isNot(contains('to .fvm/versions/3.13.2')));
    });

    test('install says where an already-installed SDK is, absolutely',
        () async {
      standInHome();
      harness.installVersion('3.13.2');

      expect(await harness.run(['install', '3.13.2']), 0);

      expect(harness.output,
          contains('already installed at $fvmHome/versions/3.13.2'));
      expect(harness.output, isNot(contains('at .fvm/versions/3.13.2')));
    });

    test('list names the SDK store absolutely, empty or not', () async {
      standInHome();

      expect(await harness.run(['list']), 0);
      expect(harness.output, contains('installed in $fvmHome/versions'));

      harness.clearOutput();
      harness.installVersion('3.13.2');

      expect(await harness.run(['list']), 0);
      expect(harness.output, contains('SDKs in $fvmHome/versions'));
      expect(harness.output, isNot(contains(' .fvm/versions')));
    });

    test('remove names the directory it deleted absolutely', () async {
      standInHome();
      harness.installVersion('3.13.2');

      expect(await harness.run(['remove', '3.13.2']), 0);

      expect(harness.output,
          contains('Removed Flutter 3.13.2 ($fvmHome/versions/3.13.2)'));
    });

    test('global names config.json absolutely', () async {
      standInHome();
      harness.installVersion('3.13.2');

      expect(await harness.run(['global', '3.13.2']), 0);

      expect(harness.output, contains('$fvmHome/config.json'));
      expect(harness.output, isNot(contains(' .fvm/config.json')));
    });

    test('alias names config.json absolutely', () async {
      standInHome();
      harness.installVersion('3.13.2');
      await harness.run(['alias', 'work', '3.13.2']);
      harness.clearOutput();

      expect(await harness.run(['alias']), 0);

      expect(harness.output, contains('Aliases in $fvmHome/config.json'));
    });

    test('which names the SDK and config.json absolutely', () async {
      standInHome();
      harness.installVersion('3.13.2');
      harness.writeConfig(const FvmConfig(global: '3.13.2'));

      expect(await harness.run(['which']), 0);

      expect(harness.output, contains('SDK: $fvmHome/versions/3.13.2'));
      expect(harness.output, contains('$fvmHome/config.json'));
      expect(harness.output, isNot(contains('SDK: .fvm/versions')));
    });

    test('use names the SDK store absolutely and the project files relatively',
        () async {
      standInHome();
      harness.installVersion('3.13.2');

      expect(await harness.run(['use', '3.13.2']), 0);

      // One sentence carrying both halves of the rule: the symlink is a
      // project file and reads relative, its target is the store and does not.
      expect(harness.output,
          contains('.fvm/flutter_sdk -> $fvmHome/versions/3.13.2'));
      expect(harness.output, contains('.fvmrc -> commit this'));
      expect(harness.output, isNot(contains('-> .fvm/versions/3.13.2')));
    });
  });

  group('project files keep the relative rendering', () {
    // The half of the relative-path work that was right and must not regress.
    // A `.fvmrc` in `$HOME` is under the working directory in the sense the
    // rule is about — it is a file in the directory the reader is standing in.
    test('a .fvmrc in \$HOME still prints relative', () async {
      standInHome();
      harness.environment['PATH'] = shims;
      harness.fileSystem.file('$home/.fvmrc').writeAsStringSync('3.13.2\n');
      harness.paths.flutterExecutable(
        harness.fileSystem.directory('$fvmHome/versions/3.13.2'),
      )
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\n');

      expect(await harness.run(['doctor']), 0);

      expect(harness.output, contains('.fvmrc pins Flutter 3.13.2'));
      expect(harness.output, isNot(contains('$home/.fvmrc pins')));
    });

    test(
        'the .fvm/flutter_sdk symlink still prints relative, and its target does '
        'not', () async {
      standInHome();
      harness.environment['PATH'] = shims;
      final version = harness.fileSystem.directory('$fvmHome/versions/3.13.2');
      harness.paths.flutterExecutable(version)
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\n');
      harness.fileSystem.file('$home/.fvmrc').writeAsStringSync('3.13.2\n');
      harness.fileSystem.link('$home/.fvm/flutter_sdk');

      await harness.run(['use', '3.13.2']);
      harness.clearOutput();

      expect(await harness.run(['doctor']), 0);

      // The link is a project file and reads relative; what it POINTS AT is
      // the SDK store and reads absolute. Both in one sentence.
      expect(harness.output,
          contains('.fvm/flutter_sdk points at $fvmHome/versions/3.13.2.'));
    });
  });
}
