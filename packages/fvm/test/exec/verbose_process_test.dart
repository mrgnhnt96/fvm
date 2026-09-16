import 'dart:io';

import 'package:fvm/fvm.dart';
import 'package:fvm/src/core/runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// What a verbose run says about a REAL child process.
///
/// `verbose_test.dart` drives the CLI against a [FakeProcessRunner], which by
/// construction cannot show that [OsProcessRunner] itself reports anything —
/// and [OsProcessRunner] is where the argv, the working directory, the
/// environment overlay and the exit code actually live. This spawns a real
/// child so the claim is about the code that ships.
void main() {
  /// The child program, found relative to the package root `dart test` runs in.
  final probe = p.join(
    Directory.current.path,
    'test',
    'exec',
    'probe_child.dart',
  );

  setUp(() {
    expect(
      File(probe).existsSync(),
      isTrue,
      reason: 'the child program is missing: $probe',
    );
  });

  test('a verbose spawn reports argv, cwd, the overlay and the exit code',
      () async {
    final sink = StringBuffer();
    final verbose = VerboseLog(sink: sink)..enable();

    final code = await OsProcessRunner(verbose: verbose).run(
      Platform.resolvedExecutable,
      <String>[probe, '-', '3', 'hello'],
      environment: const {'FVM_FLUTTER_VERSION': '3.9.0'},
      workingDirectory: Directory.current.path,
    );
    expect(code, 3);

    final said = sink.toString();
    expect(
        said,
        contains('[fvm proc] spawn ${Platform.resolvedExecutable} '
            '$probe - 3 hello'));
    expect(said, contains('[fvm proc]   cwd: ${Directory.current.path}'));
    // The OVERLAY, not the child's whole environment: this is exactly what
    // fvm changed, which is the question somebody debugging is asking.
    expect(
        said,
        contains('[fvm proc]   env override: '
            'FVM_FLUTTER_VERSION=3.9.0'));
    expect(
        said,
        contains(RegExp(r'\[fvm proc\]   pid \d+ exited 3 after '
            r'\d+ms')));
  });

  test('the same spawn with the log off says nothing at all', () async {
    final sink = StringBuffer();

    final code = await OsProcessRunner(verbose: VerboseLog(sink: sink)).run(
      Platform.resolvedExecutable,
      <String>[probe, '-', '0'],
    );

    expect(code, 0);
    expect(sink.toString(), isEmpty);
  });
}
