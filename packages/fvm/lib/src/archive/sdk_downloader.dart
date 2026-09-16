import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:file/file.dart';
import 'package:http/http.dart' as http;

import '../core/releases.dart';
import '../core/style.dart';
import '../core/verbose.dart';
import 'flutter_archive_exception.dart';
import 'progress_bar.dart';

/// Streams an SDK archive to disk and proves it arrived intact.
///
/// The bytes are hashed as they stream past rather than by re-reading the file
/// afterwards: these archives are ~225MB, and neither buffering one in memory
/// nor reading it twice is free.
class SdkDownloader {
  SdkDownloader({
    required this.fileSystem,
    required StringSink progress,
    bool progressIsTerminal = false,
    Styles? styles,
    http.Client? httpClient,
    VerboseLog? verbose,
  })  : _injectedHttp = httpClient,
        _progress = progress,
        _progressIsTerminal = progressIsTerminal,
        _styles = styles ?? Styles(),
        _verbose = verbose ?? VerboseLog.disabled;

  final FileSystem fileSystem;
  final StringSink _progress;

  /// Whether [_progress] is a terminal a human is watching.
  ///
  /// Defaults to false because that is the shape that survives being read by
  /// something other than a person; the composition root is the only place
  /// that can honestly answer this.
  final bool _progressIsTerminal;

  final Styles _styles;
  final http.Client? _injectedHttp;
  final VerboseLog _verbose;

  /// Built on first use; see [FlutterArchiveClient] for why that matters.
  late final http.Client _http = _injectedHttp ?? http.Client();

  /// Downloads [artifact] to [destination] and verifies its sha256.
  ///
  /// Throws [FlutterArchiveException] and deletes [destination] if the checksum does
  /// not match, so a corrupted or tampered archive is never handed on to be
  /// extracted.
  Future<void> download(ReleaseArtifact artifact, File destination) async {
    _verbose.log(
      VerboseArea.install,
      () => 'downloading ${artifact.fileName} to ${destination.path}',
    );
    final expected = await _expectedChecksum(artifact);
    _verbose.log(VerboseArea.net, () => '  expected sha256 $expected');

    destination.parent.createSync(recursive: true);
    final elapsed = _verbose.stopwatch();
    final actual = await _streamToFile(artifact.archive, destination);
    _verbose.log(
      VerboseArea.install,
      () => '  wrote ${destination.lengthSync()} bytes in '
          '${elapsed!.elapsedMilliseconds}ms, sha256 $actual',
    );

    if (actual != expected) {
      // Deleting here rather than leaving it for the caller means the bad
      // bytes cannot be picked up by a later run that only checks existence.
      if (destination.existsSync()) destination.deleteSync();
      throw FlutterArchiveException(
        'The download of ${artifact.fileName} does not match its published '
        'sha256 checksum.\n'
        '  expected: $expected\n'
        '  actual:   $actual\n'
        'Nothing was installed. This is either a corrupted download or a '
        'tampered-with archive; run the install again.',
      );
    }
  }

  /// The hex sha256 the archive is published with.
  ///
  /// The body is `<hex> *<filename>`; the filename is checked too, because a
  /// checksum for a different platform's archive would otherwise fail later
  /// with a mismatch that reads like corruption.
  Future<String> _expectedChecksum(ReleaseArtifact artifact) async {
    if (artifact.sha256 case final checksum?) {
      if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(checksum)) {
        throw const FlutterArchiveException(
            'Invalid SHA-256 in release manifest.');
      }
      return checksum.toLowerCase();
    }
    _verbose.log(VerboseArea.net, () => 'GET ${artifact.checksum}');
    final http.Response response;
    try {
      response = await _http.get(artifact.checksum);
    } on http.ClientException catch (error) {
      throw FlutterArchiveException(
        'Could not fetch the checksum for ${artifact.fileName}: '
        '${error.message}',
      );
    }
    _verbose.log(
      VerboseArea.net,
      () => '  HTTP ${response.statusCode}',
    );
    if (response.statusCode != 200) {
      throw FlutterArchiveException(
        'The Flutter archive returned HTTP ${response.statusCode} for the '
        'checksum of ${artifact.fileName} (${artifact.checksum}).',
      );
    }

    _verbose.log(
      VerboseArea.net,
      () => '  checksum body: ${response.body.trim()}',
    );
    final parts = response.body.trim().split(RegExp(r'\s+'));
    if (parts.length < 2 || !RegExp(r'^[0-9a-f]{64}$').hasMatch(parts.first)) {
      throw FlutterArchiveException(
        '${artifact.checksum} is not in the expected `<hex> *<filename>` '
        'form, so fvm cannot verify the download.',
      );
    }
    final named = parts[1].replaceFirst(RegExp(r'^\*'), '');
    if (named != artifact.fileName) {
      throw FlutterArchiveException(
        '${artifact.checksum} is a checksum for "$named", not for '
        '"${artifact.fileName}".',
      );
    }
    return parts.first;
  }

  /// Writes [url] into [destination], returning the hex sha256 of what arrived.
  Future<String> _streamToFile(Uri url, File destination) async {
    _verbose.log(VerboseArea.net, () => 'GET $url');
    final http.StreamedResponse response;
    try {
      response = await _http.send(http.Request('GET', url));
    } on http.ClientException catch (error) {
      throw FlutterArchiveException(
        'Could not download $url: ${error.message}',
      );
    }
    _verbose.log(
      VerboseArea.net,
      () => '  HTTP ${response.statusCode}, '
          'content-length ${response.contentLength ?? '(unknown)'}, '
          'to ${destination.path}',
    );
    if (response.statusCode != 200) {
      throw FlutterArchiveException(
        'The Flutter archive returned HTTP ${response.statusCode} for $url.',
      );
    }

    final total = response.contentLength;
    final bar = ProgressBar(
      sink: _progress,
      styles: _styles,
      label: destination.basename,
      total: total,
      isTerminal: _progressIsTerminal,
    );

    Digest? digest;
    final hasher = sha256.startChunkedConversion(
      ChunkedConversionSink<Digest>.withCallback(
        (digests) => digest = digests.single,
      ),
    );

    final sink = destination.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        hasher.add(chunk);
        sink.add(chunk);
        received += chunk.length;
        bar.update(received);
      }
    } finally {
      await sink.close();
      hasher.close();
      bar.finish(received);
    }

    // startChunkedConversion's callback fires on close, which the finally
    // block above always reaches.
    return digest!.toString();
  }
}
