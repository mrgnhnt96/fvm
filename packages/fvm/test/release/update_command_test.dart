import 'package:fvm/fvm.dart';
import 'package:fvm/fvm.dart' as fvm;
import 'package:fvm/src/archive/sdk_extractor.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

import 'fake_github_server.dart';

/// `fvm update` end to end: the real entrypoint, the real command, the real
/// updater, against a local server and a memory filesystem.
void main() {
  late FakeGitHubServer server;
  late MemoryFileSystem fs;
  late StringBuffer out;
  late StringBuffer err;

  const executablePath = '/usr/local/bin/fvm';
  const environment = {'FVM_HOME': '/fvm', 'HOME': '/home/dev', 'PATH': ''};

  setUp(() async {
    server = await FakeGitHubServer.start();
    fs = MemoryFileSystem.test();
    fs.file(executablePath)
      ..createSync(recursive: true)
      ..writeAsStringSync('the running fvm binary');
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() => server.close());

  Future<int> runFvm(List<String> args, {String currentVersion = '0.1.0'}) =>
      fvm.run(
        args,
        fileSystem: fs,
        environment: environment,
        platformVersion: '3.13.2 (stable) on "macos_arm64"',
        out: out,
        err: err,
        executablePath: executablePath,
        updater: Updater(
          fileSystem: fs,
          hostPlatform: () => const HostPlatform(os: 'macos', arch: 'arm64'),
          environment: const {},
          apiBase: server.apiBase,
          isCompiled: true,
          currentVersion: currentVersion,
          modeApplier: const NoopModeApplier(),
        ),
      );

  String installedBinary() => fs.file(executablePath).readAsStringSync();

  test('is registered and reachable from the command line', () async {
    server.publish(
      tag: 'v0.3.0',
      assets: {'fvm-macos-arm64.zip': fakeReleaseZip(contents: 'fvm 0.3.0')},
    );

    expect(await runFvm(['update']), 0);
    expect(out.toString(), contains('Updated fvm 0.1.0 -> 0.3.0'));
    expect(installedBinary(), 'fvm 0.3.0');
  });

  test('--check reports the newer version and installs nothing', () async {
    server.publish(
      tag: 'v0.3.0',
      assets: {'fvm-macos-arm64.zip': fakeReleaseZip(contents: 'fvm 0.3.0')},
    );

    expect(await runFvm(['update', '--check']), 0);
    expect(out.toString(), contains('0.1.0 -> 0.3.0'));
    expect(installedBinary(), 'the running fvm binary');
  });

  test('an explicit version installs that release', () async {
    server
      ..publish(
          tag: 'v0.3.0', assets: {'fvm-macos-arm64.zip': fakeReleaseZip()})
      ..publish(
        tag: 'v0.2.0',
        assets: {'fvm-macos-arm64.zip': fakeReleaseZip(contents: 'fvm 0.2.0')},
      );

    expect(await runFvm(['update', '0.2.0'], currentVersion: '0.3.0'), 0);
    expect(installedBinary(), 'fvm 0.2.0');
  });

  test('says so when already current', () async {
    server.publish(
      tag: 'v0.3.0',
      assets: {'fvm-macos-arm64.zip': fakeReleaseZip()},
    );

    expect(await runFvm(['update'], currentVersion: '0.3.0'), 0);
    expect(out.toString(), contains('already up to date'));
  });

  test('a failure is a message and exit 1, not a stack trace', () async {
    server.publish(
      tag: 'v0.3.0',
      assets: {'fvm-linux-x64.zip': fakeReleaseZip()},
    );

    expect(await runFvm(['update']), 1);
    expect(err.toString(), startsWith('fvm: '));
    expect(err.toString(), contains('fvm-macos-arm64.zip'));
    expect(err.toString(), isNot(contains('#0')));
    expect(installedBinary(), 'the running fvm binary');
  });

  test('more than one version is a usage error', () async {
    expect(await runFvm(['update', '0.2.0', '0.3.0']), usageExitCode);
    expect(err.toString(), contains('at most one version'));
  });
}
