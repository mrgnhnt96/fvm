import 'package:fvm/fvm.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';

/// The `fvm doctor`, `fvm setup` and `fvm install` runs that the colour work
/// touches, driven end to end against a `MemoryFileSystem` with injected sinks.
///
/// Shared by `color_test.dart` and `tool/generate_golden.dart` so the golden
/// and the test that checks it cannot describe two different runs. The golden
/// in `color_off_golden.txt` was produced by running this same set against the
/// commit BEFORE any styling existed, which is what makes it a real
/// before/after comparison rather than a restatement of the current code.
const List<ColorScenario> colorScenarios = [
  ColorScenario(
    'fvm doctor (a machine with three problems)',
    ['doctor'],
    setUp: brokenMachine,
  ),
  ColorScenario('fvm doctor (a healthy machine)', ['doctor'],
      setUp: healthyMachine),
  ColorScenario(
    'fvm setup (prints the PATH line, with a legacy install in the way)',
    ['setup', '--fvm-path', '/fvm/bin/fvm'],
    setUp: brokenMachine,
  ),
  ColorScenario(
    'fvm setup (nothing to add)',
    ['setup', '--fvm-path', '/fvm/bin/fvm'],
    setUp: healthyMachine,
  ),
  ColorScenario('fvm install 3.13.2 (a fresh install)', ['install', '3.13.2']),
  ColorScenario(
    'fvm install 3.9.0 (already installed)',
    ['install', '3.9.0'],
    setUp: healthyMachine,
  ),
];

/// One command run against one machine.
class ColorScenario {
  const ColorScenario(this.title, this.args, {this.setUp});

  final String title;
  final List<String> args;
  final void Function(FileSystem fileSystem, Map<String, String> environment)?
      setUp;
}

/// Runs every scenario and dumps stdout and stderr into one comparable blob.
///
/// [extraArgs] go in front of the command, which is where a top-level flag
/// like `--color=always` belongs. [environment] is merged over the base one,
/// so a test can add `NO_COLOR` or `TERM` without restating the rest.
Future<String> renderColorScenarios({
  List<String> extraArgs = const [],
  Map<String, String> environment = const {},
  bool outIsTerminal = false,
}) async {
  final buffer = StringBuffer();
  for (final scenario in colorScenarios) {
    final fileSystem = MemoryFileSystem.test();
    fileSystem.directory('/project').createSync(recursive: true);
    fileSystem.currentDirectory = '/project';
    final env = <String, String>{
      'FVM_HOME': '/fvm',
      'HOME': '/home/dev',
      'PATH': '/usr/bin',
      'SHELL': '/bin/zsh',
    };
    scenario.setUp?.call(fileSystem, env);
    env.addAll(environment);

    final out = StringBuffer();
    final err = StringBuffer();
    final code = await run(
      [...extraArgs, ...scenario.args],
      fileSystem: fileSystem,
      environment: env,
      platformVersion: '3.13.2 (stable) on "macos_arm64"',
      out: out,
      err: err,
      outIsTerminal: outIsTerminal,
      installer: ScenarioInstaller(fileSystem),
    );

    buffer
      ..writeln('=== ${scenario.title} -> exit $code')
      ..writeln('--- stdout')
      ..write(out)
      ..writeln('--- stderr')
      ..write(err)
      ..writeln();
  }
  return buffer.toString();
}

/// A machine with a real `flutter` ahead of the shims, no shim at all, and the
/// older cbracken/fvm still in `~/.fvm` — findings at all three severities.
void brokenMachine(FileSystem fileSystem, Map<String, String> environment) {
  fileSystem.file('/usr/bin/flutter')
    ..createSync(recursive: true)
    ..writeAsStringSync('a real flutter, not a shim');
  fileSystem.directory('/fvm/flutters/2.19.0').createSync(recursive: true);
  fileSystem.file('/fvm/bin/fvm')
    ..createSync(recursive: true)
    ..writeAsStringSync('the fvm binary');
  fileSystem.file('/home/dev/.zshrc')
    ..createSync(recursive: true)
    ..writeAsStringSync('fvm() { echo the old one; }\n');
  environment['PATH'] = '/usr/bin:/fvm/shims';
}

/// Shims installed, on PATH, ahead of everything, with a pinned SDK present.
void healthyMachine(FileSystem fileSystem, Map<String, String> environment) {
  fileSystem.file('/fvm/bin/fvm')
    ..createSync(recursive: true)
    ..writeAsStringSync('the fvm binary');
  fileSystem.file('/fvm/shims/flutter')
    ..createSync(recursive: true)
    ..writeAsStringSync('#!/bin/sh\nexec /fvm/bin/fvm exec flutter "\$@"\n');
  fileSystem.file('/fvm/versions/3.9.0/bin/flutter')
    ..createSync(recursive: true)
    ..writeAsStringSync('#!/bin/sh\n');
  fileSystem.file('/project/.fvmrc')
    ..createSync(recursive: true)
    ..writeAsStringSync('{ "flutter": "3.9.0" }\n');
  environment['PATH'] = '/fvm/shims:/fvm/bin';
}

/// Leaves behind what a real install leaves behind, without a network.
class ScenarioInstaller implements Installer {
  ScenarioInstaller(this.fileSystem);

  final FileSystem fileSystem;

  @override
  bool isInstalled(String version) =>
      fileSystem.file('/fvm/versions/$version/bin/flutter').existsSync();

  @override
  Future<Directory> install(
    String version, {
    Channel? channel,
    bool force = false,
  }) async {
    fileSystem.file('/fvm/versions/$version/bin/flutter')
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\n');
    return fileSystem.directory('/fvm/versions/$version');
  }
}
