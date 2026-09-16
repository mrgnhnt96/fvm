import 'package:args/command_runner.dart';
import 'package:file/file.dart';

import '../core/context.dart';
import '../core/exceptions.dart';
import 'version_ref.dart';

/// `fvm remove` — Delete an installed SDK.
class RemoveCommand extends Command<int> {
  RemoveCommand({required this.context}) {
    argParser.addFlag(
      'force',
      abbr: 'f',
      negatable: false,
      help: 'Remove it even if something still points at it.',
    );
  }

  final FvmContext context;

  @override
  String get name => 'remove';

  @override
  String get description => 'Delete an installed SDK.';

  @override
  String get invocation => 'fvm remove <version> [--force]';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      throw UsageException('Name a version to remove.', usage);
    }
    if (rest.length > 1) {
      throw UsageException(
        'Remove takes one version at a time, but got: ${rest.join(' ')}',
        usage,
      );
    }

    final ref = resolveVersionRef(context, rest.single);
    final version = ref.version;
    final directory = context.paths.versionDir(version);

    if (!directory.existsSync()) {
      context.err.writeln(
        'Flutter $version is not installed, so there is nothing to remove. '
        'See what is: fvm list',
      );
      return 1;
    }

    final dependents = _dependents(version);
    final force = argResults!.flag('force');
    if (dependents.isNotEmpty && !force) {
      final count = dependents.length == 1
          ? 'something still points'
          : '${dependents.length} things still point';
      context.err.writeln(
        'Refusing to remove Flutter $version: $count at it.\n'
        '${dependents.map((d) => '  - $d').join('\n')}\n'
        'Repoint them first, or remove it anyway with: '
        'fvm remove ${rest.single} --force',
      );
      return 1;
    }

    final refusal = _deleteSdk(directory, version);
    if (refusal != null) {
      context.err.writeln(refusal);
      return 1;
    }
    context.out.writeln(
        'Removed Flutter $version (${context.display(directory.path)}).');

    _dropStaleChannelRecords(version);
    if (dependents.isNotEmpty) {
      context.err.writeln(
        'These now point at a version that is not installed:\n'
        '${dependents.map((d) => '  - $d').join('\n')}',
      );
    }
    _warnAboutProjectPin(version);
    return 0;
  }

  /// Deletes the SDK at [directory], or returns the sentence to print instead
  /// of "Removed Flutter [version]".
  ///
  /// The delete is the one step in this command that asks the operating system
  /// for something it is entitled to refuse, and Windows refuses it routinely:
  /// a file cannot be deleted there while a program is running it, so
  /// `fvm remove` aimed at the SDK an editor's analysis server was started
  /// from comes back with ERROR_ACCESS_DENIED. Left uncaught, the Dart VM
  /// turned that into a stack trace and exit 255 — a crash report, for a
  /// situation the user can clear in ten seconds once someone names it.
  ///
  /// POSIX unlinks a running executable happily, because the inode outlives
  /// the directory entry, which is why this only ever showed up on Windows.
  String? _deleteSdk(Directory directory, String version) {
    try {
      directory.deleteSync(recursive: true);
      return null;
    } on FileSystemException catch (error) {
      // The OS's own words, not this exception's `toString`, which leads with
      // the class name and repeats the path.
      final said = error.osError?.message ?? error.message;
      final advice = context.paths.isWindows
          ? 'Windows keeps a hold on a file while a program is running it, so '
              'something started from this SDK is most likely still up: an '
              'editor analysing a project pinned to it, a `flutter` or `flutter run` '
              'in another terminal, a language server. Close it and run this '
              'again.'
          : 'Check that everything under it is yours to delete and that '
              'nothing has it open, then run this again.';
      return 'Could not remove Flutter $version: $said\n'
          '  ${context.display(directory.path)}\n'
          '$advice\n'
          'Part of the SDK may already have been deleted before this stopped, '
          'so running the same command again is what finishes the job.';
    }
  }

  /// What still names [version] and would break if it went away.
  ///
  /// Channel records are deliberately not in here. Every SDK installed with
  /// `fvm install stable` has one, so counting them would make `remove` refuse
  /// almost everything; the stale record is dropped after the delete instead.
  List<String> _dependents(String version) {
    final config = context.config.read();
    final dependents = <String>[];

    final global = config.global;
    if (global != null && _resolvesTo(global, version)) {
      dependents.add(
        'the global default${global == version ? '' : ' ("$global")'} in '
        '${context.display(context.paths.configFile.path)}',
      );
    }

    for (final entry in config.aliases.entries) {
      if (_resolvesTo(entry.key, version)) {
        dependents.add(
          'the alias "${entry.key}" -> ${entry.value}'
          '${entry.value == version ? '' : ' -> $version'}',
        );
      }
    }
    return dependents;
  }

  /// Whether [pin] ends up at [version] once aliases and channels are
  /// followed. A pin that cannot be resolved at all points at nothing, so it
  /// is not a dependent.
  bool _resolvesTo(String pin, String version) {
    try {
      return resolveVersionRef(context, pin).version == version;
    } on FvmException {
      return false;
    }
  }

  /// Forgets `channels.<token>` entries naming the version just deleted.
  ///
  /// Leaving one behind means `fvm use stable` reports that stable is not
  /// installed while claiming to know exactly which version it is. The
  /// record is only meaningful while the SDK it names is on disk.
  void _dropStaleChannelRecords(String version) {
    final config = context.config.read();
    final stale = [
      for (final entry in config.channels.entries)
        if (entry.value == version) entry.key,
    ];
    if (stale.isEmpty) return;

    context.config.write(
      config.copyWith(
        channels: {
          for (final entry in config.channels.entries)
            if (entry.value != version) entry.key: entry.value,
        },
      ),
    );
    for (final channel in stale) {
      context.out.writeln(
        'fvm no longer knows which version "$channel" is. '
        'Run: fvm install $channel',
      );
    }
  }

  /// A `.fvmrc` is project data, not machine state, so it never blocks a
  /// removal — but the user is about to hit an error in that directory and
  /// should hear it from the command that caused it.
  void _warnAboutProjectPin(String version) {
    final rcFile = context.fvmrc.findNearest(context.workingDirectory);
    if (rcFile == null) return;

    final String? pin;
    try {
      pin = context.fvmrc.read(rcFile);
    } on FvmException {
      return;
    }
    if (pin == null || !_resolvesTo(pin, version)) return;

    context.err.writeln(
      '${context.display(rcFile.path)} pins the version just removed. '
      'Run: fvm use <version>',
    );
  }
}
