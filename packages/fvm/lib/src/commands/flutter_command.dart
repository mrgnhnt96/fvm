import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import '../core/context.dart';
import '../core/resolver.dart';
import '../core/runner.dart';
import '../core/verbose.dart';

/// `fvm flutter` — Run flutter from the resolved SDK.
class FlutterCommand extends Command<int> {
  FlutterCommand({required this.context});

  final FvmContext context;

  @override
  String get name => 'flutter';

  @override
  String get description => 'Run flutter from the resolved SDK.';

  @override
  String get invocation => 'fvm flutter <args...>';

  // Everything after the command name belongs to the child process,
  // including flags that would otherwise look like fvm's own.
  @override
  final ArgParser argParser = ArgParser.allowAnything();

  @override
  Future<int> run() async {
    final sdk = context.resolver.resolve(from: context.workingDirectory);
    final invocation = SdkInvocation(
      fileSystem: context.fileSystem,
      sdk: sdk,
      environment: context.environment,
      verbose: context.verbose,
    );
    describeSdkChoice(context, sdk);

    return context.processes.run(
      sdk.executable.path,
      childArguments(argResults?.rest ?? const []),
      environment: invocation.environment,
      workingDirectory: context.workingDirectory.path,
    );
  }
}

/// Says on the verbose channel which SDK is about to run, and what chose it.
///
/// Shared by `fvm flutter` and `fvm exec` because they are the two ways into an
/// SDK and a log that only covered one of them would be worse than none: the
/// shim goes through `exec`, so that is the path a CI log sees, and the two
/// must not be able to disagree about how they report themselves.
void describeSdkChoice(FvmContext context, ResolvedSdk sdk) {
  context.verbose.log(
    VerboseArea.exec,
    () => 'running ${sdk.executable.path}',
  );
  context.verbose.log(
    VerboseArea.exec,
    () => '  chosen by ${sdk.rule.label}'
        '${sdk.source == null ? '' : ' (${sdk.source})'}'
        '${sdk.version == null ? '' : ', Flutter ${sdk.version}'}',
  );
}

/// What actually reaches the child, given everything after the fvm command.
///
/// `ArgParser.allowAnything()` hands over the arguments verbatim, which is what
/// makes `fvm flutter --version` report the SDK's version instead of fvm's. That
/// leaves one thing to do here: drop a leading `--`. A user writing
/// `fvm flutter -- --version` is using the terminator to say "stop reading these",
/// and passing the terminator itself through would make flutter parse an argument
/// the user meant for fvm.
List<String> childArguments(List<String> rest) =>
    rest.isNotEmpty && rest.first == '--' ? rest.sublist(1) : rest;
