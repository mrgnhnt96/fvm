import 'package:args/command_runner.dart';

import '../core/context.dart';
import '../core/updater.dart';

/// `fvm update` — Update fvm itself to the newest release.
class UpdateCommand extends Command<int> {
  UpdateCommand({required this.context}) {
    argParser.addFlag(
      'check',
      negatable: false,
      help: 'Report whether a newer fvm exists, without installing anything.',
    );
  }

  final FvmContext context;

  /// The name this command is registered under, so `lib/fvm.dart` can exclude
  /// it from the ambient version check without spelling it a second time.
  static const String commandName = 'update';

  @override
  String get name => commandName;

  @override
  String get description => 'Update fvm itself to the newest release.';

  @override
  String get invocation => 'fvm update [version]';

  @override
  Future<int> run() async {
    final results = argResults!;
    final version = switch (results.rest) {
      [] => null,
      [final String only] => only,
      final rest => throw UsageException(
          'fvm update takes at most one version, got ${rest.length}.',
          usage,
        ),
    };

    final check = results.flag('check');
    final updater = context.updater;

    try {
      final outcome = await updater.update(
        executablePath: context.executablePath,
        version: version,
        check: check,
      );

      switch (outcome.status) {
        case UpdateStatus.upToDate:
          context.out.writeln('fvm ${outcome.from} is already up to date.');

        case UpdateStatus.available:
          context.out
            ..writeln(
              'A newer fvm is available: ${outcome.from} -> ${outcome.to}',
            )
            ..writeln('Run `fvm update` to install it.');

        case UpdateStatus.installed:
          context.out.writeln(
            'Updated fvm ${outcome.from} -> ${outcome.to} '
            '(${context.executablePath}).',
          );
      }

      return 0;
    } finally {
      // The HTTP client would otherwise keep the VM alive for as long as its
      // idle connections do.
      updater.close();
    }
  }
}
