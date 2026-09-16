import 'package:fvm/fvm.dart';
import 'package:test/test.dart';

import 'harness.dart';

/// `which` is the debugging tool for the whole resolution contract, so every
/// one of the five rules in ARCHITECTURE.md gets a test that checks it names
/// the right rule — not just that it printed a path.
void main() {
  late CommandHarness harness;

  setUp(() => harness = CommandHarness());

  test('rule 1: FVM_FLUTTER_VERSION in the environment', () async {
    harness
      ..installVersion('3.9.0')
      ..environment['FVM_FLUTTER_VERSION'] = '3.9.0';

    expect(await harness.run(['which']), 0);

    expect(harness.output, contains('/fvm/versions/3.9.0/bin/flutter'));
    expect(harness.output, contains('rule 1 of 5'));
    expect(harness.output, contains('FVM_FLUTTER_VERSION'));
  });

  test('rule 2: the nearest .fvmrc', () async {
    harness.installVersion('3.9.0');
    await harness.run(['use', '3.9.0']);
    harness.clearOutput();

    expect(await harness.run(['which']), 0);

    expect(harness.output, contains('rule 2 of 5'));
    // Relative: the .fvmrc is in the working directory. The first line, the
    // one `fvm which | head -1` takes, stays absolute — pinned separately
    // below in "the machine-readable paths stay absolute".
    expect(harness.output, contains('pinned by .fvmrc'));
    expect(harness.output, isNot(contains('pinned by /project/.fvmrc')));
  });

  test('rule 2 finds a .fvmrc in a parent directory', () async {
    harness.installVersion('3.9.0');
    harness.fileSystem.file('/project/.fvmrc').writeAsStringSync('3.9.0');
    harness.fileSystem
        .directory('/project/packages/app')
        .createSync(recursive: true);
    harness.fileSystem.currentDirectory = '/project/packages/app';

    expect(await harness.run(['which']), 0);
    // ABSOLUTE, and this is the point of the test: the governing .fvmrc is
    // ABOVE the working directory, so it is not under it and the display rule
    // leaves it alone. Nobody should later "fix" this into `../..`.
    expect(harness.output, contains('pinned by /project/.fvmrc'));
  });

  test('rule 3: the global default', () async {
    harness
      ..installVersion('3.13.2')
      ..writeConfig(const FvmConfig(global: '3.13.2'));

    expect(await harness.run(['which']), 0);

    expect(harness.output, contains('rule 3 of 5'));
    expect(harness.output, contains('global default'));
    expect(harness.output, contains('/fvm/config.json'));
  });

  test('rule 4: the next flutter on PATH', () async {
    harness.putFlutterOnPath();

    expect(await harness.run(['which']), 0);

    expect(harness.output, contains('/usr/bin/flutter'));
    expect(harness.output, contains('rule 4 of 5'));
    expect(harness.output, contains('not managed by fvm'));
  });

  test('rule 5: nothing applies, and it says what to run', () async {
    expect(await harness.run(['which']), 1);

    expect(harness.errors, contains('No Flutter SDK applies'));
    expect(harness.errors, contains('FVM_FLUTTER_VERSION is not set'));
    expect(harness.errors, contains('no .fvmrc'));
    expect(harness.errors, contains('fvm use <version>'));
  });

  test('a .fvmrc naming an alias explains the hop', () async {
    harness
      ..installVersion('3.9.0')
      ..writeConfig(const FvmConfig(aliases: {'work': '3.9.0'}));
    harness.fileSystem.file('/project/.fvmrc').writeAsStringSync('work');

    expect(await harness.run(['which']), 0);

    expect(harness.output, contains('rule 2 of 5'));
    expect(harness.output, contains('an alias for 3.9.0'));
  });

  test('a .fvmrc naming a channel explains where the version came from',
      () async {
    harness
      ..installVersion('3.13.2')
      ..writeConfig(const FvmConfig(channels: {'stable': '3.13.2'}));
    harness.fileSystem.file('/project/.fvmrc').writeAsStringSync('stable');

    expect(await harness.run(['which']), 0);
    expect(harness.output, contains('the channel that was recorded as 3.13.2'));
  });

  test('--path prints only the executable, for scripting', () async {
    harness
      ..installVersion('3.9.0')
      ..writeConfig(const FvmConfig(global: '3.9.0'));

    expect(await harness.run(['which', '--path']), 0);
    expect(harness.output.trim(), '/fvm/versions/3.9.0/bin/flutter');
  });

  group("which's machine-readable paths stay absolute", () {
    /// The carve-out from the relative-path display rule, and the reason it
    /// exists: these two lines are captured by scripts and IDEs, which run
    /// with a working directory of their own. A relative path resolves against
    /// the CALLER's directory rather than fvm's, so a consumer handed
    /// `.fvm/flutter_sdk/bin/flutter` silently points at nothing. Every other path
    /// `which` prints is prose for a human and follows the normal rule.
    ///
    /// The SDK is pinned INSIDE the working directory here on purpose: that is
    /// the one arrangement where the display rule would fire, so a test using
    /// the usual `/fvm/versions/...` store could not tell the carve-out from
    /// a path that was simply never under the working directory.
    void sdkInsideTheWorkingDirectory() {
      const inside = '/project/sdk/3.9.0';
      harness.paths.flutterExecutable(harness.fileSystem.directory(inside))
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\n');
      harness.environment['FVM_HOME'] = '/project/sdk-home';
      harness.fileSystem
          .directory('/project/sdk-home/versions')
          .createSync(recursive: true);
      harness.fileSystem
          .link('/project/sdk-home/versions/3.9.0')
          .createSync(inside);
      harness.writeConfig(const FvmConfig(global: '3.9.0'));
    }

    test(
        '--path prints an absolute path even when the SDK is under the '
        'working directory', () async {
      sdkInsideTheWorkingDirectory();

      expect(await harness.run(['which', '--path']), 0);

      final printed = harness.output.trim();
      expect(printed, startsWith('/'),
          reason: 'a script capturing this resolves it from its own directory');
      expect(printed, '/project/sdk-home/versions/3.9.0/bin/flutter');
    });

    test(
        'the first line of default output — what `fvm which | head -1` '
        'takes — is absolute too', () async {
      sdkInsideTheWorkingDirectory();

      expect(await harness.run(['which']), 0);

      final firstLine = harness.output.split('\n').first;
      expect(firstLine, startsWith('/'));
      expect(firstLine, '/project/sdk-home/versions/3.9.0/bin/flutter');
    });

    test('the human-readable SDK: line names the store, so it is absolute too',
        () async {
      sdkInsideTheWorkingDirectory();

      expect(await harness.run(['which']), 0);

      // This line USED to read `SDK: sdk-home/versions/3.9.0`, because the fvm
      // home was contrived to sit inside the working directory and the display
      // rule relativized whatever was under it. That is the same defect as
      // `Installed Flutter 3.13.2 to .fvm/versions/3.13.2`: the SDK STORE printing
      // relative because of where the reader happens to stand. It is the store
      // whichever line names it, so it is absolute here as well.
      expect(harness.output, contains('SDK: /project/sdk-home/versions/3.9.0'));
      expect(harness.output, isNot(contains('SDK: sdk-home/versions')));
    });

    test('a flutter found on PATH is not fvm\'s, so it follows the normal rule',
        () async {
      // The carve-out above is still a real one, and this is what keeps it
      // honest: an SDK fvm does not manage is not under the fvm home, so it
      // relativizes like any other path when it sits under the working
      // directory. Absolute output is not simply what every path does now.
      harness.fileSystem.file('/project/tools/bin/flutter')
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\n');
      harness.environment['PATH'] = '/project/tools/bin';

      expect(await harness.run(['which']), 0);

      expect(harness.output, contains('SDK: tools'));
      expect(harness.output, contains('rule 4 of 5'));
    });
  });

  test('`current` is the same command', () async {
    harness
      ..installVersion('3.9.0')
      ..writeConfig(const FvmConfig(global: '3.9.0'));

    expect(await harness.run(['current']), 0);
    expect(harness.output, contains('rule 3 of 5'));
  });

  test('a pin naming an SDK that is not installed says so', () async {
    harness.fileSystem.file('/project/.fvmrc').writeAsStringSync('3.9.0');

    expect(await harness.run(['which']), 1);
    expect(harness.errors, contains('not installed'));
    expect(harness.errors, contains('fvm install 3.9.0'));
  });
}
