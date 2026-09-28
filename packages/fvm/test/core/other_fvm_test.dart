import 'package:file/memory.dart';
import 'package:fvm/fvm.dart';
import 'package:fvm/src/core/other_fvm.dart';
import 'package:test/test.dart';

void main() {
  group('ForeignPin.parse', () {
    test('a release', () {
      final pin = ForeignPin.parse('3.19.0') as ReleasePin;
      expect(pin.version, '3.19.0');
      expect(pin.channel, isNull);
    });

    test('a release with its channel', () {
      final pin = ForeignPin.parse('3.20.0-1.2.pre@beta') as ReleasePin;
      expect(pin.version, '3.20.0-1.2.pre');
      expect(pin.channel, Channel.beta);
    });

    test('a channel', () {
      expect(
          (ForeignPin.parse('stable') as ChannelPin).channel, Channel.stable);
    });

    for (final pin in [
      'master',
      'main',
      'myfork/3.19.0',
      'fa345b1',
      'custom_build',
      '3.19.0@master',
    ]) {
      test('$pin has no equivalent', () {
        expect(ForeignPin.parse(pin), isA<UnsupportedPin>());
      });
    }
  });

  group('OtherFvmDetector', () {
    late MemoryFileSystem fs;

    OtherFvm detect(Map<String, String> environment) => OtherFvmDetector(
          fileSystem: fs,
          paths: FvmPaths(fileSystem: fs, environment: environment),
          environment: environment,
        ).detect();

    setUp(() {
      fs = MemoryFileSystem.test();
      fs.directory('/home/dev/fvm/versions/3.19.0').createSync(recursive: true);
    });

    test('finds the default cache under HOME', () {
      final other = detect({'HOME': '/home/dev'});
      expect(other.cacheDir?.path, '/home/dev/fvm');
      expect(other.cachedVersions, ['3.19.0']);
    });

    test('follows FVM_CACHE_PATH', () {
      fs.directory('/sdks/versions/3.10.0').createSync(recursive: true);
      final other = detect({'HOME': '/home/dev', 'FVM_CACHE_PATH': '/sdks'});
      expect(other.cachedVersions, ['3.10.0']);
    });

    test('ignores a cache that is this fvm home', () {
      // FVM_HOME is the other fvm's legacy cache variable too.
      final other = detect({
        'HOME': '/home/dev',
        'FVM_HOME': '/home/dev/fvm',
        'FVM_CACHE_PATH': '/home/dev/fvm',
      });
      expect(other.cacheDir, isNull);
      expect(other.cachedVersions, isEmpty);
    });

    test('never mistakes this fvm for the other one', () {
      fs.file('/home/dev/fvm/bin/fvm').createSync(recursive: true);
      final other = OtherFvmDetector(
        fileSystem: fs,
        paths: FvmPaths(fileSystem: fs, environment: const {'HOME': '/x'}),
        environment: const {'HOME': '/home/dev'},
        executablePath: '/home/dev/fvm/bin/fvm',
      ).detect();
      expect(other.installs, isEmpty);
    });
  });
}
