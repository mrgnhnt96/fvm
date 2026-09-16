import 'package:args/command_runner.dart';

import '../core/context.dart';
import '../core/exceptions.dart';
import 'version_ref.dart';

/// `fvm global` — Set the version used when no .fvmrc applies.
class GlobalCommand extends Command<int> {
  GlobalCommand({required this.context});

  final FvmContext context;

  @override
  String get name => 'global';

  @override
  String get description => 'Set the version used when no .fvmrc applies.';

  @override
  String get invocation => 'fvm global <version>';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) return _report();
    if (rest.length > 1) {
      throw UsageException(
        'Global takes one version, but got: ${rest.join(' ')}',
        usage,
      );
    }

    final ref = resolveVersionRef(context, rest.single);
    await ensureInstalled(context, ref);
    writeGlobal(context, ref);
    return 0;
  }

  /// `fvm global` with no argument answers "what is it now?".
  int _report() {
    final global = context.config.read().global;
    if (global == null) {
      context.out.writeln(
        'No global default is set. Directories with no .fvmrc fall through to '
        'the first flutter on PATH.\n'
        'Set one with: fvm global <version>',
      );
      return 0;
    }

    context.out.writeln('The global default is $global.');

    // A global naming something that is not installed is not hypothetical: it
    // is what `fvm remove --force` leaves behind, and every command run
    // outside a pinned project fails until it is fixed.
    if (!context.installer.isInstalled(global)) {
      final ref = _tryResolve(global);
      if (ref == null || !context.installer.isInstalled(ref.version)) {
        context.err.writeln(
          'It is not installed. Run: fvm install $global',
        );
        return 1;
      }
      context.out.writeln('  ${ref.trail}');
    }
    context.out.writeln('  ${context.display(context.paths.configFile.path)}');
    return 0;
  }

  VersionRef? _tryResolve(String pin) {
    try {
      return resolveVersionRef(context, pin);
    } on FvmException {
      return null;
    }
  }
}
