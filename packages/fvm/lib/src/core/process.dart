import 'runner.dart';
import 'verbose.dart';

/// Runs the resolved SDK's binaries.
///
/// A seam rather than a direct `Process.start` so that commands stay testable.
/// Implementations must start the child with `ProcessStartMode.inheritStdio`,
/// forward its exit code, and forward SIGINT/SIGTERM to it — Flutter has no
/// `exec()`, and getting this wrong is what makes `fvm flutter run` feel broken.
abstract class ProcessRunner {
  /// Runs [executable] with [arguments] and completes with its exit code.
  Future<int> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? workingDirectory,
  });
}

/// The seam `lib/fvm.dart` calls to get a [ProcessRunner].
ProcessRunner createProcessRunner({VerboseLog? verbose}) =>
    OsProcessRunner(verbose: verbose);
