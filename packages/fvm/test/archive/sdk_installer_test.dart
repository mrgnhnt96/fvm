import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'package:fvm/fvm.dart';
import 'package:fvm/src/archive/flutter_archive_client.dart';
import 'package:fvm/src/archive/flutter_archive_exception.dart';
import 'package:fvm/src/archive/sdk_extractor.dart';
import 'package:fvm/src/archive/sdk_installer.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

import 'fake_archive_server.dart';

void main() {
  late FakeArchiveServer server;
  late MemoryFileSystem fs;
  late FvmPaths paths;
  late StringBuffer progress;

  const platform = HostPlatform(os: 'macos', arch: 'arm64');
  final fileName = 'flutter_${platform.os}_${platform.arch}_test.zip';

  setUp(() async {
    server = await FakeArchiveServer.start();
    fs = MemoryFileSystem.test();
    // Every test runs against a fake $FVM_HOME on a memory filesystem; nothing
    // here can reach the real ~/.fvm.
    paths = FvmPaths(fileSystem: fs, environment: {'FVM_HOME': '/fvm'});
    progress = StringBuffer();
  });

  tearDown(() => server.close());

  SdkInstaller buildInstaller({
    SdkExtractor? extractor,
    ModeApplier? modeApplier,
  }) {
    return SdkInstaller(
      fileSystem: fs,
      paths: paths,
      releases: FlutterArchiveClient(
        objectBase: server.objectBase,
      ),
      hostPlatform: () => platform,
      progress: progress,
      extractor: extractor,
      // The real applier shells out to chmod, which cannot see a memory
      // filesystem. The POSIX-mode behaviour is covered on a real filesystem
      // in sdk_modes_test.dart.
      modeApplier: modeApplier ?? const NoopModeApplier(),
    );
  }

  void publishSdk({String version = '3.13.2', Uint8List? bytes}) {
    server.publish(
      channel: 'stable',
      version: version,
      fileName: fileName,
      bytes: bytes ?? fakeSdkZip(version: version),
    );
  }

  /// Everything under `~/.fvm/versions`, as paths.
  List<String> versionsContents() {
    final dir = paths.versionsDir;
    if (!dir.existsSync()) return const [];
    return [for (final entity in dir.listSync()) entity.basename];
  }

  /// Everything left behind in `~/.fvm/cache`.
  List<String> cacheContents() {
    final dir = paths.cacheDir;
    if (!dir.existsSync()) return const [];
    return [for (final entity in dir.listSync(recursive: true)) entity.path];
  }

  group('a good install', () {
    test('lands the SDK under versions/<version>', () async {
      publishSdk();

      final directory = await buildInstaller().install('3.13.2');

      expect(directory.path, paths.versionDir('3.13.2').path);
      expect(
        fs.file('/fvm/versions/3.13.2/bin/flutter').existsSync(),
        isTrue,
        reason: 'the wrapping flutter-sdk/ directory should not survive',
      );
      expect(fs.file('/fvm/versions/3.13.2/version').readAsStringSync().trim(),
          '3.13.2');
    });

    test('leaves nothing behind in the cache', () async {
      publishSdk();

      await buildInstaller().install('3.13.2');

      expect(cacheContents(), isEmpty);
    });

    test('reports download progress', () async {
      publishSdk();

      await buildInstaller().install('3.13.2');

      expect(progress.toString(), contains('Downloading Flutter 3.13.2'));
      expect(progress.toString(), contains('100%'));
    });

    test('finds the channel itself when it is not told one', () async {
      publishSdk();

      await buildInstaller().install('3.13.2');

      expect(
        server.requests,
        contains(contains('/releases/releases_')),
      );
    });
  });

  group('isInstalled', () {
    test('is false for a directory with no bin/flutter in it', () {
      fs.directory('/fvm/versions/3.13.2/lib').createSync(recursive: true);

      expect(buildInstaller().isInstalled('3.13.2'), isFalse);
    });

    test('is true once a real SDK is there', () async {
      publishSdk();
      await buildInstaller().install('3.13.2');

      expect(buildInstaller().isInstalled('3.13.2'), isTrue);
    });
  });

  test('an already-installed version is not downloaded again', () async {
    publishSdk();
    await buildInstaller().install('3.13.2');
    server.requests.clear();

    final directory = await buildInstaller().install('3.13.2');

    expect(directory.path, paths.versionDir('3.13.2').path);
    expect(server.requests, isEmpty);
  });

  group('nothing is published unless the whole install succeeded', () {
    test('a checksum mismatch aborts and versions/ stays empty', () async {
      publishSdk();
      // A checksum for different bytes is what a corrupted download, or a
      // tampered-with archive, looks like.
      server.checksumOverrides['stable/3.13.2/$fileName'] = 'a' * 64;

      await expectLater(
        buildInstaller().install('3.13.2'),
        throwsA(isA<FlutterArchiveException>().having(
          (e) => e.message,
          'message',
          allOf(contains('sha256'), contains('Nothing was installed')),
        )),
      );

      expect(versionsContents(), isEmpty);
      expect(cacheContents(), isEmpty);
    });

    test('a failure mid-extract leaves versions/ empty', () async {
      publishSdk();
      final extractor = _HalfwayExtractor();

      await expectLater(
        buildInstaller(extractor: extractor).install('3.13.2'),
        throwsA(isA<StateError>()),
      );

      // The atomic rename is the mechanism, and it only works because nothing
      // is ever extracted into versions/ in the first place.
      expect(
        fs.path.isWithin(paths.cacheDir.path, extractor.destination!),
        isTrue,
        reason: 'extraction should happen under the cache, not in place',
      );
      expect(
        versionsContents(),
        isEmpty,
        reason: 'extracting in place would have left a half-written SDK here',
      );
      expect(cacheContents(), isEmpty);
    });

    test('an archive that is not a zip leaves versions/ empty', () async {
      // Checksummed correctly and still garbage: verification proves the bytes
      // arrived intact, not that they are a Flutter SDK.
      publishSdk(bytes: Uint8List.fromList(List.filled(2048, 0x41)));

      await expectLater(
        buildInstaller().install('3.13.2'),
        throwsA(isA<FlutterArchiveException>()),
      );

      expect(versionsContents(), isEmpty);
      expect(cacheContents(), isEmpty);
    });

    test('a zip with no bin/flutter in it leaves versions/ empty', () async {
      publishSdk(bytes: fakeSdkZip(flutterExecutableName: 'not-flutter'));

      await expectLater(
        buildInstaller().install('3.13.2'),
        throwsA(isA<FlutterArchiveException>().having(
          (e) => e.message,
          'message',
          contains('does not contain a Flutter SDK'),
        )),
      );

      expect(versionsContents(), isEmpty);
      expect(cacheContents(), isEmpty);
    });

    test('a checksum published for another platform is refused', () async {
      publishSdk();
      server.checksumOverrides['stable/3.13.2/$fileName'] =
          '${'b' * 64} *fluttersdk-linux-x64-release.zip';

      await expectLater(
        buildInstaller().install('3.13.2'),
        throwsA(isA<FlutterArchiveException>().having(
          (e) => e.message,
          'message',
          contains('SHA-256'),
        )),
      );

      expect(versionsContents(), isEmpty);
    });
  });

  test('a zip entry pointing outside the destination is not written', () async {
    publishSdk(bytes: _escapingZip());

    await expectLater(
      buildInstaller().install('3.13.2'),
      completion(isA<Directory>()),
    );

    expect(
      fs.file('/fvm/escaped.txt').existsSync(),
      isFalse,
      reason: '../ in a zip entry must not write outside the extract dir',
    );
  });
}

/// An extractor that gets partway through and then fails, the way an
/// interrupted or truncated extraction does.
class _HalfwayExtractor implements SdkExtractor {
  /// Where the installer asked for the archive to be unpacked.
  String? destination;

  @override
  Future<Map<String, int>> extract({
    required File archive,
    required Directory destination,
    ExtractionProgress? onProgress,
  }) async {
    this.destination = destination.path;
    final fs = destination.fileSystem;
    destination.createSync(recursive: true);
    fs.file(fs.path.join(destination.path, 'bin', 'flutter'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('half a file');
    throw StateError('the connection dropped mid-extract');
  }
}

/// A zip whose entries try to write above the directory they unpack into.
Uint8List _escapingZip() {
  final archive = Archive()
    ..add(ArchiveFile.string('flutter-sdk/bin/flutter', '#!/bin/sh\n')
      ..mode = 0x1ED)
    ..add(ArchiveFile.string('flutter-sdk/version', '3.13.2\n')..mode = 0x1A4)
    ..add(ArchiveFile.string('../../../escaped.txt', 'pwned\n')..mode = 0x1A4);
  return ZipEncoder().encodeBytes(archive);
}
