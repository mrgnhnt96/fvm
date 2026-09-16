import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fvm/fvm.dart';
import 'package:fvm/src/archive/flutter_archive_client.dart';
import 'package:fvm/src/archive/sdk_extractor.dart';
import 'package:fvm/src/archive/sdk_installer.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

import 'fake_archive_server.dart';

/// What `fvm install` renders while the downloaded SDK is unpacked.
///
/// The gap this closes: the download bar reached
/// `fluttersdk-macos-arm64-release.zip  100%  (215.4 / 215.4 MB)` and then the
/// process printed NOTHING until `Installed Flutter 3.13.2 to ...`. Measured on a
/// real 3.13.2 macos-arm64 install that window is ~1.4s on an M-series Mac and
/// grows with a slower disk. A bar that stops at 100% and then does nothing is
/// worse than no bar: the user has been told the work finished, and it visibly
/// has not.
///
/// The unit is UNCOMPRESSED BYTES, not entries-completed. Measured on the real
/// archive — 1044 entries, 622MB — the longest a percentage sat still was
/// 616ms counting entries against 168ms counting bytes, because a handful of
/// large snapshots take ~170ms each while thousands of tiny files flash past.
void main() {
  late MemoryFileSystem fs;

  setUp(() => fs = MemoryFileSystem.test());

  /// A zip of [count] entries whose sizes are deliberately uneven, the way a
  /// real SDK's are: one entry far larger than the rest.
  Uint8List lumpyZip({int count = 40}) {
    final archive = Archive()
      ..add(ArchiveFile.string('flutter-sdk/bin/flutter', '#!/bin/sh\nexit 0\n')
        ..mode = 0x1ED)
      ..add(
          ArchiveFile.string('flutter-sdk/version', '3.13.2\n')..mode = 0x1A4);
    for (var i = 0; i < count; i++) {
      // Entry 7 is the "snapshot": the one that would stall an entry counter.
      final body = i == 7 ? 'x' * 200000 : 'y' * 64;
      archive.add(
          ArchiveFile.string('flutter-sdk/lib/f$i.dart', body)..mode = 0x1A4);
    }
    return ZipEncoder().encodeBytes(archive);
  }

  group('the extractor itself', () {
    test('reports progress DURING the extraction, not once at the end',
        () async {
      final zip = fs.file('/sdk.zip')..writeAsBytesSync(lumpyZip());
      final destination = fs.directory('/unpacked');

      // How many files were already on disk at each callback. If progress were
      // reported only after everything was written, every observation would
      // equal the final count — which is the failure this test exists to catch
      // and is indistinguishable from "a callback exists" on its own.
      final filesOnDiskAt = <int>[];
      final reported = <int>[];
      var seenTotal = 0;

      await const ArchiveSdkExtractor().extract(
        archive: zip,
        destination: destination,
        onProgress: (completed, total) {
          seenTotal = total;
          reported.add(completed);
          filesOnDiskAt.add(destination.existsSync()
              ? destination.listSync(recursive: true).whereType<File>().length
              : 0);
        },
      );

      final finalCount =
          destination.listSync(recursive: true).whereType<File>().length;

      expect(reported.length, greaterThan(2),
          reason: 'one callback is not progress');
      expect(filesOnDiskAt.first, lessThan(finalCount),
          reason: 'the first report must arrive before the work is done');
      expect(filesOnDiskAt.any((n) => n > 0 && n < finalCount), isTrue,
          reason: 'progress must be observable partway through');

      // Monotonic and lands exactly on the total, so the bar cannot finish
      // short of 100% or jump backwards.
      expect(reported, orderedEquals(List.of(reported)..sort()));
      expect(reported.first, 0);
      expect(reported.last, seenTotal);
      expect(seenTotal, greaterThan(0));
    });

    test('the total counts only bytes that are actually written', () async {
      // An entry escaping the destination is skipped, so counting it in the
      // total would leave the bar stuck below 100% on every such archive.
      final archive = Archive()
        ..add(ArchiveFile.string('flutter-sdk/bin/flutter', '#!/bin/sh\n')
          ..mode = 0x1ED)
        ..add(
            ArchiveFile.string('../../escaped.txt', 'p' * 5000)..mode = 0x1A4);
      final zip = fs.file('/sdk.zip')
        ..writeAsBytesSync(ZipEncoder().encodeBytes(archive));

      var last = -1;
      var total = -1;
      await const ArchiveSdkExtractor().extract(
        archive: zip,
        destination: fs.directory('/unpacked'),
        onProgress: (completed, seen) {
          last = completed;
          total = seen;
        },
      );

      expect(last, total, reason: 'the bar must reach 100%');
      expect(total, lessThan(5000), reason: 'the skipped entry is not counted');
    });

    test('an extraction with no callback still extracts', () async {
      // onProgress is optional, and the seam has non-reporting callers.
      final zip = fs.file('/sdk.zip')..writeAsBytesSync(lumpyZip(count: 3));

      final modes = await const ArchiveSdkExtractor()
          .extract(archive: zip, destination: fs.directory('/unpacked'));

      expect(modes, isNotEmpty);
      expect(fs.file('/unpacked/flutter-sdk/bin/flutter').existsSync(), isTrue);
    });
  });

  group('what the install prints while unpacking', () {
    late FakeArchiveServer server;
    const platform = HostPlatform(os: 'macos', arch: 'arm64');

    setUp(() async {
      server = await FakeArchiveServer.start();
      server.publish(
        channel: 'stable',
        version: '3.13.2',
        fileName: 'flutter_${platform.os}_${platform.arch}_test.zip',
        bytes: lumpyZip(count: 60),
      );
    });

    tearDown(() => server.close());

    Future<String> install({required bool isTerminal}) async {
      final progress = StringBuffer();
      await SdkInstaller(
        fileSystem: fs,
        paths: FvmPaths(fileSystem: fs, environment: {'FVM_HOME': '/fvm'}),
        releases: FlutterArchiveClient(
          objectBase: server.objectBase,
        ),
        hostPlatform: () => platform,
        progress: progress,
        progressIsTerminal: isTerminal,
        modeApplier: const NoopModeApplier(),
      ).install('3.13.2');
      return progress.toString();
    }

    test('a terminal gets a repainted bar, in the download\'s own shape',
        () async {
      final output = await install(isTerminal: true);

      expect(output, contains('Unpacking Flutter 3.13.2'));
      expect(output, contains('flutter-sdk'));
      expect(output, contains('100%'));
      // A repaint, which is what keeps the unpack to a single line.
      expect(output, contains('\r  flutter-sdk'));
    });

    test('a non-terminal sink gets no redraw storm', () async {
      final output = await install(isTerminal: false);

      expect(output, contains('Unpacking Flutter 3.13.2'));
      expect(output, contains('100%'));
      // The whole reason the two shapes are not cosmetic variants: a carriage
      // return does not repaint a file or a CI log, it appends, so every
      // redraw would land in one unreadable line.
      expect(output, isNot(contains('\r')));

      final unpackLines = const LineSplitter()
          .convert(output)
          .where((line) => line.contains('flutter-sdk  '))
          .toList();
      // Throttled to ~10% steps, exactly as the download is. A per-entry line
      // would be 60 here and tens of thousands on a real SDK.
      expect(unpackLines.length, lessThanOrEqualTo(11),
          reason: 'a CI log must not fill with redraw lines');
      expect(unpackLines.length, greaterThan(1),
          reason: 'but it must still show movement');
    });

    test('the unpack bar is closed off before the next line prints', () async {
      final output = await install(isTerminal: true);

      // The repaints rewrite one line; without a closing newline the next
      // thing printed lands on the end of the bar.
      expect(output, contains('\n'));
      expect(output.trimRight(), isNot(endsWith('%')));
    });
  });
}
