import 'package:fvm/fvm.dart';
// The entrypoint is `run`, and so is this harness's method for calling it.
import 'package:fvm/fvm.dart' as fvm;
import 'package:file/file.dart';
import 'package:file/memory.dart';

/// Drives the real `fvm` entrypoint against a memory filesystem.
///
/// `FVM_HOME` is set, so nothing here can reach the real `~/.fvm` even if a
/// command asks for the home directory by hand. The environment is mutable
/// because two of the five resolution rules are environment facts.
class CommandHarness {
  /// [opHandle] is `MemoryFileSystem`'s seam for making one filesystem call
  /// fail. A memory filesystem otherwise never refuses anything, so it is the
  /// only way to drive the branches that exist because a real one does.
  CommandHarness({
    void Function(String path, FileSystemOp operation)? opHandle,
  }) {
    fileSystem = MemoryFileSystem.test(
      opHandle: opHandle ?? (_, __) {},
    );
    fileSystem.directory(projectPath).createSync(recursive: true);
    fileSystem.currentDirectory = projectPath;
    paths = FvmPaths(fileSystem: fileSystem, environment: environment);
    config = ConfigStore(fileSystem: fileSystem, paths: paths);
    installer = FakeInstaller(fileSystem: fileSystem, paths: paths);
  }

  static const String projectPath = '/project';
  static const String fvmHome = '/fvm';

  late final MemoryFileSystem fileSystem;
  late final FvmPaths paths;
  late final ConfigStore config;
  late final FakeInstaller installer;

  final Map<String, String> environment = {
    'FVM_HOME': fvmHome,
    'HOME': '/home/dev',
    // Empty rather than absent: rule 4 must not find whatever `flutter` happens
    // to be on the machine running the tests.
    'PATH': '',
  };

  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();

  String get output => out.toString();
  String get errors => err.toString();

  String? executablePath;

  Future<int> run(List<String> args) => fvm.run(
        args,
        executablePath: executablePath,
        fileSystem: fileSystem,
        environment: environment,
        platformVersion: '3.13.2 (stable) on "macos_arm64"',
        out: out,
        err: err,
        installer: installer,
      );

  /// Puts a usable SDK in the cache, the way a real install leaves it.
  Directory installVersion(String version) {
    final directory = paths.versionDir(version);
    paths.flutterExecutable(directory)
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\n');
    return directory;
  }

  /// A directory under `versions/` with no `bin/flutter` in it — what an
  /// interrupted removal or a hand-edited cache leaves behind.
  Directory breakVersion(String version) =>
      paths.versionDir(version)..createSync(recursive: true);

  /// A real, non-shim `flutter` on PATH, for rule 4.
  File putFlutterOnPath({String directory = '/usr/bin'}) {
    final executable = fileSystem.file('$directory/flutter')
      ..createSync(recursive: true)
      ..writeAsStringSync('not a shim, just bytes');
    environment['PATH'] = directory;
    return executable;
  }

  void writeConfig(FvmConfig value) => config.write(value);

  FvmConfig readConfig() => config.read();

  String readFvmrc([String path = '$projectPath/.fvmrc']) =>
      fileSystem.file(path).readAsStringSync();

  void clearOutput() {
    out.clear();
    err.clear();
  }
}

/// An [Installer] that records what it was asked for and creates the same
/// files a real install would.
///
/// The point of the recording is that `use` promising to auto-install is only
/// worth anything if it actually asks; the point of creating `bin/flutter` is
/// that `isInstalled` here means the same thing it means in production.
class FakeInstaller implements Installer {
  FakeInstaller({required this.fileSystem, required this.paths});

  final FileSystem fileSystem;
  final FvmPaths paths;

  /// One entry per [install] call, in order.
  final List<InstallRequest> requests = [];

  /// When set, [install] throws this instead of installing.
  Object? failure;

  /// When true, [install] returns without leaving an SDK behind — the "the
  /// installer said yes and produced nothing" case.
  bool produceNothing = false;

  @override
  bool isInstalled(String version) =>
      paths.flutterExecutable(paths.versionDir(version)).existsSync();

  @override
  Future<Directory> install(
    String version, {
    Channel? channel,
    bool force = false,
  }) async {
    requests.add(
      InstallRequest(version: version, channel: channel, force: force),
    );
    final error = failure;
    if (error != null) throw error;

    final directory = paths.versionDir(version);
    if (!produceNothing) {
      paths.flutterExecutable(directory)
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\n');
    }
    return directory;
  }
}

/// One call to [FakeInstaller.install].
class InstallRequest {
  const InstallRequest({
    required this.version,
    required this.channel,
    required this.force,
  });

  final String version;
  final Channel? channel;
  final bool force;
}
