import 'package:fvm/src/archive/flutter_archive_exception.dart';
import 'package:fvm/src/archive/sdk_extractor.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

/// [sdkRootWithin] must spell paths the way the FILESYSTEM it was handed does.
///
/// It takes a `Directory`, and a `Directory` carries its own filesystem, which
/// may be a memory one whose style has nothing to do with the host's. Joining
/// with the top-level `package:path` context instead asks the HOST how paths
/// are spelled, and the two agree on every machine the suite used to run on.
///
/// Which is why this reads as a test that could never have failed: on Linux and
/// macOS it passes against the broken code as well, because a windows-style
/// memory filesystem accepts `/` as a separator too. It is the Windows job that
/// makes it bite — there the host joins with `\`, the posix-style filesystem
/// treats that as an ordinary character, and the function looks for a file
/// literally called `bin\flutter`. Every install in the suite failed that way the
/// first time this repo ran its tests on Windows.
void main() {
  /// An extracted SDK, wrapped in `flutter-sdk/` the way the published zips are.
  Directory extracted(FileSystem fs, String root, String executableName) {
    final path = fs.path;
    fs
        .file(path.join(root, 'unpacked', 'flutter-sdk', 'bin', executableName))
        .createSync(recursive: true);
    return fs.directory(path.join(root, 'unpacked'));
  }

  test('finds the SDK root on a posix-style filesystem', () {
    final fs = MemoryFileSystem.test();
    final root = sdkRootWithin(extracted(fs, '/fvm', 'flutter'), 'flutter');
    expect(root.path, '/fvm/unpacked/flutter-sdk');
  });

  test('finds the SDK root on a windows-style filesystem', () {
    final fs = MemoryFileSystem.test(style: FileSystemStyle.windows);
    final root = sdkRootWithin(
      extracted(fs, r'C:\fvm', 'flutter.bat'),
      'flutter.bat',
    );
    expect(root.path, r'C:\fvm\unpacked\flutter-sdk');
  });

  test('an SDK that is not wrapped is found where it is', () {
    final fs = MemoryFileSystem.test();
    fs.file('/fvm/unpacked/bin/flutter').createSync(recursive: true);
    expect(
      sdkRootWithin(fs.directory('/fvm/unpacked'), 'flutter').path,
      '/fvm/unpacked',
    );
  });

  test('an archive with no SDK in it says so, naming what it looked for', () {
    final fs = MemoryFileSystem.test();
    fs.file('/fvm/unpacked/README.md').createSync(recursive: true);
    expect(
      () => sdkRootWithin(fs.directory('/fvm/unpacked'), 'flutter.bat'),
      throwsA(
        isA<FlutterArchiveException>().having(
          (error) => error.message,
          'message',
          contains('bin/flutter.bat'),
        ),
      ),
    );
  });
}
