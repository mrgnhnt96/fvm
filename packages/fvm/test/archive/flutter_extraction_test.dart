import 'dart:io' as io;

import 'package:file/local.dart';
import 'package:file/memory.dart';
import 'package:fvm/src/archive/sdk_extractor.dart';
import 'package:fvm/src/archive/flutter_archive_exception.dart';
import 'package:test/test.dart';

void main() {
  for (final local in [false, true]) {
    test(
        'extracts tar.xz with Flutter launcher and bundled Dart (local=$local)',
        () async {
      final fs = local ? const LocalFileSystem() : MemoryFileSystem.test();
      final tmp = local
          ? fs.systemTempDirectory.createTempSync('fvm-extract-')
          : fs.directory('/tmp')
        ..createSync(recursive: true);
      addTearDown(() => tmp.deleteSync(recursive: true));
      final archive = fs.file(fs.path.join(tmp.path, 'sdk.tar.xz'));
      archive.writeAsBytesSync(
          io.File('test/archive/fixtures/flutter.tar.xz').readAsBytesSync());
      final destination = fs.directory(fs.path.join(tmp.path, 'out'));
      final modes = await const ArchiveSdkExtractor()
          .extract(archive: archive, destination: destination);
      final sdk = sdkRootWithin(destination, 'flutter');
      expect(
          fs.file(fs.path.join(sdk.path, 'bin', 'dart')).existsSync(), isTrue);
      expect(modes[fs.path.join(sdk.path, 'bin', 'flutter')]! & 0x1ff, 0x1ed);
      expect(fs.file('${archive.path}.tar').existsSync(), isFalse);
    });
  }
  test('preserves internal zip symlinks and rejects escaping links', () async {
    if (io.Platform.isWindows) return;
    final fs = MemoryFileSystem.test();
    final zip = fs.file('/sdk.zip');
    zip.writeAsBytesSync(
        io.File('test/archive/fixtures/symlink.zip').readAsBytesSync());
    await const ArchiveSdkExtractor()
        .extract(archive: zip, destination: fs.directory('/out'));
    expect(fs.link('/out/flutter/bin/tool').targetSync(), 'flutter');
    zip.writeAsBytesSync(
        io.File('test/archive/fixtures/unsafe.zip').readAsBytesSync());
    expect(
        () => const ArchiveSdkExtractor()
            .extract(archive: zip, destination: fs.directory('/unsafe')),
        throwsA(isA<FlutterArchiveException>()));
  });
}
