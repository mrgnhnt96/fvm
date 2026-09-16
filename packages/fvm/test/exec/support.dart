import 'package:fvm/fvm.dart';
import 'package:fvm/fvm.dart' as fvm;

import '../commands/harness.dart';

/// A [ProcessRunner] that records what it was asked to run instead of running
/// it.
///
/// The point of these tests is what fvm hands the child — executable, argv,
/// environment — and that is exactly what a real `Process.start` swallows.
/// `process_runner_test.dart` covers the other half by spawning real children.
class FakeProcessRunner implements ProcessRunner {
  /// One entry per [run] call, in order.
  final List<ProcessInvocation> calls = [];

  /// What [run] completes with.
  int result = 0;

  /// The only invocation, failing the test if there was not exactly one.
  ProcessInvocation get only => calls.single;

  @override
  Future<int> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    calls.add(
      ProcessInvocation(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
      ),
    );
    return result;
  }
}

/// One call to [FakeProcessRunner.run].
class ProcessInvocation {
  const ProcessInvocation({
    required this.executable,
    required this.arguments,
    required this.environment,
    required this.workingDirectory,
  });

  final String executable;
  final List<String> arguments;

  /// The overrides fvm asked for, not the child's whole environment: the rest
  /// of it comes from the parent process at `Process.start` time.
  final Map<String, String>? environment;
  final String? workingDirectory;
}

/// Drives the real entrypoint against [harness] with [processes] injected.
///
/// `CommandHarness.run` does not take a process runner, and adding one there
/// would be an edit to a file every command's tests share.
Future<int> runWith(
  CommandHarness harness,
  List<String> args, {
  required FakeProcessRunner processes,
}) =>
    fvm.run(
      args,
      fileSystem: harness.fileSystem,
      environment: harness.environment,
      platformVersion: '3.13.2 (stable) on "macos_arm64"',
      out: harness.out,
      err: harness.err,
      installer: harness.installer,
      processes: processes,
    );
