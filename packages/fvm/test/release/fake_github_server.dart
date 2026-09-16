import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

/// A stand-in for GitHub's releases API, bound to a loopback port.
///
/// Every updater test drives the real [Updater] against this instead of
/// api.github.com: nothing here touches the network, so a green suite means
/// the same thing offline, in CI, and behind a rate limit. Modelled on
/// `test/archive/fake_archive_server.dart`, which does the same job for the
/// Flutter SDK archive.
class FakeGitHubServer {
  FakeGitHubServer._(this._server) {
    _server.listen(_handle);
  }

  static Future<FakeGitHubServer> start() async => FakeGitHubServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;

  /// Newest first, the way GitHub returns them.
  final List<FakeRelease> releases = [];

  /// Every path this server was asked for, in order.
  final List<String> requests = [];

  /// When set, every request gets this status instead of an answer.
  int? failWith;

  Uri get apiBase =>
      Uri.parse('http://${_server.address.host}:${_server.port}/repos/'
          'mrgnhnt96/fvm/');

  Future<void> close() => _server.close(force: true);

  /// Publishes a release. Assets are `name -> bytes`; a `.sha256` sibling is
  /// generated for each one unless the test supplies its own.
  FakeRelease publish({
    required String tag,
    Map<String, Uint8List> assets = const {},
    bool draft = false,
    bool prerelease = false,
  }) {
    final release = FakeRelease(
      tag: tag,
      draft: draft,
      prerelease: prerelease,
      assets: {...assets},
    );
    for (final entry in assets.entries) {
      release.assets['${entry.key}.sha256'] = Uint8List.fromList(
        utf8.encode('${sha256.convert(entry.value)}  ${entry.key}\n'),
      );
    }
    releases.add(release);
    return release;
  }

  Future<void> _handle(HttpRequest request) async {
    requests.add(request.uri.toString());
    final response = request.response;

    final failure = failWith;
    if (failure != null) {
      response.statusCode = failure;
      await response.close();
      return;
    }

    final path = request.uri.path;
    Object? body;
    List<int>? bytes;

    if (path == '/repos/mrgnhnt96/fvm/releases') {
      body = [for (final release in releases) release.toJson(this)];
    } else if (RegExp(r'^/repos/mrgnhnt96/fvm/releases/tags/(.+)$')
            .firstMatch(path)
        case final match?) {
      final tag = match.group(1);
      for (final release in releases) {
        if (release.tag == tag) body = release.toJson(this);
      }
    } else if (RegExp(r'^/download/([^/]+)/(.+)$').firstMatch(path)
        case final match?) {
      for (final release in releases) {
        if (release.tag != match.group(1)) continue;
        bytes = release.assets[match.group(2)];
      }
    }

    if (bytes != null) {
      response
        ..statusCode = 200
        ..contentLength = bytes.length
        ..add(bytes);
      await response.close();
      return;
    }

    if (body == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await response.close();
  }

  Uri downloadUrl(String tag, String assetName) => Uri.parse(
        'http://${_server.address.host}:${_server.port}/download/$tag/'
        '$assetName',
      );
}

/// One release on a [FakeGitHubServer].
class FakeRelease {
  FakeRelease({
    required this.tag,
    required this.draft,
    required this.prerelease,
    required this.assets,
  });

  final String tag;
  final bool draft;
  final bool prerelease;

  /// Asset name -> the bytes served for it.
  final Map<String, Uint8List> assets;

  /// The subset of [assets] the API lists. Everything, unless a test drops a
  /// name here to model a release that is missing one.
  final Set<String> hidden = {};

  Map<String, Object?> toJson(FakeGitHubServer server) => {
        'tag_name': tag,
        'draft': draft,
        'prerelease': prerelease,
        'assets': [
          for (final name in assets.keys)
            if (!hidden.contains(name))
              {
                'name': name,
                'browser_download_url':
                    server.downloadUrl(tag, name).toString(),
              },
        ],
      };
}

/// A release asset: a zip holding one bare executable, as
/// `tool/package_release_assets.sh` builds it.
Uint8List fakeReleaseZip({
  String executableName = 'fvm',
  String contents = 'a new fvm binary',
}) {
  final archive = Archive()
    ..add(ArchiveFile.string(executableName, contents)..mode = 0x1ED);
  return ZipEncoder().encodeBytes(archive);
}
