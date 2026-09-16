import 'package:test/test.dart';

import '../commands/harness.dart';
import 'support.dart';

/// `fvm exec` runs anything at all with the pinned SDK in front of it, which is
/// what makes `fvm exec melos bootstrap` build against the version the project
/// pinned rather than whatever is first on the developer's PATH.
void main() {
  late CommandHarness harness;
  late FakeProcessRunner processes;

  setUp(() {
    harness = CommandHarness();
    processes = FakeProcessRunner();
    harness.installVersion('3.9.0');
    harness.fileSystem.file('/project/.fvmrc').writeAsStringSync('3.9.0');
  });

  /// A command on the parent's PATH but not in the SDK — what `melos` is.
  void putOnPath(String path) {
    harness.fileSystem.file(path)
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\n');
    harness.environment['PATH'] = harness.fileSystem.path.dirname(path);
  }

  test('runs a command found on the child PATH', () async {
    putOnPath('/opt/pub/melos');

    expect(
      await runWith(harness, ['exec', 'melos', 'bootstrap'],
          processes: processes),
      0,
    );

    expect(processes.only.executable, '/opt/pub/melos');
    expect(processes.only.arguments, ['bootstrap']);
    expect(processes.only.environment, {
      'PATH': '/fvm/versions/3.9.0/bin:/opt/pub',
      'FVM_FLUTTER_VERSION': '3.9.0',
    });
  });

  test('`exec flutter` reaches the pinned SDK, not the one on PATH', () async {
    // This is the shim's own code path: `~/.fvm/shims/flutter` is
    // `exec fvm exec flutter "$@"`, so picking the PATH copy here would either run
    // the wrong SDK or re-enter the shim and fork until the machine gives up.
    putOnPath('/usr/bin/flutter');

    await runWith(harness, ['exec', 'flutter', '--version'],
        processes: processes);

    expect(processes.only.executable, '/fvm/versions/3.9.0/bin/flutter');
    expect(processes.only.arguments, ['--version']);
  });

  test('arguments reach the child untouched', () async {
    putOnPath('/opt/pub/melos');

    await runWith(
      harness,
      ['exec', 'melos', 'exec', '--', 'echo a b', "it's"],
      processes: processes,
    );

    expect(processes.only.arguments, ['exec', '--', 'echo a b', "it's"]);
  });

  test('a leading -- introduces the command rather than being one', () async {
    putOnPath('/opt/pub/melos');

    await runWith(harness, ['exec', '--', 'melos'], processes: processes);

    expect(processes.only.executable, '/opt/pub/melos');
  });

  test('the child exit code becomes fvm\'s', () async {
    putOnPath('/opt/pub/melos');
    processes.result = 42;

    expect(await runWith(harness, ['exec', 'melos'], processes: processes), 42);
  });

  test('a command that is not there exits 127, the way a shell does', () async {
    expect(await runWith(harness, ['exec', 'nope'], processes: processes), 127);
    expect(harness.errors, contains('command not found: nope'));
    expect(processes.calls, isEmpty);
  });

  test('naming no command at all is a usage error', () async {
    expect(await runWith(harness, ['exec'], processes: processes), 64);
    expect(harness.errors, contains('exec needs a command to run'));
    expect(processes.calls, isEmpty);
  });
}
