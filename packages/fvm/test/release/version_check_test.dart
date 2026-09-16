import 'dart:convert';
import 'dart:typed_data';

import 'package:fvm/fvm.dart';
import 'package:fvm/fvm.dart' as fvm;
import 'package:file/memory.dart';
import 'package:test/test.dart';

import 'fake_github_server.dart';

/// The ambient "a newer fvm exists" notice.
///
/// Its hard requirement is negative — it must never block, slow or fail a
/// command — so most of what is asserted here is that something did NOT
/// happen: no notice, no non-zero exit, no second request.
void main() {
  late MemoryFileSystem fs;
  late StringBuffer out;
  late StringBuffer err;

  const fvmHome = '/fvm';
  final environment = {'FVM_HOME': fvmHome, 'HOME': '/home/dev', 'PATH': ''};

  setUp(() {
    fs = MemoryFileSystem.test();
    out = StringBuffer();
    err = StringBuffer();
  });

  FvmPaths pathsFor() => FvmPaths(fileSystem: fs, environment: environment);

  /// An updater whose API base is a port nothing is listening on, so any
  /// attempt to reach the network is both visible and fast to fail.
  Updater offlineUpdater({
    bool isCompiled = true,
    String currentVersion = '0.1.0',
  }) =>
      Updater(
        fileSystem: fs,
        hostPlatform: () => const HostPlatform(os: 'macos', arch: 'arm64'),
        environment: const {},
        apiBase: Uri.parse('http://127.0.0.1:1/repos/mrgnhnt96/fvm/'),
        isCompiled: isCompiled,
        currentVersion: currentVersion,
      );

  /// Records an answer in the cache, as a check within the TTL would have.
  void warmCache(String? latest, {Duration age = Duration.zero}) {
    final paths = pathsFor();
    paths.cacheDir.createSync(recursive: true);
    fs
        .file(fs.path.join(paths.cacheDir.path, 'update-check.json'))
        .writeAsStringSync(jsonEncode({
          'checkedAt': DateTime.now().subtract(age).millisecondsSinceEpoch,
          'latest': latest,
        }));
  }

  Future<int> runFvm(List<String> args, {required Updater updater}) => fvm.run(
        args,
        fileSystem: fs,
        environment: environment,
        platformVersion: '3.13.2 (stable) on "macos_arm64"',
        out: out,
        err: err,
        updater: updater,
        executablePath: '/usr/local/bin/fvm',
      );

  group('through the real entrypoint', () {
    test('an ordinary command reports a newer release on stderr', () async {
      warmCache('0.9.0');

      expect(await runFvm(['list'], updater: offlineUpdater()), 0);
      expect(
        err.toString(),
        allOf(contains('0.1.0 -> 0.9.0'), contains('fvm update')),
      );
      // stdout is what a script reads; the notice must stay out of it.
      expect(out.toString(), isNot(contains('0.9.0')));
    });

    test('--no-version-check suppresses it entirely', () async {
      warmCache('0.9.0');

      expect(
        await runFvm(['--no-version-check', 'list'], updater: offlineUpdater()),
        0,
      );
      expect(err.toString(), isEmpty);
    });

    test('a source build never checks at all', () async {
      warmCache('0.9.0');

      expect(
        await runFvm(['list'], updater: offlineUpdater(isCompiled: false)),
        0,
      );
      expect(err.toString(), isEmpty);
    });

    test('says nothing when the cached answer is not newer', () async {
      warmCache('0.1.0');

      expect(await runFvm(['list'], updater: offlineUpdater()), 0);
      expect(err.toString(), isEmpty);
    });

    test('a dead network is invisible: no notice, no error, no failure',
        () async {
      // Nothing is listening on port 1. The command must succeed anyway and
      // say nothing about it — this is the `fvm flutter test` case.
      expect(await runFvm(['list'], updater: offlineUpdater()), 0);
      expect(err.toString(), isEmpty);
    });

    test('a missing fvm home does not turn into an error', () async {
      // No FVM_HOME and no HOME: FvmPaths throws when asked where the cache
      // lives, and the check has to swallow that like any other failure.
      expect(
        await fvm.run(
          ['--help'],
          fileSystem: fs,
          environment: const {},
          platformVersion: '3.13.2 (stable) on "macos_arm64"',
          out: out,
          err: err,
          updater: offlineUpdater(),
          executablePath: '/usr/local/bin/fvm',
        ),
        0,
      );
      expect(err.toString(), isEmpty);
    });

    test('the update command does not also print the ambient notice', () async {
      warmCache('0.9.0');

      // It fails (nothing is listening), but the point is that the notice is
      // not appended to a command whose entire job is to say this better.
      await runFvm(['update', '--check'], updater: offlineUpdater());
      expect(err.toString(), isNot(contains('Run `fvm update`')));
    });
  });

  group('the cache', () {
    late FakeGitHubServer server;

    setUp(() async {
      server = await FakeGitHubServer.start();
      server.publish(tag: 'v0.9.0', assets: {'fvm-macos-arm64.zip': _asset()});
    });

    tearDown(() => server.close());

    Updater liveUpdater() => Updater(
          fileSystem: fs,
          hostPlatform: () => const HostPlatform(os: 'macos', arch: 'arm64'),
          environment: const {},
          apiBase: server.apiBase,
          isCompiled: true,
          currentVersion: '0.1.0',
        );

    VersionCheck checkFor(Updater updater) => VersionCheck(
          updater: updater,
          paths: pathsFor(),
          out: err,
          // Generous on purpose: this test is about caching, and a budget
          // tight enough to be a timing test would be flaky rather than
          // informative.
          reportBudget: const Duration(seconds: 5),
          networkTimeout: const Duration(seconds: 5),
        );

    test('is written on the first check and answers the second', () async {
      await (checkFor(liveUpdater())..start()).report();
      expect(err.toString(), contains('0.1.0 -> 0.9.0'));
      final afterFirst = server.requests.length;
      expect(afterFirst, greaterThan(0));

      err.clear();
      await (checkFor(liveUpdater())..start()).report();

      expect(err.toString(), contains('0.1.0 -> 0.9.0'));
      expect(
        server.requests.length,
        afterFirst,
        reason: 'a cached answer must cost no request at all',
      );
    });

    test('goes back to the network once the entry is older than the TTL',
        () async {
      warmCache('0.9.0', age: const Duration(days: 2));

      await (checkFor(liveUpdater())..start()).report();

      expect(server.requests, isNotEmpty);
    });

    test(
        'records the attempt before the request, so a slow link is charged '
        'once per TTL rather than once per command', () async {
      // The budget is zero, so [report] gives up before any answer can
      // arrive — the case where a real process would exit mid-request.
      final check = VersionCheck(
        updater: liveUpdater(),
        paths: pathsFor(),
        out: err,
        reportBudget: Duration.zero,
      )..start();
      await check.report();

      expect(err.toString(), isEmpty);
      expect(
        check.cacheFile.existsSync(),
        isTrue,
        reason: 'without a stamp, the next invocation pays the budget again',
      );
    });

    test('records a failed check so an offline machine stops retrying',
        () async {
      await (checkFor(offlineUpdater())..start()).report();

      expect(err.toString(), isEmpty);
      final paths = pathsFor();
      final cache = fs.file(
        fs.path.join(paths.cacheDir.path, 'update-check.json'),
      );
      expect(cache.existsSync(), isTrue);
      expect(
        jsonDecode(cache.readAsStringSync()),
        containsPair('latest', isNull),
      );
    });
  });
}

Uint8List _asset() => fakeReleaseZip();
