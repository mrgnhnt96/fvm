import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import '../core/context.dart';
import '../core/exceptions.dart';
import '../core/runner.dart';
import 'flutter_command.dart';

/// Runs the Dart launcher bundled with the selected Flutter SDK.
class DartCommand extends Command<int> {
  DartCommand({required this.context});
  final FvmContext context;
  @override
  String get name => 'dart';
  @override
  String get description => 'Run Dart from the selected Flutter SDK.';
  @override
  final ArgParser argParser = ArgParser.allowAnything();
  @override
  Future<int> run() async {
    final sdk = context.resolver.resolve(from: context.workingDirectory);
    final invocation = SdkInvocation(
        fileSystem: context.fileSystem,
        sdk: sdk,
        environment: context.environment,
        verbose: context.verbose);
    final executable = context.fileSystem.file(context.fileSystem.path.join(
        sdk.sdkDir.path, 'bin', context.paths.isWindows ? 'dart.bat' : 'dart'));
    if (!executable.existsSync()) {
      throw const ResolutionException(
          'The selected Flutter SDK has no Dart launcher.');
    }
    return context.processes.run(
        executable.path, childArguments(argResults?.rest ?? const []),
        environment: invocation.environment,
        workingDirectory: context.workingDirectory.path);
  }
}
