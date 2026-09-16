import 'dart:convert';
import 'dart:typed_data';

import 'package:fvm/fvm.dart';
import 'package:fvm/src/archive/sdk_extractor.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

import 'fake_github_server.dart';

void main() {
  late FakeGitHubServer server;
  late MemoryFileSystem fs;

  setUp(() async {
    server = await FakeGitHubServer.start();
    fs = MemoryFileSystem.test();
  });

  tearDown(() => server.close());

  /// An [Updater] pointed at the fake server, installing onto [fs].
  ///
  /// `isCompiled: true` because every path worth testing is gated on it and a
  /// test run is never a compiled build. `NoopModeApplier` because chmod is a
  /// real subprocess against a real path, and none of these paths are real.
  Updater updaterFor({
    HostPlatform? platform,
    String currentVersion = '0.1.0',
    bool isCompiled = true,
    FileSystem? fileSystem,
    ModeApplier? modeApplier,
  }) =>
      Updater(
        fileSystem: fileSystem ?? fs,
        hostPlatform: () =>
            platform ?? const HostPlatform(os: 'macos', arch: 'arm64'),
        environment: const {},
        apiBase: server.apiBase,
        isCompiled: isCompiled,
        currentVersion: currentVersion,
        modeApplier: modeApplier ?? const NoopModeApplier(),
      );

  /// An installed fvm binary at [path], the way a release left it.
  File installedFvm([String path = '/usr/local/bin/fvm']) => fs.file(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(utf8.encode('the running fvm binary'));

  group('release asset names', () {
    test('are the five names install.sh and release.yml agree on', () {
      const targets = {
        'linux-x64',
        'linux-arm64',
        'macos-x64',
        'macos-arm64',
        'windows-x64',
      };
      for (final target in targets) {
        final parts = target.split('-');
        expect(
          releaseAssetName(HostPlatform(os: parts[0], arch: parts[1])),
          'fvm-$target.zip',
        );
      }
    });

    test('refuse a host fvm publishes no binary for, naming the ones it does',
        () {
      // Flutter publishes an SDK for linux/riscv64, so fvm can manage SDKs there,
      // but there is no fvm binary for it to install or update itself with.
      expect(
        () =>
            releaseAssetName(const HostPlatform(os: 'linux', arch: 'riscv64')),
        throwsA(
          isA<UnsupportedPlatformException>().having(
            (e) => e.message,
            'message',
            allOf(contains('linux-riscv64'), contains('linux-arm64')),
          ),
        ),
      );
    });
  });

  group('latestRelease', () {
    test('takes the newest release carrying this platform\'s asset', () async {
      server
        ..publish(tag: 'v0.3.0', assets: {'fvm-macos-arm64.zip': _zip()})
        ..publish(tag: 'v0.2.0', assets: {'fvm-macos-arm64.zip': _zip()});

      expect((await updaterFor().latestRelease()).version, '0.3.0');
    });

    test('skips drafts and prereleases', () async {
      server
        ..publish(
          tag: 'v0.9.0',
          draft: true,
          assets: {'fvm-macos-arm64.zip': _zip()},
        )
        ..publish(
          tag: 'v0.8.0',
          prerelease: true,
          assets: {'fvm-macos-arm64.zip': _zip()},
        )
        ..publish(tag: 'v0.3.0', assets: {'fvm-macos-arm64.zip': _zip()});

      expect((await updaterFor().latestRelease()).version, '0.3.0');
    });

    test('skips a newer release that carries no fvm binary', () async {
      // The case /releases/latest gets wrong: a release for something other
      // than the CLI takes the "latest" slot and has no fvm asset in it.
      server
        ..publish(tag: 'v0.4.0', assets: {'some-other-thing.zip': _zip()})
        ..publish(tag: 'v0.3.0', assets: {'fvm-macos-arm64.zip': _zip()});

      expect((await updaterFor().latestRelease()).version, '0.3.0');
    });

    test('fails naming the asset when no release has one for this platform',
        () async {
      server.publish(tag: 'v0.3.0', assets: {'fvm-linux-x64.zip': _zip()});

      await expectLater(
        updaterFor().latestRelease(),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('fvm-macos-arm64.zip'),
          ),
        ),
      );
    });
  });

  group('update', () {
    test('replaces the running binary and reports both versions', () async {
      server.publish(
        tag: 'v0.3.0',
        assets: {'fvm-macos-arm64.zip': _zip(contents: 'fvm 0.3.0')},
      );
      final binary = installedFvm();

      final outcome = await updaterFor().update(
        executablePath: binary.path,
      );

      expect(outcome.installed, isTrue);
      expect(outcome.from, '0.1.0');
      expect(outcome.to, '0.3.0');
      expect(binary.readAsStringSync(), 'fvm 0.3.0');
      // Temp file cleaned up by the rename, not left beside the binary.
      expect(fs.file('${binary.path}.new').existsSync(), isFalse);
    });

    test('makes the installed binary executable before it is in place',
        () async {
      server.publish(
        tag: 'v0.3.0',
        assets: {'fvm-macos-arm64.zip': _zip()},
      );
      final binary = installedFvm();
      final modes = _RecordingModeApplier();

      await updaterFor(modeApplier: modes).update(executablePath: binary.path);

      // The temp path, not the final one: a binary that is only chmod-ed
      // after the rename is briefly on disk and not runnable.
      expect(modes.applied, [
        {'${binary.path}.new': 0x1ED},
      ]);
    });

    test('installs an explicitly named version, including an older one',
        () async {
      server
        ..publish(tag: 'v0.3.0', assets: {'fvm-macos-arm64.zip': _zip()})
        ..publish(
          tag: 'v0.2.0',
          assets: {'fvm-macos-arm64.zip': _zip(contents: 'fvm 0.2.0')},
        );
      final binary = installedFvm();

      final outcome = await updaterFor(currentVersion: '0.3.0').update(
        executablePath: binary.path,
        version: '0.2.0',
      );

      expect(outcome.to, '0.2.0');
      expect(binary.readAsStringSync(), 'fvm 0.2.0');
    });

    test('--check resolves the version and installs nothing', () async {
      server.publish(
        tag: 'v0.3.0',
        assets: {'fvm-macos-arm64.zip': _zip(contents: 'fvm 0.3.0')},
      );
      final binary = installedFvm();

      final outcome = await updaterFor().update(
        executablePath: binary.path,
        check: true,
      );

      expect(outcome.to, '0.3.0');
      expect(outcome.installed, isFalse);
      expect(binary.readAsStringSync(), 'the running fvm binary');
      // Not even the asset was fetched — only the release list.
      expect(
        server.requests.where((path) => path.contains('/download/')),
        isEmpty,
      );
    });

    test('says so and touches nothing when already on the newest', () async {
      server.publish(tag: 'v0.3.0', assets: {'fvm-macos-arm64.zip': _zip()});
      final binary = installedFvm();

      final outcome = await updaterFor(currentVersion: '0.3.0').update(
        executablePath: binary.path,
      );

      expect(outcome.isUpToDate, isTrue);
      expect(outcome.installed, isFalse);
      expect(binary.readAsStringSync(), 'the running fvm binary');
    });

    test('a checksum mismatch aborts and leaves the binary untouched',
        () async {
      final release = server.publish(
        tag: 'v0.3.0',
        assets: {'fvm-macos-arm64.zip': _zip(contents: 'fvm 0.3.0')},
      );
      // A checksum for the right asset name but the wrong bytes: the shape a
      // corrupted or swapped download actually has.
      release.assets['fvm-macos-arm64.zip.sha256'] = Uint8List.fromList(
        utf8.encode('${'0' * 64}  fvm-macos-arm64.zip\n'),
      );
      final binary = installedFvm();

      await expectLater(
        updaterFor().update(executablePath: binary.path),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            allOf(contains('NOT updated'), contains('sha256')),
          ),
        ),
      );

      expect(binary.readAsStringSync(), 'the running fvm binary');
      expect(fs.file('${binary.path}.new').existsSync(), isFalse);
      expect(fs.file('${binary.path}.old').existsSync(), isFalse);
    });

    test('refuses when the release publishes no checksum for the asset',
        () async {
      final release = server.publish(
        tag: 'v0.3.0',
        assets: {'fvm-macos-arm64.zip': _zip()},
      );
      release.hidden.add('fvm-macos-arm64.zip.sha256');
      final binary = installedFvm();

      await expectLater(
        updaterFor().update(executablePath: binary.path),
        throwsA(isA<UpdateException>().having(
          (e) => e.message,
          'message',
          contains('cannot be verified'),
        )),
      );
      expect(binary.readAsStringSync(), 'the running fvm binary');
    });

    test('refuses when the asset contains no fvm executable', () async {
      server.publish(
        tag: 'v0.3.0',
        assets: {
          'fvm-macos-arm64.zip': fakeReleaseZip(executableName: 'README.md'),
        },
      );
      final binary = installedFvm();

      await expectLater(
        updaterFor().update(executablePath: binary.path),
        throwsA(isA<UpdateException>().having(
          (e) => e.message,
          'message',
          contains('does not contain a fvm'),
        )),
      );
      expect(binary.readAsStringSync(), 'the running fvm binary');
    });

    test('refuses outright when fvm is running from source', () async {
      server.publish(tag: 'v0.3.0', assets: {'fvm-macos-arm64.zip': _zip()});

      await expectLater(
        updaterFor(isCompiled: false).update(executablePath: '/usr/bin/fvm'),
        throwsA(isA<UpdateException>().having(
          (e) => e.message,
          'message',
          contains('running from source'),
        )),
      );
      // Not even a request: there is nothing this could have done.
      expect(server.requests, isEmpty);
    });

    test('on windows moves the running exe aside instead of overwriting it',
        () async {
      // Windows refuses to delete or overwrite a running .exe but allows a
      // rename, which is the whole reason this path exists separately.
      final windows = MemoryFileSystem.test(style: FileSystemStyle.windows);
      server.publish(
        tag: 'v0.3.0',
        assets: {
          'fvm-windows-x64.zip': fakeReleaseZip(
            executableName: 'fvm.exe',
            contents: 'fvm 0.3.0',
          ),
        },
      );
      final binary = windows.file(r'C:\Users\dev\.fvm\bin\fvm.exe')
        ..createSync(recursive: true)
        ..writeAsStringSync('the running fvm binary');

      final outcome = await updaterFor(
        platform: const HostPlatform(os: 'windows', arch: 'x64'),
        fileSystem: windows,
      ).update(executablePath: binary.path);

      expect(outcome.installed, isTrue);
      expect(binary.readAsStringSync(), 'fvm 0.3.0');
      expect(
        windows.file(r'C:\Users\dev\.fvm\bin\fvm.exe.old').readAsStringSync(),
        'the running fvm binary',
        reason: 'the outgoing binary is renamed aside, never deleted',
      );
    });
  });

  test('a released version is newer than the dev build of the same number', () {
    // The first real release has to be announced to everyone running a
    // 0.1.0-dev built from source; semver says 0.1.0 > 0.1.0-dev.
    final updater = updaterFor(currentVersion: '0.1.0-dev');
    expect(updater.isNewerThanCurrent('0.1.0'), isTrue);
    expect(updater.isNewerThanCurrent('0.1.0-dev'), isFalse);
    // And string comparison would get this one backwards.
    expect(updaterFor(currentVersion: '0.9.0').isNewerThanCurrent('0.13.0'),
        isTrue);
  });
}

Uint8List _zip({String contents = 'a new fvm binary'}) =>
    fakeReleaseZip(contents: contents);

/// A [ModeApplier] that records what it was asked to apply instead of
/// shelling out to `chmod`, which has nothing to work on in a memory
/// filesystem.
class _RecordingModeApplier implements ModeApplier {
  final List<Map<String, int>> applied = [];

  @override
  Future<void> apply(Map<String, int> modeByPath) async =>
      applied.add(modeByPath);
}
