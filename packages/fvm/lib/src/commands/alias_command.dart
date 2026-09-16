import 'package:args/command_runner.dart';

import '../core/channel.dart';
import '../core/config.dart';
import '../core/context.dart';
import '../core/exceptions.dart';
import 'version_ref.dart';

/// `fvm alias` — Give a version a name, or list the names you have.
class AliasCommand extends Command<int> {
  AliasCommand({required this.context});

  final FvmContext context;

  @override
  String get name => 'alias';

  @override
  String get description =>
      'Give a version a name, or list the names you have.';

  @override
  String get invocation => 'fvm alias <name> <version> | alias list';

  /// The one name that cannot be an alias for reasons other than shadowing:
  /// `fvm alias list 3.9.0` has to keep meaning "show me the aliases".
  static const String _listSubcommand = 'list';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty || (rest.length == 1 && rest.single == _listSubcommand)) {
      return _list();
    }
    if (rest.length == 1) {
      throw UsageException(
        'Say which version "${rest.single}" should mean: '
        'fvm alias ${rest.single} <version>',
        usage,
      );
    }
    if (rest.length > 2) {
      throw UsageException(
        'An alias is one name and one version, but got: ${rest.join(' ')}',
        usage,
      );
    }

    return _define(rest[0], rest[1]);
  }

  int _define(String aliasName, String target) {
    final rejection =
        _rejectName(aliasName) ?? _rejectTarget(aliasName, target);
    if (rejection != null) {
      context.err.writeln(rejection);
      return 1;
    }

    final config = context.config.read();
    final previous = config.aliases[aliasName];
    context.config.write(
      config.copyWith(aliases: {...config.aliases, aliasName: target}),
    );

    context.out.writeln('"$aliasName" now means $target.');
    if (previous != null && previous != target) {
      context.out.writeln('  was: $previous');
    }
    _warnIfUnusable(aliasName, target);
    return 0;
  }

  /// Why [aliasName] cannot be an alias, or null if it can.
  ///
  /// Shadowing is the failure this guards against: an alias named `stable`
  /// would be unreachable, because resolution checks channels before aliases,
  /// and the user would be left with a name in their config that silently does
  /// nothing. Refusing up front is the only place that is cheap to explain.
  String? _rejectName(String aliasName) {
    if (aliasName.isEmpty) return 'An alias needs a name.';

    if (Channel.tryParse(aliasName) != null) {
      return '"$aliasName" is a Flutter release channel, so it cannot be an '
          'alias. Channel names always mean the version that channel resolved '
          'to when you last ran: fvm install $aliasName';
    }
    if (looksLikeVersion(aliasName)) {
      return '"$aliasName" looks like a version, so it cannot be an alias: '
          'fvm would have no way to tell the two apart. Pick a name that does '
          'not start with a digit, like: fvm alias work $aliasName';
    }
    if (aliasName == _listSubcommand) {
      return '"$_listSubcommand" cannot be an alias: `fvm alias list` means '
          '"show me the aliases".';
    }
    if (aliasName.startsWith('-')) {
      return '"$aliasName" cannot be an alias: a leading dash reads as an '
          'option.';
    }
    if (RegExp(r'[\s/\\]').hasMatch(aliasName)) {
      return '"$aliasName" cannot be an alias: a name is a single word with '
          'no whitespace or path separators in it.';
    }
    return null;
  }

  /// Why [target] cannot be what [aliasName] points at, or null if it can.
  String? _rejectTarget(String aliasName, String target) {
    if (target.isEmpty) return 'An alias needs a version to point at.';
    if (RegExp(r'\s').hasMatch(target)) {
      return '"$target" is not a version: a version, channel or alias name is '
          'a single word.';
    }
    if (target == aliasName) {
      return 'An alias cannot point at itself.';
    }
    if (wouldCycle(context.config.read().aliases, aliasName, target)) {
      return 'Pointing "$aliasName" at "$target" would make a loop of '
          'aliases that never reaches a version. Point it at a version '
          'instead.';
    }
    return null;
  }

  /// An alias may legitimately be written before the SDK exists, so a target
  /// that is not installed is a note rather than a refusal — but a silent one
  /// would look like the alias is broken the first time it is used.
  void _warnIfUnusable(String aliasName, String target) {
    final VersionRef ref;
    try {
      ref = resolveVersionRef(context, aliasName);
    } on FvmException catch (error) {
      context.out.writeln('  ${error.message.split('\n').first}');
      return;
    }

    if (!ref.isDirect) context.out.writeln('  ${ref.trail}');
    if (!context.installer.isInstalled(ref.version)) {
      context.out.writeln(
        '  Flutter ${ref.version} is not installed. Run: fvm install $target',
      );
    }
  }

  int _list() {
    final config = context.config.read();
    if (config.aliases.isEmpty) {
      context.out.writeln(
        'No aliases yet. Create one with: fvm alias work 3.9.0',
      );
      _listChannels(config);
      return 0;
    }

    final names = config.aliases.keys.toList()..sort();
    final width = names.map((n) => n.length).reduce((a, b) => a > b ? a : b);

    context.out
      ..writeln('Aliases in ${context.display(context.paths.configFile.path)}:')
      ..writeln();
    for (final aliasName in names) {
      context.out.writeln(
        '  ${aliasName.padRight(width)} -> ${_describeTarget(aliasName)}',
      );
    }
    _listChannels(config);
    return 0;
  }

  String _describeTarget(String aliasName) {
    final target = context.config.read().aliases[aliasName]!;
    final VersionRef ref;
    try {
      ref = resolveVersionRef(context, aliasName);
    } on FvmException catch (error) {
      return '$target  (broken: ${error.message.split('\n').first})';
    }

    // The hops after the alias name itself: `work -> stable -> 3.13.2` reads
    // as `stable -> 3.13.2` once the name is already in the left column.
    final trail = ref.hops.skip(1).join(' -> ');
    final state = context.installer.isInstalled(ref.version)
        ? 'installed'
        : 'NOT installed';
    return '$trail  ($state)';
  }

  /// Channels are shown alongside aliases because they are the other way a
  /// name maps to a version, and the two are easy to confuse.
  void _listChannels(FvmConfig config) {
    if (config.channels.isEmpty) return;
    context.out.writeln();
    context.out.writeln('Channels, as recorded by fvm install:');
    for (final entry in config.channels.entries) {
      context.out.writeln('  ${entry.key} -> ${entry.value}');
    }
  }
}
