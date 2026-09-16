/// A per-project Flutter SDK version manager.
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:file/file.dart';
import 'package:file/local.dart';

import 'src/commands/alias_command.dart';
import 'src/commands/config_command.dart';
import 'src/commands/flutter_command.dart';
import 'src/commands/dart_command.dart';
import 'src/commands/doctor_command.dart';
import 'src/commands/exec_command.dart';
import 'src/commands/global_command.dart';
import 'src/commands/install_command.dart';
import 'src/commands/list_command.dart';
import 'src/commands/list_remote_command.dart';
import 'src/commands/remove_command.dart';
import 'src/commands/setup_command.dart';
import 'src/commands/unalias_command.dart';
import 'src/commands/update_command.dart';
import 'src/commands/use_command.dart';
import 'src/commands/which_command.dart';
import 'src/core/context.dart';
import 'src/core/exceptions.dart';
import 'src/core/installer.dart';
import 'src/core/process.dart';
import 'src/core/releases.dart';
import 'src/core/style.dart';
import 'src/core/updater.dart';
import 'src/core/verbose.dart';
import 'src/gen/version.dart';

export 'src/core/channel.dart';
export 'src/core/config.dart';
export 'src/core/context.dart';
export 'src/core/exceptions.dart';
export 'src/core/installer.dart';
export 'src/core/paths.dart';
export 'src/core/platform.dart';
export 'src/core/process.dart';
export 'src/core/releases.dart';
export 'src/core/resolver.dart';
export 'src/core/style.dart';
export 'src/core/updater.dart';
export 'src/core/verbose.dart';
export 'src/gen/version.dart';

/// Bad usage — `EX_USAGE` from sysexits(3).
const int usageExitCode = 64;

/// Runs the `fvm` CLI with [args] and resolves to the process exit code.
///
/// Everything the CLI touches is a parameter with a real-world default, so a
/// test can drive the whole binary against a `MemoryFileSystem` and a fake
/// environment without going near the real `~/.fvm`.
Future<int> run(
  List<String> args, {
  FileSystem? fileSystem,
  Map<String, String>? environment,
  String? platformVersion,
  StringSink? out,
  StringSink? err,
  bool? outIsTerminal,
  ReleaseClient? releases,
  Installer? installer,
  ProcessRunner? processes,
  Updater? updater,
  String? executablePath,
}) async {
  final output = out ?? stdout;
  final errors = err ?? stderr;
  final env = environment ?? Platform.environment;
  // Asked here and nowhere else: this is the only place that knows whether
  // [output] is the process's own stdout. An injected sink belongs to the
  // caller and is never assumed to be a terminal, so the default a test sees
  // is the one CI sees.
  final terminal = outIsTerminal ?? (out == null && stdout.hasTerminal);

  // Read before anything is wired, so a run turned on by the environment is
  // verbose from its first line. The `--verbose` FLAG cannot be honoured this
  // early — the command runner owns the parser that knows about it — so it
  // switches this same object on instead, in [FvmCommandRunner.runCommand].
  final verbose = VerboseLog(
    // stderr, always: `fvm which` and everything behind the shim have their
    // stdout read by other programs.
    sink: errors,
    enabled: VerboseLog.enabledIn(env),
  );

  // Built here for the same reason: the composition root is the only place
  // that knows whether [output] is a real terminal. `--color` is a flag, so it
  // cannot be read this early — [FvmCommandRunner.runCommand] applies it to
  // this same object once the parser has run.
  final styles = Styles(environment: env, outIsTerminal: terminal);

  final context = FvmContext.wire(
    fileSystem: fileSystem ?? const LocalFileSystem(),
    environment: env,
    platformVersion: platformVersion ?? Platform.version,
    out: output,
    err: errors,
    outIsTerminal: terminal,
    // `resolvedExecutable`, not `executable`: the latter can be a bare name
    // found on PATH, and `fvm update` has to rename over a real path.
    executablePath: executablePath ?? Platform.resolvedExecutable,
    verbose: verbose,
    styles: styles,
    releases: releases,
    installer: installer,
    processes: processes,
    updater: updater,
  );

  try {
    return await FvmCommandRunner(context).run(args) ?? 0;
  } on UsageException catch (error) {
    errors
      ..writeln(error.message)
      ..writeln()
      ..writeln(error.usage);
    return usageExitCode;
  } on FvmException catch (error) {
    // The message is already written for a human; a stack trace would only
    // bury it.
    errors.writeln('fvm: ${error.message}');
    return 1;
  }
}

/// The `fvm` command surface.
///
/// Every command in ARCHITECTURE.md's table is registered here, so a command
/// becoming real is a change to its own file and never to this one.
class FvmCommandRunner extends CommandRunner<int> {
  FvmCommandRunner(this.context)
      : super('fvm', 'A per-project Flutter SDK version manager.') {
    argParser
      ..addFlag(
        'version',
        negatable: false,
        help: 'Print the fvm version.',
      )
      // The escape hatch ARCHITECTURE.md names. Anything scripted against fvm
      // wants its output to be exactly what it asked for.
      ..addFlag(
        'version-check',
        defaultsTo: true,
        help: 'Notice when a newer fvm has been released.',
      )
      // Top-level rather than per-command so that every subcommand inherits it
      // and `fvm --help` is where somebody finds it. `${VerboseLog.variable}` is
      // the other way in, and it is the only way in for a `flutter` arriving
      // through the PATH shim, where nobody is typing a fvm command line.
      ..addFlag(
        'verbose',
        abbr: 'v',
        negatable: false,
        help: 'Explain what fvm is doing, on stderr. '
            'Also enabled by ${VerboseLog.variable}=1.',
      )
      // Beside `-v` and top-level for the same reason: every subcommand
      // inherits it, and `fvm --help` is where somebody finds it. `always` is
      // what you pass when piping into `less -R`; see [Styles.enabled] for the
      // precedence between this and NO_COLOR.
      ..addOption(
        ColorMode.flag,
        allowed: ColorMode.tokens,
        defaultsTo: ColorMode.auto.name,
        valueHelp: 'when',
        help: 'Colour the output. `auto` colours only a terminal, and honours '
            'NO_COLOR and TERM=dumb; `always` overrides both. '
            'Overrides the preference saved by `fvm config color`.',
      );

    addCommand(ConfigCommand(context: context));
    addCommand(InstallCommand(context: context));
    addCommand(UseCommand(context: context));
    addCommand(ListCommand(context: context));
    addCommand(ListRemoteCommand(context: context));
    addCommand(RemoveCommand(context: context));
    addCommand(AliasCommand(context: context));
    addCommand(UnaliasCommand(context: context));
    addCommand(GlobalCommand(context: context));
    addCommand(WhichCommand(context: context));
    addCommand(FlutterCommand(context: context));
    addCommand(DartCommand(context: context));
    addCommand(ExecCommand(context: context));
    addCommand(SetupCommand(context: context));
    addCommand(DoctorCommand(context: context));
    addCommand(UpdateCommand(context: context));
  }

  final FvmContext context;

  /// Writes usage to the injected sink instead of the process's stdout, so a
  /// test can assert on what `--help` printed.
  @override
  void printUsage() => context.out.writeln(usage);

  @override
  Future<int?> runCommand(ArgResults topLevelResults) async {
    // First, before anything can decide anything: a run asked to explain
    // itself has to explain the whole run, including the version check below.
    if (topLevelResults.flag('verbose')) context.verbose.enable();
    // Before anything prints. The environment answer is already baked in; this
    // is the flag having its say over it.
    var color = ColorMode.auto;
    if (topLevelResults.wasParsed(ColorMode.flag)) {
      color = ColorMode.values.byName(topLevelResults.option(ColorMode.flag)!);
    } else {
      try {
        color = context.config.read().color ?? ColorMode.auto;
      } on ConfigException {
        // Keep help and doctor available to diagnose a malformed config.
      }
    }
    context.styles.setMode(color);
    context.verbose.log(
      VerboseArea.cli,
      () => 'fvm ${version()} in ${context.workingDirectory.path}',
    );
    context.verbose.log(
      VerboseArea.cli,
      () => 'command: ${topLevelResults.command?.name ?? '(none)'}'
          '${topLevelResults.command == null ? '' : ' '
              '${topLevelResults.command!.rest.join(' ')}'}',
    );

    if (topLevelResults.flag('version')) {
      context.out.writeln('fvm ${version()}');
      return 0;
    }

    // `--help` on a SUBcommand. [CommandRunner] hands that to the command's
    // own `printUsage`, which writes to the process's stdout with `print` and
    // so is the one path out of this CLI that ignores [context.out]. Answered
    // here instead, so `fvm install --help` is as capturable as `fvm --help`
    // already is — same usage text, just written to the sink the caller gave.
    // `options` is asked first because `fvm flutter` and `fvm exec` parse with
    // `ArgParser.allowAnything()` and own no `--help` at all: for them the flag
    // belongs to the child SDK and must pass straight through.
    final subcommand = topLevelResults.command;
    if (subcommand != null &&
        subcommand.options.contains('help') &&
        subcommand.flag('help')) {
      final command = commands[subcommand.name];
      if (command != null) {
        context.out.writeln(command.usage);
        return 0;
      }
    }

    // Started BEFORE the command and reported after it, so the command's own
    // work is what the check runs during. `fvm update` is excluded because it
    // says all this itself, at more length.
    final check = VersionCheck(
      updater: context.updater,
      paths: context.paths,
      // stderr, not stdout: `fvm which --path` and `fvm list` are read by
      // scripts, and a notice mixed into their output would be a breaking
      // change that arrives on its own schedule.
      out: context.err,
      enabled: topLevelResults.flag('version-check') &&
          topLevelResults.command?.name != UpdateCommand.commandName,
    )..start();

    try {
      return await super.runCommand(topLevelResults);
    } finally {
      await check.report();
    }
  }
}

/// The version of this build of fvm.
String version() => kVersion;
