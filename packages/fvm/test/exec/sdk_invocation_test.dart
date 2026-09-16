import 'package:fvm/fvm.dart';
import 'package:fvm/src/core/runner.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

/// The child's view of the world: what is first on its PATH, what version it
/// is told it is running, and which binary a bare command name reaches.
void main() {
  late MemoryFileSystem fs;

  setUp(() => fs = MemoryFileSystem.test());

  /// An SDK laid out the way a real install leaves one.
  ResolvedSdk installed(
    MemoryFileSystem fileSystem, {
    String version = '3.9.0',
    String? sdkVersion,
  }) {
    final root = '${fileSystem.path.separator}fvm';
    final sdkDir = fileSystem.directory(
      fileSystem.path.join(root, 'versions', version),
    );
    final executable = fileSystem.file(
      fileSystem.path.join(sdkDir.path, 'bin', 'flutter'),
    )
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\n');
    return ResolvedSdk(
      rule: ResolutionRule.fvmrc,
      sdkDir: sdkDir,
      executable: executable,
      version: sdkVersion ?? version,
    );
  }

  SdkInvocation invocationOver(
    Map<String, String> environment, {
    MemoryFileSystem? fileSystem,
    ResolvedSdk? sdk,
  }) {
    final system = fileSystem ?? fs;
    return SdkInvocation(
      fileSystem: system,
      sdk: sdk ?? installed(system),
      environment: environment,
    );
  }

  group('the child PATH', () {
    test("starts with the resolved SDK's bin", () {
      final invocation = invocationOver({'PATH': '/usr/bin:/bin'});

      expect(invocation.binDir, '/fvm/versions/3.9.0/bin');
      expect(invocation.path, '/fvm/versions/3.9.0/bin:/usr/bin:/bin');
    });

    test('is just the SDK when the parent had no PATH at all', () {
      expect(invocationOver({}).path, '/fvm/versions/3.9.0/bin');
      expect(invocationOver({'PATH': ''}).path, '/fvm/versions/3.9.0/bin');
    });

    test('does not grow an entry per nesting level', () {
      // `fvm exec` inside `fvm exec` inside a build script inherits a PATH this
      // has already prefixed once.
      final once = invocationOver({'PATH': '/usr/bin'}).path;
      final twice = invocationOver({'PATH': once}).path;

      expect(twice, once);
    });

    test('keeps the spelling of PATH the parent used', () {
      // Windows hands out `Path`. Writing `PATH` back would leave the child
      // with the old value still under the old name.
      final windows = MemoryFileSystem.test(style: FileSystemStyle.windows);
      final invocation = invocationOver(
        {'Path': r'C:\Windows'},
        fileSystem: windows,
        sdk: installed(windows),
      );

      expect(invocation.environment.keys, contains('Path'));
      expect(invocation.environment.keys, isNot(contains('PATH')));
      expect(
        invocation.environment['Path'],
        r'\fvm\versions\3.9.0\bin;C:\Windows',
      );
    });
  });

  group('FVM_FLUTTER_VERSION', () {
    test('tells the child which version it is running', () {
      expect(
        invocationOver({'PATH': '/usr/bin'}).environment['FVM_FLUTTER_VERSION'],
        '3.9.0',
      );
    });

    test('is left alone when the SDK is not fvm-managed', () {
      // Rule 4 found a `flutter` on PATH. Pinning a version fvm did not choose
      // would be a lie that a nested fvm then acts on.
      final unmanaged = ResolvedSdk(
        rule: ResolutionRule.pathFallback,
        sdkDir: fs.directory('/usr'),
        executable: fs.file('/usr/bin/flutter'),
      );
      final invocation = invocationOver(
        {'PATH': '/usr/bin', 'FVM_FLUTTER_VERSION': ''},
        sdk: unmanaged,
      );

      expect(invocation.environment, isNot(contains('FVM_FLUTTER_VERSION')));
      expect(invocation.path, '/usr/bin');
    });

    test('only PATH and the version are overridden', () {
      final invocation = invocationOver({
        'PATH': '/usr/bin',
        'HOME': '/home/dev',
        'TERM': 'xterm',
      });

      // Everything else reaches the child from the parent process itself; a
      // hand-built environment would drop HOME and TERM on the floor.
      expect(invocation.environment.keys, ['PATH', 'FVM_FLUTTER_VERSION']);
    });
  });

  group('lookup', () {
    test('prefers the SDK over the same name later on PATH', () {
      fs.file('/usr/bin/flutter')
        ..createSync(recursive: true)
        ..writeAsStringSync('the wrong flutter');

      final invocation = invocationOver({'PATH': '/usr/bin'});

      expect(invocation.lookup('flutter')?.path,
          '/fvm/versions/3.9.0/bin/flutter');
    });

    test('finds a command the SDK does not ship', () {
      fs.file('/opt/pub/melos')
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\n');

      final invocation = invocationOver({'PATH': '/opt/pub:/usr/bin'});

      expect(invocation.lookup('melos')?.path, '/opt/pub/melos');
    });

    test('is null when nothing on the child PATH matches', () {
      expect(invocationOver({'PATH': '/usr/bin'}).lookup('melos'), isNull);
      expect(invocationOver({'PATH': '/usr/bin'}).lookup(''), isNull);
    });

    test('takes a name with a separator in it as a path, unsearched', () {
      fs.file('/project/tool/build')
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\n');

      final invocation = invocationOver({'PATH': '/usr/bin'});

      expect(invocation.lookup('/project/tool/build')?.path,
          '/project/tool/build');
      expect(invocation.lookup('./nope/build'), isNull);
    });

    test('skips empty PATH entries rather than looking in the root', () {
      fs.file('/melos')
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\n');

      expect(invocationOver({'PATH': '::/usr/bin'}).lookup('melos'), isNull);
    });

    test('tries the Windows executable extensions for a bare name', () {
      final windows = MemoryFileSystem.test(style: FileSystemStyle.windows);
      windows.file(r'C:\pub\melos.bat')
        ..createSync(recursive: true)
        ..writeAsStringSync('@echo off\n');

      final invocation = invocationOver(
        {'Path': r'C:\pub'},
        fileSystem: windows,
        sdk: installed(windows),
      );

      expect(invocation.lookup('melos')?.path, r'C:\pub\melos.bat');
    });
  });
}
