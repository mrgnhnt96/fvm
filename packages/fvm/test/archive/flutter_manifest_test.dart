import 'dart:convert';

import 'package:fvm/fvm.dart';
import 'package:fvm/src/archive/flutter_archive_client.dart';
import 'package:fvm/src/archive/flutter_archive_exception.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  const arm = HostPlatform(os: 'macos', arch: 'arm64');
  Map<String, Object> release(String version,
          {String? arch, String? checksum}) =>
      {
        'version': version,
        'hash': 'release-$version',
        'channel': 'stable',
        if (arch != null) 'dart_sdk_arch': arch,
        'archive':
            'stable/macos/flutter_macos_${arch ?? 'x64'}_$version-stable.zip',
        'sha256': checksum ?? 'a' * 64,
      };
  FlutterArchiveClient client(List<Map<String, Object>> entries) =>
      FlutterArchiveClient(
          platform: arm,
          httpClient: MockClient((request) async {
            expect(request.url.path, endsWith('/releases/releases_macos.json'));
            return http.Response(
                jsonEncode({
                  'current_release': {'stable': 'release-3.44.0'},
                  'releases': entries
                }),
                200);
          }));

  test('selects native architecture and interprets old missing arch as x64',
      () async {
    final api = client([
      release('3.44.0'),
      release('3.44.0', arch: 'arm64'),
      release('3.10.0')
    ]);
    expect(await api.listReleases(Channel.stable), ['3.44.0']);
    expect(await api.latestVersion(Channel.stable), '3.44.0');
    final artifact = await api.artifactFor(
        channel: Channel.stable, version: '3.44.0', platform: arm);
    expect(artifact.fileName, 'flutter_macos_arm64_3.44.0-stable.zip');
    expect(artifact.sha256, 'a' * 64);
  });
  test('does not silently substitute x64 for unavailable arm64', () async {
    final api = client([release('3.44.0')]);
    expect(() => api.latestVersion(Channel.stable),
        throwsA(isA<FlutterArchiveException>()));
    expect(
        () => api.artifactFor(
            channel: Channel.stable, version: '3.44.0', platform: arm),
        throwsA(isA<FlutterArchiveException>()));
  });
  test('rejects invalid manifest checksums', () async {
    final api = client([release('3.44.0', arch: 'arm64', checksum: 'oops')]);
    expect(
        () => api.artifactFor(
            channel: Channel.stable, version: '3.44.0', platform: arm),
        throwsA(isA<FlutterArchiveException>()));
  });
  test('malformed JSON reports a domain error', () async {
    final api = FlutterArchiveClient(
        platform: arm,
        httpClient: MockClient((_) async => http.Response('{', 200)));
    expect(() => api.listReleases(Channel.stable),
        throwsA(isA<FlutterArchiveException>()));
  });
}
