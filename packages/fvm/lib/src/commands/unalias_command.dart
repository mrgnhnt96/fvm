import 'package:args/command_runner.dart';

import '../core/context.dart';

/// `fvm unalias` — Remove a named version.
class UnaliasCommand extends Command<int> {
  UnaliasCommand({required this.context});

  final FvmContext context;

  @override
  String get name => 'unalias';

  @override
  String get description => 'Remove a named version.';

  @override
  String get invocation => 'fvm unalias <name>';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      throw UsageException('Name the alias to remove.', usage);
    }
    if (rest.length > 1) {
      throw UsageException(
        'Unalias takes one name at a time, but got: ${rest.join(' ')}',
        usage,
      );
    }

    final aliasName = rest.single;
    final config = context.config.read();
    final target = config.aliases[aliasName];
    if (target == null) {
      context.err.writeln(
        config.aliases.isEmpty
            ? 'There is no alias "$aliasName"; no aliases are defined.'
            : 'There is no alias "$aliasName". Defined: '
                '${(config.aliases.keys.toList()..sort()).join(', ')}',
      );
      return 1;
    }

    context.config.write(
      config.copyWith(
        aliases: {
          for (final entry in config.aliases.entries)
            if (entry.key != aliasName) entry.key: entry.value,
        },
      ),
    );
    context.out.writeln(
      'Removed the alias "$aliasName" (it meant $target). '
      'The SDK itself is untouched.',
    );

    _warnAboutDanglingReferences(aliasName);
    return 0;
  }

  /// Anything still spelled with the name that just stopped existing.
  ///
  /// A global default naming a deleted alias is the bad one: the name is no
  /// longer an alias, so resolution treats it as a concrete version and
  /// reports that a version called "work" is not installed.
  void _warnAboutDanglingReferences(String aliasName) {
    final config = context.config.read();

    if (config.global == aliasName) {
      context.err.writeln(
        'The global default still says "$aliasName", which no longer means '
        'anything. Run: fvm global <version>',
      );
    }
    for (final entry in config.aliases.entries) {
      if (entry.value == aliasName) {
        context.err.writeln(
          'The alias "${entry.key}" still points at "$aliasName". '
          'Run: fvm alias ${entry.key} <version>',
        );
      }
    }

    final rcFile = context.fvmrc.findNearest(context.workingDirectory);
    if (rcFile == null) return;
    try {
      if (context.fvmrc.read(rcFile) == aliasName) {
        context.err.writeln(
          '${context.display(rcFile.path)} still pins "$aliasName". '
          'Run: fvm use <version>',
        );
      }
    } on Object {
      // A malformed .fvmrc is not this command's problem to report; `which`
      // and every command that resolves will say so with the right message.
      return;
    }
  }
}
