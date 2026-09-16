import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

/// A stand-in for the `flutter-archive` bucket, bound to a loopback port.
///
/// Every test in this directory drives the real client and the real installer
/// against this instead of the network: nothing here downloads 225MB, and a
/// green suite on a machine with no internet means the same thing as one with.
class FakeArchiveServer {
  FakeArchiveServer._(this._server) {
    _server.listen(_handle);
  }

  static Future<FakeArchiveServer> start() async => FakeArchiveServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;

  /// Channel token -> the release directory names the bucket lists.
  final Map<String, List<String>> prefixes = {};

  /// Channel token -> the version `latest/VERSION` reports.
  final Map<String, String> latest = {};

  /// `<channel>/<version>/<filename>` -> the archive bytes served for it.
  final Map<String, Uint8List> archives = {};

  /// Overrides the checksum body for `<channel>/<version>/<filename>`. Without
  /// an entry the server publishes the true sha256 of what it serves.
  final Map<String, String> checksumOverrides = {};

  /// Every path this server was asked for, in order.
  final List<String> requests = [];

  Uri get objectBase => Uri.parse('http://${_server.address.host}:'
      '${_server.port}/flutter-archive/');

  Uri get listApi => Uri.parse('http://${_server.address.host}:'
      '${_server.port}/storage/v1/b/flutter-archive/o');

  Future<void> close() => _server.close(force: true);

  /// Publishes [bytes] as `<channel>/<version>`'s SDK archive.
  void publish({
    required String channel,
    required String version,
    required String fileName,
    required Uint8List bytes,
  }) {
    archives['$channel/$version/$fileName'] = bytes;
    (prefixes[channel] ??= []).add(version);
  }

  Future<void> _handle(HttpRequest request) async {
    requests.add(request.uri.toString());
    final response = request.response;

    if (request.uri.path.contains('/releases/releases_')) {
      final releases = <Map<String, Object?>>[];
      for (final channel in {...prefixes.keys, ...latest.keys}) {
        for (final version in {
          ...?prefixes[channel],
          if (latest[channel] != null) latest[channel]!
        }) {
          final matches = archives.keys
              .where((key) => key.startsWith('$channel/$version/'));
          for (final arch in ['x64', 'arm64']) {
            final key = matches.isEmpty ? null : matches.first;
            releases.add({
              'version': version,
              'channel': channel,
              'hash': '$channel-$version',
              'dart_sdk_arch': arch,
              if (key != null)
                'archive':
                    'channels/$channel/release/$version/sdk/${key.split('/').last}',
              if (key != null)
                'sha256': checksumOverrides[key] ??
                    sha256.convert(archives[key]!).toString(),
            });
          }
        }
      }
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({
        'current_release': {
          for (final entry in latest.entries)
            entry.key: '${entry.key}-${entry.value}',
        },
        'releases': releases
      }));
      await response.close();
      return;
    }
    final listing = _listing(request.uri);
    if (listing != null) {
      response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(listing));
      await response.close();
      return;
    }

    const objectPrefix = '/flutter-archive/';
    if (!request.uri.path.startsWith(objectPrefix)) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final path = request.uri.path.substring(objectPrefix.length);

    final body = _object(path);
    if (body == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    response
      ..statusCode = 200
      ..contentLength = body.length
      ..add(body);
    await response.close();
  }

  /// The GCS JSON API's `prefixes` answer, or null if [uri] is not a listing.
  Map<String, Object?>? _listing(Uri uri) {
    if (uri.path != '/storage/v1/b/flutter-archive/o') return null;
    final prefix = uri.queryParameters['prefix'] ?? '';
    final match = RegExp(r'^channels/([^/]+)/release/$').firstMatch(prefix);
    if (match == null) return const {};
    final entries = prefixes[match.group(1)] ?? const [];
    return {
      'prefixes': [for (final entry in entries) '$prefix$entry/'],
    };
  }

  List<int>? _object(String path) {
    final version = RegExp(
      r'^channels/([^/]+)/release/([^/]+)/VERSION$',
    ).firstMatch(path);
    if (version != null) {
      final channel = version.group(1)!;
      final release = version.group(2)!;
      if (release == 'latest') {
        final resolved = latest[channel];
        return resolved == null
            ? null
            : utf8.encode(jsonEncode({'version': resolved}));
      }
      final known = prefixes[channel]?.contains(release) ?? false;
      return known ? utf8.encode(jsonEncode({'version': release})) : null;
    }

    final sdk = RegExp(
      r'^channels/([^/]+)/release/([^/]+)/sdk/(.+?)(\.sha256sum)?$',
    ).firstMatch(path);
    if (sdk == null) return null;

    final key = '${sdk.group(1)}/${sdk.group(2)}/${sdk.group(3)}';
    final bytes = archives[key];
    if (bytes == null) return null;

    if (sdk.group(4) == null) return bytes;
    final override = checksumOverrides[key];
    final digest = override ?? sha256.convert(bytes).toString();
    return utf8.encode('$digest *${sdk.group(3)}\n');
  }
}

/// A miniature SDK zip: enough shape for the installer to accept it, small
/// enough that a test can build one per case.
Uint8List fakeSdkZip({
  String version = '3.13.2',
  String root = 'flutter-sdk',
  String flutterExecutableName = 'flutter',
  int flutterMode = 0x1ED,
  int versionFileMode = 0x1A4,
}) {
  final archive = Archive()
    ..add(
      ArchiveFile.string(
          '$root/bin/$flutterExecutableName', '#!/bin/sh\nexit 0\n')
        ..mode = flutterMode,
    )
    ..add(ArchiveFile.string('$root/version', '$version\n')
      ..mode = versionFileMode)
    ..add(ArchiveFile.string('$root/lib/core/core.dart', '// core\n')
      ..mode = versionFileMode);
  return ZipEncoder().encodeBytes(archive);
}
