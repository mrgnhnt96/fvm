import 'package:test/test.dart';

import '../commands/harness.dart';
import 'support.dart';

/// `fvm flutter` is the command the PATH shim ultimately runs, so every assertion
/// here is about a thing that would otherwise be wrong on every single `flutter`
/// invocation on the machine.
void main() {
  late CommandHarness harness;
  late FakeProcessRunner processes;

  setUp(() {
    harness = CommandHarness();
    processes = FakeProcessRunner();
    harness.installVersion('3.9.0');
    harness.fileSystem.file('/project/.fvmrc').writeAsStringSync('3.9.0');
  });

  test("runs the resolved SDK's flutter", () async {
    expect(await runWith(harness, ['flutter'], processes: processes), 0);

    expect(processes.only.executable, '/fvm/versions/3.9.0/bin/flutter');
    expect(processes.only.arguments, isEmpty);
    expect(processes.only.workingDirectory, '/project');
  });

  test('passes arguments through untouched', () async {
    await runWith(
      harness,
      ['flutter', 'run', 'bin/tool.dart', '--name=a b', "it's", '--', '-x'],
      processes: processes,
    );

    expect(processes.only.arguments, [
      'run',
      'bin/tool.dart',
      '--name=a b',
      "it's",
      '--',
      '-x',
    ]);
  });

  test('--version reports the SDK, not fvm', () async {
    expect(
        await runWith(harness, ['flutter', '--version'], processes: processes),
        0);

    // The child was asked the question...
    expect(processes.only.arguments, ['--version']);
    // ...and fvm did not answer it itself on the way past.
    expect(harness.output, isEmpty);
    expect(harness.errors, isEmpty);
  });

  test('a leading -- is the terminator, not an argument for flutter', () async {
    await runWith(harness, ['flutter', '--', '--version'],
        processes: processes);

    expect(processes.only.arguments, ['--version']);
  });

  test('the child exit code becomes fvm\'s', () async {
    // The one that matters: a version manager that turns a failing
    // `dart test` into a success breaks CI for everyone downstream.
    processes.result = 3;
    expect(
        await runWith(harness, ['flutter', 'test'], processes: processes), 3);

    processes.result = 0;
    expect(
        await runWith(harness, ['flutter', 'test'], processes: processes), 0);
  });

  test('the child is told which SDK it is running under', () async {
    harness.environment['PATH'] = '/usr/bin:/bin';

    await runWith(harness, ['flutter'], processes: processes);

    expect(processes.only.environment, {
      'PATH': '/fvm/versions/3.9.0/bin:/usr/bin:/bin',
      'FVM_FLUTTER_VERSION': '3.9.0',
    });
  });

  test('an unresolvable pin fails instead of running something else', () async {
    harness.fileSystem.file('/project/.fvmrc').writeAsStringSync('4.0.0');

    expect(await runWith(harness, ['flutter'], processes: processes), 1);
    expect(harness.errors, contains('not installed'));
    expect(processes.calls, isEmpty);
  });
}
