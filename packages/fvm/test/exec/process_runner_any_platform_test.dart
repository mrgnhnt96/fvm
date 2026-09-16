import 'dart:io';

import 'package:fvm/fvm.dart';
import 'package:fvm/src/core/runner.dart';
import 'package:file/local.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// What [OsProcessRunner] promises, asked on WHATEVER platform is running.
///
/// `process_runner_test.dart` covers the same ground more thoroughly but is
/// `@TestOn('!windows')`: it spawns `/bin/sh` scripts and sends real POSIX
/// signals, neither of which Windows has. That left the promise every command
/// in fvm depends on — the child's exit code becomes fvm's — completely
/// untested on the one platform where it was broken.
///
/// It was broken. On Windows `OsProcessRunner` asked to watch SIGTERM, which
/// that platform refuses; the failure arrived as an unhandled asynchronous
/// error, and `fvm flutter --version` printed the SDK's answer and then exited
/// 255. Every one of the exit codes below came back as 255 before the fix.
void main() {
  late Directory temp;

  /// The child program, found relative to the package root `dart test` runs in.
  final probe = p.join(
    Directory.current.path,
    'test',
    'exec',
    'probe_child.dart',
  );

  setUp(() {
    // Resolved because macOS hands out /var/folders/… which is a symlink to
    // /private/var, and the child reports the resolved spelling back.
    temp = Directory(
      Directory.systemTemp
          .createTempSync('fvm_runner_')
          .resolveSymbolicLinksSync(),
    );
    expect(
      File(probe).existsSync(),
      isTrue,
      reason: 'the child program is missing: $probe',
    );
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Future<int> runProbe(
    List<String> arguments, {
    Map<String, String>? environment,
  }) =>
      const OsProcessRunner().run(
        Platform.resolvedExecutable,
        <String>[probe, ...arguments],
        environment: environment,
      );

  test("the child's exit code becomes fvm's", () async {
    // The one that breaks CI silently if it is wrong: a `dart test` that failed
    // has to still look like a failure from outside fvm, with the SAME number.
    for (final code in [0, 1, 3, 42, 127]) {
      expect(
        await runProbe(['-', '$code']),
        code,
        reason: 'exit $code did not survive the round trip',
      );
    }
  });

  test('running a child leaves no signal handler behind', () async {
    // Two in a row. Installing a handler and failing to take it off again is
    // invisible in a single run and turns the second one into a hang or a
    // crash — which is how the Windows failure would have looked if the first
    // call had happened to succeed.
    expect(await runProbe(['-', '4']), 4);
    expect(await runProbe(['-', '5']), 5);
  });

  test('arguments reach the child exactly as written', () async {
    final record = p.join(temp.path, 'argv');
    const arguments = [
      'a b',
      "it's",
      'say "hi"',
      '--define=x=a b',
      r'$HOME',
      '%PATH%',
      '*',
    ];

    expect(await runProbe([record, '0', ...arguments]), 0);

    // No shell sits between fvm and the child, so `$HOME`, `%PATH%` and `*`
    // arrive as the characters the user typed rather than expanded.
    final lines = File(record).readAsLinesSync();
    expect(lines.take(arguments.length), arguments);
  });

  test('the child sees the SDK first on PATH and knows its version', () async {
    final sdkDir = Directory(p.join(temp.path, 'versions', '3.9.0'));
    const fileSystem = LocalFileSystem();
    final flutter = fileSystem.file(
      p.join(
          sdkDir.path, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter'),
    )..createSync(recursive: true);

    final invocation = SdkInvocation(
      fileSystem: fileSystem,
      sdk: ResolvedSdk(
        rule: ResolutionRule.fvmrc,
        sdkDir: fileSystem.directory(sdkDir.path),
        executable: flutter,
        version: '3.9.0',
      ),
      environment: Platform.environment,
    );

    final record = p.join(temp.path, 'env');
    expect(
      await runProbe([record, '0'], environment: invocation.environment),
      0,
    );

    final lines = File(record).readAsLinesSync();
    final separator = lines.indexOf('--');
    expect(separator, isNonNegative, reason: 'the child wrote no separator');
    expect(lines[separator + 1], '3.9.0');
    expect(
      lines[separator + 2].split(Platform.isWindows ? ';' : ':').first,
      p.join(sdkDir.path, 'bin'),
    );
  });
}
