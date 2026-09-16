import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fvm/fvm.dart';
import 'package:fvm/src/archive/sdk_downloader.dart';
import 'package:file/memory.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// What `fvm install` renders while an SDK streams in.
///
/// The two shapes are not cosmetic variants of each other. A carriage return is
/// a repaint only on a terminal; sent to a file or a CI log it appends, so the
/// single line a human sees becomes one ~20KB line holding all 101 states. And
/// installing an SDK in CI is a primary use of a version manager, so the
/// non-terminal shape is the one more machines read.
///
/// Both branches are driven through the injected sink, never the process's
/// stdout, so this says nothing about the terminal the suite happens to run in.
void main() {
  late MemoryFileSystem fs;
  late StringBuffer progress;

  const platform = HostPlatform(os: 'macos', arch: 'arm64');

  /// A thousand chunks, so how much is printed is decided by the throttling
  /// rather than by how a socket happened to split the body. A real 205MB
  /// download is tens of thousands.
  const chunkCount = 1000;
  const chunkSize = 1024;

  final artifact = ReleaseArtifact(
      version: '3.13.2',
      fileName: 'flutter_${platform.os}_${platform.arch}_test.zip',
      archive: Uri.parse('https://example.test/sdk.zip'),
      checksum: Uri.parse('https://example.test/sdk.zip.sha256sum'));

  setUp(() {
    fs = MemoryFileSystem.test();
    progress = StringBuffer();
  });

  /// Serves [artifact] as [chunkCount] equal chunks, with the checksum the
  /// downloader verifies them against.
  http.Client chunkedClient({int? contentLength = chunkCount * chunkSize}) {
    final body = Uint8List(chunkCount * chunkSize);
    final digest = sha256.convert(body).toString();

    return MockClient.streaming((request, _) async {
      if (request.url.path.endsWith('.sha256sum')) {
        final line = utf8.encode('$digest *${artifact.fileName}\n');
        return http.StreamedResponse(
          Stream.value(line),
          200,
          contentLength: line.length,
        );
      }
      return http.StreamedResponse(
        Stream.fromIterable([
          for (var i = 0; i < chunkCount; i++)
            body.sublist(i * chunkSize, (i + 1) * chunkSize),
        ]),
        200,
        contentLength: contentLength,
      );
    });
  }

  Future<String> downloadWith({
    required bool progressIsTerminal,
    int? contentLength = chunkCount * chunkSize,
  }) async {
    await SdkDownloader(
      fileSystem: fs,
      progress: progress,
      progressIsTerminal: progressIsTerminal,
      httpClient: chunkedClient(contentLength: contentLength),
    ).download(artifact, fs.file('/cache/${artifact.fileName}'));
    return progress.toString();
  }

  group('progress written to something that is not a terminal', () {
    test('is discrete lines, and never a carriage return', () async {
      final output = await downloadWith(progressIsTerminal: false);

      expect(output, isNot(contains('\r')));
      expect(output, endsWith('\n'));

      final lines = output.split('\n')..removeLast();
      expect(lines.length, greaterThan(2));
      for (final line in lines) {
        expect(
          line,
          matches(RegExp(r'^  \S+  \d{1,3}%  \(\d+\.\d / \d+\.\d MB\)$')),
          reason: 'every line has to stand on its own: "$line"',
        );
      }
      expect(lines.first, contains('  0%  '));
      expect(lines.last, contains('  100%  '));
    });

    test('is throttled to one line per 10%, not one per chunk', () async {
      final output = await downloadWith(progressIsTerminal: false);
      final lines = output.split('\n')..removeLast();

      // 0, 10, … 100 is eleven lines for a thousand chunks.
      expect(lines.length, 11);
      expect(
        [
          for (final line in lines) RegExp(r'(\d+)%').firstMatch(line)!.group(1)
        ],
        ['0', '10', '20', '30', '40', '50', '60', '70', '80', '90', '100'],
      );
    });
  });

  group('progress written to a terminal', () {
    test('still overwrites a single line', () async {
      final output = await downloadWith(progressIsTerminal: true);

      expect(output, contains('\r'));
      expect(output, contains('100%'));
      // One line: the repaints share it, and only the finishing newline ends
      // it.
      expect(output.split('\n').length, 2);
      expect(output, endsWith('\n'));
      expect(
        '\r'.allMatches(output).length,
        101,
        reason: 'a terminal is repainted for every percentage, 0 through 100',
      );
    });
  });

  test('a download of unknown length finishes on its own line either way',
      () async {
    for (final isTerminal in [true, false]) {
      progress = StringBuffer();
      final output = await downloadWith(
        progressIsTerminal: isTerminal,
        contentLength: null,
      );
      expect(output, isNot(contains('\r')));
      expect(output, endsWith('\n'));
      expect(output.split('\n')..removeLast(), hasLength(1));
    }
  });
}
