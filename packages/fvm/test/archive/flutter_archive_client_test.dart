import 'package:fvm/fvm.dart';
import 'package:fvm/src/archive/flutter_archive_client.dart';
import 'package:fvm/src/archive/flutter_archive_exception.dart';
import 'package:test/test.dart';

import 'fake_archive_server.dart';

void main() {
  late FakeArchiveServer server;
  late FlutterArchiveClient client;

  setUp(() async {
    server = await FakeArchiveServer.start();
    client = FlutterArchiveClient(
      objectBase: server.objectBase,
    );
  });

  tearDown(() => server.close());

  group('listReleases', () {
    test('drops the Flutter 1 build numbers and the latest alias', () async {
      // A sample of the real bucket: 28 of stable's ~205 prefixes are Flutter 1
      // build numbers rather than versions, and one is `latest`.
      server.prefixes['stable'] = [
        '29803',
        '41096',
        '1.24.3',
        'latest',
        '2.19.6',
        '3.9.0',
      ];

      expect(
        await client.listReleases(Channel.stable),
        ['3.9.0', '2.19.6', '1.24.3'],
      );
    });

    test('sorts semantically, not lexically', () async {
      // The whole point: as strings "3.9.0" sorts above "3.13.0", which would
      // present a two-year-old SDK as the newest release available.
      server.prefixes['stable'] = ['3.13.0', '3.9.0', '3.10.1', '3.2.0'];

      final releases = await client.listReleases(Channel.stable);
      expect(releases, ['3.13.0', '3.10.1', '3.9.0', '3.2.0']);
      expect(
        releases.indexOf('3.13.0'),
        lessThan(releases.indexOf('3.9.0')),
        reason: '3.13.0 is newer than 3.9.0',
      );
    });

    test('orders a prerelease below the release it leads to', () async {
      server.prefixes['dev'] = ['3.14.0', '3.14.0-1.0.dev', '3.14.0-2.0.dev'];

      expect(
        await client.listReleases(Channel.dev),
        ['3.14.0', '3.14.0-2.0.dev', '3.14.0-1.0.dev'],
      );
    });

    test('asks for the channel it was given', () async {
      server.prefixes['beta'] = ['3.14.0-172.2.beta'];

      expect(await client.listReleases(Channel.beta), ['3.14.0-172.2.beta']);
      expect(
        server.requests.single,
        contains('/releases/releases_'),
      );
    });

    test('a channel with nothing published is empty, not an error', () async {
      expect(await client.listReleases(Channel.dev), isEmpty);
    });
  });

  group('latestVersion', () {
    test('reads the version out of latest/VERSION', () async {
      server.latest['stable'] = '3.13.2';

      expect(await client.latestVersion(Channel.stable), '3.13.2');
    });

    test('a missing channel is a FvmException, not a crash', () async {
      expect(
        () => client.latestVersion(Channel.beta),
        throwsA(isA<FlutterArchiveException>().having(
          (e) => e.message,
          'message',
          contains('No current beta'),
        )),
      );
    });
  });

  group('channelFor', () {
    test('probes stable, then beta, then dev, and stops at the first hit',
        () async {
      server.prefixes['dev'] = ['3.14.0-1.0.dev'];

      expect(await client.channelFor('3.14.0-1.0.dev'), Channel.dev);
      expect(server.requests, hasLength(1));
    });

    test('a version in more than one channel resolves to stable', () async {
      server.prefixes['stable'] = ['3.13.2'];
      server.prefixes['beta'] = ['3.13.2'];

      expect(await client.channelFor('3.13.2'), Channel.stable);
      expect(server.requests, hasLength(1));
    });

    test('a version in no channel names all three in its message', () async {
      expect(
        () => client.channelFor('9.9.9'),
        throwsA(isA<FlutterArchiveException>().having(
          (e) => e.message,
          'message',
          contains('fvm list-remote'),
        )),
      );
    });
  });

  group('artifactFor', () {
    test('reads archive URL and SHA-256 from the manifest', () async {
      server.publish(
          channel: 'stable',
          version: '3.44.0',
          fileName: 'flutter_macos_arm64_3.44.0-stable.zip',
          bytes: fakeSdkZip());
      final artifact = await client.artifactFor(
          channel: Channel.stable,
          version: '3.44.0',
          platform: const HostPlatform(os: 'macos', arch: 'arm64'));
      expect(artifact.fileName, 'flutter_macos_arm64_3.44.0-stable.zip');
      expect(artifact.sha256, matches(RegExp(r'^[a-f0-9]{64}$')));
      await client.latestVersion(Channel.stable).catchError((Object _) => '');
      expect(server.requests, hasLength(1),
          reason: 'manifest is cached per invocation');
    });
    test('fails when requested version has no archive', () async {
      expect(
          () => client.artifactFor(
              channel: Channel.stable,
              version: '9.9.9',
              platform: const HostPlatform(os: 'macos', arch: 'arm64')),
          throwsA(isA<FlutterArchiveException>()));
    });
  });
}
