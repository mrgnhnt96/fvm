import 'package:fvm/fvm.dart';
import 'package:fvm/src/archive/sdk_extractor.dart';
import 'package:fvm/src/core/shims.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

void main() {
  late MemoryFileSystem fileSystem;
  late FvmPaths paths;
  late RecordingModeApplier modes;
  late ShimWriter writer;

  ShimWriter build(MemoryFileSystem fs, String home) {
    paths = FvmPaths(fileSystem: fs, environment: {'FVM_HOME': home});
    modes = RecordingModeApplier();
    return ShimWriter(fileSystem: fs, paths: paths, modes: modes);
  }

  setUp(() {
    fileSystem = MemoryFileSystem.test();
    writer = build(fileSystem, '/fvm');
  });

  test('writes a two-line POSIX shim that execs the given fvm binary',
      () async {
    final shim = await writer.write('/usr/local/bin/fvm');

    expect(shim.path, '/fvm/shims/flutter');
    expect(
      shim.readAsStringSync(),
      '#!/bin/sh\nexec "/usr/local/bin/fvm" exec flutter "\$@"\n',
    );
  });

  test('asks for mode 0755 on the shim it wrote', () async {
    final shim = await writer.write('/usr/local/bin/fvm');

    expect(modes.applied, [
      {shim.path: 0x1ED},
    ]);
    expect(ShimWriter.shimMode.toRadixString(8), '755');
  });

  test('creates the shims directory when it is not there yet', () async {
    expect(fileSystem.directory('/fvm/shims').existsSync(), isFalse);

    await writer.write('/usr/local/bin/fvm');

    expect(fileSystem.directory('/fvm/shims').existsSync(), isTrue);
  });

  test('the shim it writes is what the resolver recognises as a shim', () {
    // The resolver skips fvm's own shims when it scans PATH, by content as
    // well as by location. A shim this writer produced that the resolver did
    // not recognise would make `flutter` fork until the machine gave up.
    final body = writer.body('/usr/local/bin/fvm');
    expect(body.length, lessThan(512), reason: 'the resolver only reads 512B');

    final onPath = fileSystem.file('/usr/bin/flutter')
      ..createSync(recursive: true)
      ..writeAsStringSync(body);
    final resolver = VersionResolver(
      fileSystem: fileSystem,
      paths: paths,
      config: ConfigStore(fileSystem: fileSystem, paths: paths),
      fvmrc: FvmrcStore(fileSystem: fileSystem),
      environment: const {'PATH': '/usr/bin'},
    );

    expect(onPath.existsSync(), isTrue);
    expect(
      resolver.findFlutterOnPath(),
      isNull,
      reason: 'a copy of the shim on PATH must not be taken for a real flutter',
    );
  });

  test('reads back the binary a shim runs', () async {
    final shim = await writer.write('/opt/fvm/bin/fvm');

    expect(writer.targetOf(shim), '/opt/fvm/bin/fvm');
  });

  test('reads back nothing from a file that is not one of its shims', () {
    final other = fileSystem.file('/usr/local/bin/flutter')
      ..createSync(recursive: true)
      ..writeAsStringSync(
          '#!/bin/sh\nexec /usr/lib/flutter/bin/flutter "\$@"\n');

    expect(writer.targetOf(other), isNull);
  });

  test('refuses a relative fvm path', () async {
    await expectLater(
      writer.write('bin/fvm'),
      throwsA(
        isA<ConfigException>().having(
          (error) => error.message,
          'message',
          contains('must be absolute'),
        ),
      ),
    );
  });

  test('refuses a fvm path that would break out of the quoting', () async {
    await expectLater(
      writer.write('/opt/"; rm -rf /; "/fvm'),
      throwsA(isA<ConfigException>()),
    );
    expect(paths.flutterShim.existsSync(), isFalse);
  });

  test('writes a .bat that forwards its arguments on Windows', () async {
    final windows = MemoryFileSystem.test(style: FileSystemStyle.windows);
    final windowsWriter = build(windows, r'C:\fvm');

    final shim = await windowsWriter.write(r'C:\Users\dev\.fvm\bin\fvm.exe');

    expect(shim.path, r'C:\fvm\shims\flutter.bat');
    expect(
      shim.readAsStringSync(),
      '@echo off\r\n"C:\\Users\\dev\\.fvm\\bin\\fvm.exe" exec flutter %*\r\n',
    );
    expect(
      modes.applied,
      isEmpty,
      reason: 'Windows has no mode bits and no chmod',
    );
  });
}

/// A [ModeApplier] that records what it was asked to apply.
///
/// The real one shells out to `chmod`, which acts on the machine's filesystem
/// and not on the [MemoryFileSystem] these tests write to.
class RecordingModeApplier implements ModeApplier {
  final List<Map<String, int>> applied = [];

  @override
  Future<void> apply(Map<String, int> modeByPath) async {
    applied.add(modeByPath);
  }
}
