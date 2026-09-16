import 'package:fvm/fvm.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late CommandHarness harness;

  /// The state `fvm setup` leaves behind on a working machine: a fvm binary, a
  /// shim naming it, and the shims directory first on PATH.
  void makeHealthy() {
    harness.fileSystem.file('/usr/local/bin/fvm')
      ..createSync(recursive: true)
      ..writeAsStringSync('a compiled binary');
    harness.fileSystem.file('/fvm/shims/flutter')
      ..createSync(recursive: true)
      ..writeAsStringSync(
          '#!/bin/sh\nexec "/usr/local/bin/fvm" exec flutter "\$@"\n');
    harness.environment['PATH'] = '/fvm/shims:/usr/bin';
  }

  /// A real, non-shim `flutter` in [directory].
  void putFlutterIn(String directory) {
    harness.fileSystem.file('$directory/flutter')
      ..createSync(recursive: true)
      ..writeAsStringSync('a multi-megabyte binary, in spirit');
  }

  setUp(() {
    harness = CommandHarness();
    harness.environment['SHELL'] = '/bin/zsh';
  });

  test('passes on a machine that is set up correctly', () async {
    makeHealthy();

    expect(await harness.run(['doctor']), 0);
    expect(harness.output, contains('Everything checks out.'));
    expect(harness.output, isNot(contains('FAIL')));
  });

  group('PATH', () {
    test('fails when the shims are not on PATH at all', () async {
      makeHealthy();
      harness.environment['PATH'] = '/usr/bin';
      putFlutterIn('/usr/bin');

      expect(await harness.run(['doctor']), 1);
      expect(harness.output, contains('/fvm/shims is not on PATH'));
      expect(harness.output, contains(r'export PATH="/fvm/shims:$PATH"'));
    });

    test('fails when another flutter comes first, and reports the order',
        () async {
      makeHealthy();
      harness.environment['PATH'] = '/opt/flutter/bin:/usr/bin:/fvm/shims';
      putFlutterIn('/opt/flutter/bin');

      expect(await harness.run(['doctor']), 1);
      expect(harness.output, contains('the shim is never reached'));
      expect(harness.output, contains('PATH order'));
      expect(harness.output, contains('1. /opt/flutter/bin'));
      expect(harness.output, contains('3. /fvm/shims  <- fvm shims'));
    });

    test('does not count a copy of the shim as a flutter that beats it',
        () async {
      makeHealthy();
      // What `cp ~/.fvm/shims/flutter ~/.local/bin/` leaves behind. It still goes
      // through fvm, so it is not a problem the user can act on.
      harness.fileSystem.file('/home/dev/.local/bin/flutter')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '#!/bin/sh\nexec "/usr/local/bin/fvm" exec flutter "\$@"\n',
        );
      harness.environment['PATH'] = '/home/dev/.local/bin:/fvm/shims';

      expect(await harness.run(['doctor']), 0);
    });
  });

  group('shims', () {
    test('fails when the shim is not there', () async {
      harness.environment['PATH'] = '/fvm/shims';

      expect(await harness.run(['doctor']), 1);
      expect(harness.output, contains('/fvm/shims/flutter does not exist'));
      expect(harness.output, contains('fvm setup'));
    });

    test('fails when the shim runs a fvm binary that is gone', () async {
      makeHealthy();
      harness.fileSystem.file('/usr/local/bin/fvm').deleteSync();

      expect(await harness.run(['doctor']), 1);
      expect(
        harness.output,
        contains('runs /usr/local/bin/fvm, which no longer exists'),
      );
    });

    test('fails when the shim is not recognisable as one of ours', () async {
      makeHealthy();
      harness.fileSystem
          .file('/fvm/shims/flutter')
          .writeAsStringSync('#!/bin/sh\necho hello\n');

      expect(await harness.run(['doctor']), 1);
      expect(harness.output, contains('not recognisable as a fvm shim'));
    });
  });

  group('shell', () {
    test('fails on a fvm shell function, naming the file and the line',
        () async {
      makeHealthy();
      harness.fileSystem.file('/home/dev/.zshrc')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'export EDITOR=vim\n'
          '[ -s "\$HOME/.fvm/scripts/fvm" ] && . "\$HOME/.fvm/scripts/fvm"\n',
        );

      expect(await harness.run(['doctor']), 1);
      expect(harness.output, contains('/home/dev/.zshrc:2:'));
      expect(harness.output, contains('resolved before PATH is searched'));
      expect(harness.output, contains('conflicting fvm shell script'));
    });

    test('warns when a startup file puts the shims on PATH but PATH does not',
        () async {
      // The state this leaf is about, and the one the reporter was stuck in:
      // the line is real, it is in a real file, and the shell running doctor
      // has never sourced that file. The PATH check above already FAILs; this
      // is the finding that says WHY and names the file.
      makeHealthy();
      harness.environment['PATH'] = '/usr/bin';
      harness.fileSystem.file('/home/dev/.profile')
        ..createSync(recursive: true)
        ..writeAsStringSync('# >>> fvm >>>\n'
            r'export PATH="/fvm/shims:$PATH"'
            '\n# <<< fvm <<<\n');

      expect(await harness.run(['doctor']), 1);

      expect(harness.output, contains('warn  shell:'));
      expect(
          harness.output,
          contains('is put on PATH by a startup file, but '
              'it is not on the PATH of this shell'));
      expect(harness.output, contains('/home/dev/.profile:2:'));
      expect(harness.output, contains('no new shell has been started'));
      // One problem, not two: the PATH check already counted the failure, and
      // this explains that failure rather than being a second one.
      expect(harness.output, contains('1 problem, 1 warning.'));
    });

    test('names the other shell whose rc files are sitting right there',
        () async {
      makeHealthy();
      harness.environment['PATH'] = '/usr/bin';
      harness.environment.remove('SHELL');
      harness.fileSystem.file('/home/dev/.zshrc')
        ..createSync(recursive: true)
        ..writeAsStringSync('export EDITOR=vim\n');
      harness.fileSystem.file('/home/dev/.profile')
        ..createSync(recursive: true)
        ..writeAsStringSync(r'export PATH="/fvm/shims:$PATH"' '\n');

      expect(await harness.run(['doctor']), 1);

      expect(
          harness.output,
          contains('/home/dev/.zshrc is here too, so zsh '
              'is in use on this machine'));
      expect(harness.output,
          contains('SHELL=<your shell> fvm setup --write-path-line'));
    });

    test('says nothing when the line is in a file and IS in effect', () async {
      makeHealthy();
      harness.fileSystem.file('/home/dev/.zshrc')
        ..createSync(recursive: true)
        ..writeAsStringSync(r'export PATH="/fvm/shims:$PATH"' '\n');

      expect(await harness.run(['doctor']), 0);
      expect(harness.output, contains('Everything checks out.'));
    });

    test('says nothing when no startup file mentions the shims at all',
        () async {
      // The plain "not set up yet" machine. It gets the PATH failure and no
      // second sentence, because there is no misfiled line to point at.
      makeHealthy();
      harness.environment['PATH'] = '/usr/bin';

      expect(await harness.run(['doctor']), 1);
      expect(harness.output, isNot(contains('put on PATH by a startup file')));
    });
  });

  group('config', () {
    test('fails when the global default is not installed', () async {
      makeHealthy();
      harness.writeConfig(const FvmConfig(global: '3.13.2'));

      expect(await harness.run(['doctor']), 1);
      expect(
        harness.output,
        contains(
            'the global default is Flutter 3.13.2, which is not installed'),
      );
      expect(harness.output, contains('fvm install 3.13.2'));
    });

    test('fails on a config.json that is not valid JSON', () async {
      makeHealthy();
      harness.fileSystem.file('/fvm/config.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"global": ');

      expect(await harness.run(['doctor']), 1);
      expect(harness.output, contains('not valid JSON'));
    });

    test('passes when the global default is installed', () async {
      makeHealthy();
      harness
        ..installVersion('3.13.2')
        ..writeConfig(const FvmConfig(global: '3.13.2'));

      expect(await harness.run(['doctor']), 0);
      expect(
          harness.output,
          contains('the global default Flutter 3.13.2 is '
              'installed'));
    });
  });

  group('project', () {
    test('fails when the version this project pins is not installed', () async {
      makeHealthy();
      harness.fileSystem.file('/project/.fvmrc').writeAsStringSync('3.9.0');

      expect(await harness.run(['doctor']), 1);
      expect(
        harness.output,
        contains('.fvmrc pins Flutter 3.9.0, which is not installed'),
      );
    });

    test('fails on a stale .fvm/flutter_sdk symlink', () async {
      makeHealthy();
      harness.installVersion('3.9.0');
      harness.fileSystem.file('/project/.fvmrc').writeAsStringSync('3.9.0');
      // What `fvm remove` of a version some project still points at leaves:
      // the link outlives the directory it names.
      harness.fileSystem
          .link('/project/.fvm/flutter_sdk')
          .createSync('/fvm/versions/3.7.0', recursive: true);

      expect(await harness.run(['doctor']), 1);
      expect(harness.output, contains('is a stale symlink'));
      expect(harness.output, contains('/fvm/versions/3.7.0'));
      expect(harness.output, contains('fvm use 3.9.0'));
    });

    test('warns when the symlink points somewhere other than the pin',
        () async {
      makeHealthy();
      harness
        ..installVersion('3.9.0')
        ..installVersion('3.13.2');
      harness.fileSystem.file('/project/.fvmrc').writeAsStringSync('3.9.0');
      harness.fileSystem
          .link('/project/.fvm/flutter_sdk')
          .createSync('/fvm/versions/3.13.2', recursive: true);

      expect(await harness.run(['doctor']), 0);
      expect(harness.output, contains('but this project pins Flutter 3.9.0'));
    });

    test('is quiet about projects with no pin', () async {
      makeHealthy();

      expect(await harness.run(['doctor']), 0);
      expect(harness.output, contains('no .fvmrc at or above /project'));
    });
  });

  test('reports several problems in one run', () async {
    // Nothing set up at all: no shim, no PATH entry, and a global pointing at
    // a version that is not there.
    harness.writeConfig(const FvmConfig(global: '3.13.2'));

    expect(await harness.run(['doctor']), 1);
    expect(harness.output, contains('3 problems, 0 warnings.'));
  });
}
