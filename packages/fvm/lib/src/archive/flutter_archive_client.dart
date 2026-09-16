import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';

import '../core/channel.dart';
import '../core/platform.dart';
import '../core/releases.dart';
import '../core/verbose.dart';
import 'flutter_archive_exception.dart';

/// Reads Flutter's platform-specific release manifests.
class FlutterArchiveClient implements ReleaseClient {
  FlutterArchiveClient(
      {http.Client? httpClient,
      Uri? objectBase,
      HostPlatform? platform,
      VerboseLog? verbose})
      : _injectedHttp = httpClient,
        _base = objectBase ?? defaultObjectBase,
        _injectedPlatform = platform,
        _verbose = verbose ?? VerboseLog.disabled;

  static final Uri defaultObjectBase = Uri.parse(
      'https://storage.googleapis.com/flutter_infra_release/releases/');
  final http.Client? _injectedHttp;
  late final http.Client _http = _injectedHttp ?? http.Client();
  final Uri _base;
  final HostPlatform? _injectedPlatform;
  late final HostPlatform _platform =
      _injectedPlatform ?? HostPlatform.detect(Platform.version);
  final VerboseLog _verbose;
  final Map<String, Map<String, dynamic>> _manifests = {};

  Future<Map<String, dynamic>> _manifest(HostPlatform platform) async {
    if (_manifests[platform.os] case final cached?) return cached;
    final url = _base.resolve('releases_${platform.os}.json');
    _verbose.log(VerboseArea.net, () => 'GET $url');
    try {
      final response = await _http.get(url);
      if (response.statusCode != 200) {
        throw FlutterArchiveException('Flutter releases returned HTTP '
            '${response.statusCode} ($url).');
      }
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic> ||
          body['releases'] is! List ||
          body['current_release'] is! Map) {
        throw const FormatException('Missing releases or current_release');
      }
      return _manifests[platform.os] = body;
    } on FormatException catch (error) {
      throw FlutterArchiveException('Invalid Flutter release manifest: $error');
    } on http.ClientException catch (error) {
      throw FlutterArchiveException('Could not reach Flutter releases: $error');
    }
  }

  List<Map<String, dynamic>> _entries(
          Map<String, dynamic> manifest, HostPlatform platform) =>
      (manifest['releases'] as List)
          .whereType<Map<String, dynamic>>()
          .where((entry) => (entry['dart_sdk_arch'] ?? 'x64') == platform.arch)
          .toList();

  @override
  Future<List<String>> listReleases(Channel channel) async {
    final manifest = await _manifest(_platform);
    final versions = _entries(manifest, _platform)
        .where((entry) => entry['channel'] == channel.token)
        .map((entry) => entry['version'])
        .whereType<String>()
        .where((v) => tryParseRelease(v) != null)
        .toSet()
        .toList();
    versions.sort((a, b) => Version.parse(b).compareTo(Version.parse(a)));
    return versions;
  }

  @override
  Future<String> latestVersion(Channel channel) async {
    final manifest = await _manifest(_platform);
    final hash = (manifest['current_release'] as Map)[channel.token];
    for (final entry in _entries(manifest, _platform)) {
      if (entry['hash'] == hash &&
          entry['channel'] == channel.token &&
          entry['version'] is String) {
        return entry['version'] as String;
      }
    }
    throw FlutterArchiveException('No current ${channel.token} Flutter archive '
        'for $_platform. Use stable, beta, or a published version.');
  }

  @override
  Future<Channel> channelFor(String version) async {
    final entries = _entries(await _manifest(_platform), _platform);
    for (final channel in Channel.probeOrder) {
      if (entries.any(
          (e) => e['version'] == version && e['channel'] == channel.token)) {
        return channel;
      }
    }
    throw FlutterArchiveException('Flutter $version is not published for '
        '$_platform. Run `fvm list-remote` to see available versions.');
  }

  @override
  Future<ReleaseArtifact> artifactFor(
      {required Channel channel,
      required String version,
      required HostPlatform platform}) async {
    final entries = _entries(await _manifest(platform), platform);
    for (final entry in entries) {
      if (entry['version'] != version || entry['channel'] != channel.token) {
        continue;
      }
      final archive = entry['archive'];
      final checksum = entry['sha256'];
      if (archive is! String ||
          checksum is! String ||
          !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(checksum)) {
        throw const FlutterArchiveException(
            'Release is missing its archive or SHA-256.');
      }
      final uri = _base.resolve(archive);
      if (uri.origin != _base.origin || archive.contains('..')) {
        throw const FlutterArchiveException(
            'Unsafe archive URL in release manifest.');
      }
      return ReleaseArtifact(
          version: version,
          fileName: uri.pathSegments.last,
          archive: uri,
          checksum: uri,
          sha256: checksum);
    }
    throw FlutterArchiveException('Flutter $version (${channel.token}) has no '
        'archive for $platform.');
  }
}

Version? tryParseRelease(String token) {
  try {
    return Version.parse(token);
  } on FormatException {
    return null;
  }
}
