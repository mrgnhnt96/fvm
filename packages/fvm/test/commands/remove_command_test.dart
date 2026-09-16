import 'dart:io' show OSError, PathAccessException;

import 'package:fvm/fvm.dart';
import 'package:fvm/fvm.dart' as fvm;
import 'package:file/memory.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late CommandHarness harness;

  setUp(() => harness = CommandHarness());

  test('deletes the SDK from the cache', () async {
    harness
      ..installVersion('3.9.0')
      ..installVersion('3.13.2');

    expect(await harness.run(['remove', '3.9.0']), 0);

    expect(harness.fileSystem.directory('/fvm/versions/3.9.0').existsSync(),
        isFalse);
    expect(harness.fileSystem.directory('/fvm/versions/3.13.2').existsSync(),
        isTrue);
    expect(harness.output, contains('Removed Flutter 3.9.0'));
  });

  test('a version that is not installed is reported, not crashed on', () async {
    expect(await harness.run(['remove', '3.9.0']), 1);
    expect(harness.errors, contains('not installed'));
    expect(harness.errors, contains('fvm list'));
  });

  group('refusing to break something', () {
    test('refuses a version an alias points at, naming the alias', () async {
      harness
        ..installVersion('3.9.0')
        ..writeConfig(const FvmConfig(aliases: {'work': '3.9.0'}));

      expect(await harness.run(['remove', '3.9.0']), 1);

      expect(harness.errors, contains('Refusing to remove Flutter 3.9.0'));
      expect(harness.errors, contains('the alias "work"'));
      expect(harness.errors, contains('--force'));
      expect(harness.fileSystem.directory('/fvm/versions/3.9.0').existsSync(),
          isTrue,
          reason: 'a refusal must not delete anything');
    });

    test('refuses when an alias reaches it through another alias', () async {
      harness
        ..installVersion('3.9.0')
        ..writeConfig(
          const FvmConfig(aliases: {'work': '3.9.0', 'current': 'work'}),
        );

      expect(await harness.run(['remove', '3.9.0']), 1);
      expect(harness.errors, contains('the alias "current"'));
    });

    test('refuses the global default, naming it', () async {
      harness
        ..installVersion('3.9.0')
        ..writeConfig(const FvmConfig(global: '3.9.0'));

      expect(await harness.run(['remove', '3.9.0']), 1);
      expect(harness.errors, contains('the global default'));
      expect(harness.fileSystem.directory('/fvm/versions/3.9.0').existsSync(),
          isTrue);
    });

    test('--force removes it anyway and says what now dangles', () async {
      harness
        ..installVersion('3.9.0')
        ..writeConfig(
          const FvmConfig(global: '3.9.0', aliases: {'work': '3.9.0'}),
        );

      expect(await harness.run(['remove', '3.9.0', '--force']), 0);

      expect(harness.fileSystem.directory('/fvm/versions/3.9.0').existsSync(),
          isFalse);
      expect(
          harness.errors,
          contains('now point at a version that is not '
              'installed'));
      expect(harness.errors, contains('the alias "work"'));
    });

    test('a channel record does not block removal', () async {
      harness
        ..installVersion('3.13.2')
        ..writeConfig(const FvmConfig(channels: {'stable': '3.13.2'}));

      expect(await harness.run(['remove', '3.13.2']), 0);
    });
  });

  test('removing a channel version forgets the stale record', () async {
    harness
      ..installVersion('3.13.2')
      ..writeConfig(
        const FvmConfig(
            channels: {'stable': '3.13.2', 'beta': '3.14.0-1.beta'}),
      );

    await harness.run(['remove', '3.13.2']);

    // A record naming a version that is gone would make `fvm use stable`
    // claim to know exactly which SDK stable is, then fail to find it.
    expect(harness.readConfig().channels, {'beta': '3.14.0-1.beta'});
    expect(harness.output, contains('fvm install stable'));
  });

  test('an alias can be used to name what to remove', () async {
    harness
      ..installVersion('3.9.0')
      ..writeConfig(const FvmConfig(aliases: {'work': '3.9.0'}));

    // The alias still counts as a dependent, so this needs --force: the point
    // is that the name resolves to the right directory.
    expect(await harness.run(['remove', 'work', '--force']), 0);
    expect(harness.fileSystem.directory('/fvm/versions/3.9.0').existsSync(),
        isFalse);
  });

  test('warns when this project pinned the version just removed', () async {
    harness.installVersion('3.9.0');
    harness.fileSystem.file('/project/.fvmrc').writeAsStringSync('3.9.0');

    expect(await harness.run(['remove', '3.9.0']), 0);
    expect(
        harness.errors,
        contains('.fvmrc pins the version just '
            'removed'));
    expect(harness.errors, isNot(contains('/project/.fvmrc')));
  });

  group('when the filesystem refuses the delete', () {
    /// What Windows returns for `DeleteFileW` on a file a process is running.
    ///
    /// A real one, quoted from CI run 33284815252 on windows-latest, where it
    /// reached the user as an unhandled exception, a twelve-frame VM stack
    /// trace, and exit 255.
    PathAccessException accessDenied(String path) => PathAccessException(
          path,
          const OSError('Access is denied.', 5),
          'Deletion failed',
        );

    /// Fails the delete of `versions/<version>` and nothing else.
    void Function(String, FileSystemOp) denyDeleting(String version) =>
        (String path, FileSystemOp operation) {
          if (operation == FileSystemOp.delete && path.endsWith(version)) {
            throw accessDenied(path);
          }
        };

    test('reports it and exits 1 instead of crashing with a stack trace',
        () async {
      harness = CommandHarness(opHandle: denyDeleting('3.9.0'));
      harness.installVersion('3.9.0');

      expect(await harness.run(['remove', '3.9.0']), 1);

      // The OS's own words and the path it named, so the user can act on it.
      expect(harness.errors, contains('Could not remove Flutter 3.9.0'));
      expect(harness.errors, contains('Access is denied.'));
      expect(harness.errors, contains('/fvm/versions/3.9.0'));
      // A report, not a crash.
      expect(harness.errors, isNot(contains('PathAccessException')));
      expect(harness.errors, isNot(contains('#0')));
    });

    test('claims nothing it did not do', () async {
      harness = CommandHarness(opHandle: denyDeleting('3.13.2'));
      harness
        ..installVersion('3.13.2')
        ..writeConfig(const FvmConfig(channels: {'stable': '3.13.2'}));
      harness.fileSystem.file('/project/.fvmrc').writeAsStringSync('3.13.2');

      await harness.run(['remove', '3.13.2']);

      // Everything after the delete describes a version that is gone, and none
      // of it is true when the delete was refused. The channel record is the
      // one that would be DESTROYED on the way past, leaving the config
      // disagreeing with a cache that never changed.
      expect(harness.output, isNot(contains('Removed Flutter 3.13.2')));
      expect(harness.errors, isNot(contains('pins the version just removed')));
      expect(harness.readConfig().channels, {'stable': '3.13.2'});
      expect(
        harness.fileSystem.directory('/fvm/versions/3.13.2').existsSync(),
        isTrue,
      );
    });

    test('on Windows it names the thing that actually causes this', () async {
      // A Windows-styled filesystem, because the advice is chosen from the
      // paths fvm is working with rather than from the host running the suite
      // -- and the whole point of the sentence is that it is Windows-specific:
      // POSIX unlinks a running executable without complaint.
      final fileSystem = MemoryFileSystem.test(
        style: FileSystemStyle.windows,
        opHandle: (String path, FileSystemOp operation) {
          if (operation == FileSystemOp.delete && path.endsWith('3.9.0')) {
            throw accessDenied(path);
          }
        },
      );
      fileSystem
          .file(r'C:\fvm\versions\3.9.0\bin\flutter.bat')
          .createSync(recursive: true);

      final out = StringBuffer();
      final err = StringBuffer();
      final code = await fvm.run(
        ['remove', '3.9.0'],
        fileSystem: fileSystem,
        environment: {'FVM_HOME': r'C:\fvm', 'PATH': ''},
        platformVersion: '3.13.2 (stable) on "windows_x64"',
        out: out,
        err: err,
      );

      expect(code, 1);
      expect(err.toString(), contains(r'C:\fvm\versions\3.9.0'));
      expect(err.toString(), contains('while a program is running it'));
    });
  });

  group('bad usage', () {
    test('naming nothing is a usage error', () async {
      expect(await harness.run(['remove']), usageExitCode);
      expect(harness.errors, contains('Name a version to remove'));
    });

    test('naming two versions is a usage error', () async {
      expect(await harness.run(['remove', '3.9.0', '3.13.2']), usageExitCode);
      expect(harness.errors, contains('one version at a time'));
    });
  });
}
