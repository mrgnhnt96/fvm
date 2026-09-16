import 'package:args/command_runner.dart';

import '../core/channel.dart';
import '../core/context.dart';
import '../core/resolver.dart';

/// `fvm which` — Print the resolved SDK and which rule chose it. (alias: current)
class WhichCommand extends Command<int> {
  WhichCommand({required this.context}) {
    argParser.addFlag(
      'path',
      negatable: false,
      help: 'Print only the path to the flutter executable, for scripting.',
    );
  }

  final FvmContext context;

  @override
  String get name => 'which';

  @override
  String get description =>
      'Print the resolved SDK and which rule chose it. (alias: current)';

  @override
  List<String> get aliases => const ['current'];

  @override
  Future<int> run() async {
    // Rule 5 throws out of here with the message that enumerates all five
    // rules and what to run, which is exactly what `which` would print.
    final resolved = context.resolver.resolve(from: context.workingDirectory);

    // ABSOLUTE, unconditionally, and NOT through `context.display`. These two
    // lines are the machine-readable ones: `--path` is the flag's entire
    // output, and the first line of the default output is what
    // `fvm which | head -1` takes. A relative path resolves against the
    // CALLER's working directory, which is not necessarily fvm's, so a
    // consumer handed `.fvm/flutter_sdk/bin/flutter` silently points at nothing.
    // Everything below here is prose for a human and follows the normal rule.
    if (argResults!.flag('path')) {
      context.out.writeln(resolved.executable.path);
      return 0;
    }

    context.out.writeln(resolved.executable.path);
    if (resolved.version != null) {
      context.out.writeln('Flutter ${resolved.version}');
    }
    context.out.writeln(_explainRule(resolved));

    final indirection = _explainIndirection(resolved);
    if (indirection != null) context.out.writeln('  $indirection');

    context.out.writeln('SDK: ${context.display(resolved.sdkDir.path)}');
    if (!resolved.isManaged) {
      context.out.writeln(
        'This SDK is not managed by fvm. Pin one for this directory with: '
        'fvm use <version>',
      );
    }
    return 0;
  }

  /// The whole point of the command: which of the five rules answered, said
  /// the way a person would say it.
  String _explainRule(ResolvedSdk resolved) {
    final source = _displaySource(resolved);
    return switch (resolved.rule) {
      ResolutionRule.environmentVariable =>
        'Chosen by rule 1 of 5: ${VersionResolver.versionVariable} is set in '
            'the environment, which overrides everything on disk.',
      ResolutionRule.fvmrc => 'Chosen by rule 2 of 5: pinned by $source.',
      ResolutionRule.globalDefault =>
        'Chosen by rule 3 of 5: no .fvmrc applies here, so the global '
            'default in $source was used.',
      ResolutionRule.pathFallback =>
        'Chosen by rule 4 of 5: nothing pins a version here and no global '
            'default is set, so this is the next flutter on PATH, found in '
            '$source.',
    };
  }

  /// Where the answer came from, formatted for a human.
  ///
  /// [ResolvedSdk.source] is nullable in general, but every rule that names it
  /// above sets it. Falling back to a placeholder rather than `!` keeps a
  /// later rule that forgets from crashing `which`, which is the command
  /// people reach for precisely when something is already wrong.
  String _displaySource(ResolvedSdk resolved) {
    final source = resolved.source;
    return source == null ? '(unknown)' : context.display(source);
  }

  /// The hop from what was written down to what it turned out to mean.
  String? _explainIndirection(ResolvedSdk resolved) {
    final requested = resolved.requested;
    final version = resolved.version;
    if (requested == null || version == null || requested == version) {
      return null;
    }

    final channel = Channel.tryParse(requested);
    if (channel != null) {
      return 'It says "$requested", the channel that was recorded as '
          '$version when it was last installed.';
    }
    return 'It says "$requested", an alias for $version in '
        '${context.display(context.paths.configFile.path)}.';
  }
}
