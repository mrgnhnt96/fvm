import 'package:fvm/fvm.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

void main() {
  group('FvmPaths', () {
    test('defaults to ~/.fvm and lays out the documented directories', () {
      final fs = MemoryFileSystem.test();
      final paths = FvmPaths(
        fileSystem: fs,
        environment: {'HOME': '/home/dev'},
      );

      expect(paths.home.path, '/home/dev/.fvm');
      expect(paths.versionsDir.path, '/home/dev/.fvm/versions');
      expect(paths.shimsDir.path, '/home/dev/.fvm/shims');
      expect(paths.cacheDir.path, '/home/dev/.fvm/cache');
      expect(paths.configFile.path, '/home/dev/.fvm/config.json');
      expect(paths.versionDir('3.9.0').path, '/home/dev/.fvm/versions/3.9.0');
    });

    test('FVM_HOME overrides the default', () {
      final fs = MemoryFileSystem.test();
      final paths = FvmPaths(
        fileSystem: fs,
        environment: {'HOME': '/home/dev', 'FVM_HOME': '/volumes/big/fvm'},
      );

      expect(paths.home.path, '/volumes/big/fvm');
      expect(paths.versionDir('3.9.0').path, '/volumes/big/fvm/versions/3.9.0');
    });

    test('a relative FVM_HOME is made absolute', () {
      final fs = MemoryFileSystem.test();
      fs.directory('/work').createSync(recursive: true);
      fs.currentDirectory = '/work';
      final paths = FvmPaths(fileSystem: fs, environment: {'FVM_HOME': 'sdks'});

      expect(paths.home.path, '/work/sdks');
    });

    test('a blank FVM_HOME falls back to HOME rather than being used', () {
      final fs = MemoryFileSystem.test();
      final paths = FvmPaths(
        fileSystem: fs,
        environment: {'HOME': '/home/dev', 'FVM_HOME': '  '},
      );

      expect(paths.home.path, '/home/dev/.fvm');
    });

    test('with no home variable at all it says what to set', () {
      final paths = FvmPaths(
        fileSystem: MemoryFileSystem.test(),
        environment: const {},
      );

      expect(
        () => paths.home,
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('FVM_HOME'), contains('HOME')),
          ),
        ),
      );
    });

    test('constructing never throws, so --help works without a HOME', () {
      expect(
        () => FvmPaths(
          fileSystem: MemoryFileSystem.test(),
          environment: const {},
        ),
        returnsNormally,
      );
    });

    test('the flutter executable sits under bin/ in an SDK', () {
      final fs = MemoryFileSystem.test();
      final paths = FvmPaths(
        fileSystem: fs,
        environment: {'HOME': '/home/dev'},
      );

      expect(
        paths.flutterExecutable(paths.versionDir('3.9.0')).path,
        '/home/dev/.fvm/versions/3.9.0/bin/flutter',
      );
    });

    test('per-project paths match the documented layout', () {
      final fs = MemoryFileSystem.test();
      final paths = FvmPaths(
        fileSystem: fs,
        environment: {'HOME': '/home/dev'},
      );
      final project = fs.directory('/code/app');

      expect(paths.fvmrcFile(project).path, '/code/app/.fvmrc');
      expect(paths.projectSdkLink(project).path, '/code/app/.fvm/flutter_sdk');
    });

    test('Windows uses USERPROFILE, flutter.bat and the .bat shim', () {
      final fs = MemoryFileSystem.test(style: FileSystemStyle.windows);
      final paths = FvmPaths(
        fileSystem: fs,
        environment: {r'USERPROFILE': r'C:\Users\dev'},
      );

      expect(paths.home.path, r'C:\Users\dev\.fvm');
      expect(paths.flutterExecutableName, 'flutter.bat');
      expect(paths.flutterShim.path, r'C:\Users\dev\.fvm\shims\flutter.bat');
    });
  });
}
