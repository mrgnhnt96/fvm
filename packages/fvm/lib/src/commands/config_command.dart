import 'package:args/command_runner.dart';

import '../core/context.dart';
import '../core/style.dart';

/// Reads and saves user preferences in the FVM configuration.
class ConfigCommand extends Command<int> {
  ConfigCommand({required this.context});

  final FvmContext context;

  @override
  String get name => 'config';

  @override
  String get description =>
      'Read or save preferences (color: auto, always, never).';

  @override
  String get invocation => 'fvm config color [auto|always|never]';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length > 2 || (rest.isNotEmpty && rest.first != 'color')) {
      throw UsageException('Expected: $invocation', usage);
    }
    if (rest.length == 2 && !ColorMode.tokens.contains(rest[1])) {
      throw UsageException('Color must be auto, always, or never.', usage);
    }

    var config = context.config.read();
    if (rest.length == 2) {
      config = config.copyWith(color: ColorMode.values.byName(rest[1]));
      context.config.write(config);
    }
    context.out.writeln('color: ${(config.color ?? ColorMode.auto).name}');
    return 0;
  }
}
