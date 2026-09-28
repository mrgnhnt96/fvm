import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:file/file.dart';

import '../core/channel.dart';
import '../core/context.dart';
import '../core/exceptions.dart';
import '../core/other_fvm.dart';
import '../core/project_link.dart';
import '../core/shell.dart';
import 'setup_command.dart';

/// `fvm migrate` — Move from leoafarias/fvm to this fvm.
///
/// Translates what the other tool left behind into this tool's existing
/// features and nothing more: a project pin becomes a `.fvmrc` and a
/// `.fvm/flutter_sdk` link, its global version becomes `fvm global`. What has
/// no equivalent here — flavors, forks, commits, its own settings — is named
/// and left out rather than approximated.
class MigrateCommand extends Command<int> {
  MigrateCommand({required this.context}) {
    argParser
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Show what would change without changing anything.',
      )
      ..addFlag(
        'uninstall',
        help: 'Uninstall the other fvm afterwards without asking. '
            '--no-uninstall keeps it. By default fvm asks, or only prints the '
            'uninstall commands when there is no terminal to ask at.',
      );
  }

  final FvmContext context;

  @override
  String get name => 'migrate';

  @override
  String get description => 'Move projects and the global version over from '
      'leoafarias/fvm, then offer to uninstall it.';

  @override
  String get invocation => 'fvm migrate [--dry-run] [--[no-]uninstall]';

  @override
  Future<int> run() async {
    final results = argResults!;
    final other = detectOtherFvm(context);
    final current = _currentProject();
    final projects = [
      if (current != null) current,
      for (final project in other.projects)
        if (current == null || !_samePath(project.path, current.path)) project,
    ];

    if (!other.isPresent && projects.isEmpty) {
      context.out.writeln(
        'Nothing to migrate: leoafarias/fvm is not installed, and this '
        'directory is not in a project it set up.',
      );
      return 0;
    }

    final migration = Migration(
      context: context,
      other: other,
      dryRun: results.flag('dry-run'),
    );
    final ok = await migration.run(
      projects: projects,
      uninstall:
          results.wasParsed('uninstall') ? results.flag('uninstall') : null,
    );
    return ok ? 0 : 1;
  }

  /// The nearest directory at or above the working directory that the other
  /// fvm pinned: one holding `.fvmrc` or `.fvm/fvm_config.json`.
  Directory? _currentProject() {
    final fs = context.fileSystem;
    var directory =
        fs.directory(fs.path.normalize(context.workingDirectory.absolute.path));
    while (true) {
      if (context.paths.fvmrcFile(directory).existsSync() ||
          _legacyConfig(context, directory).existsSync()) {
        return directory;
      }
      final parent = directory.parent;
      if (parent.path == directory.path) return null;
      directory = parent;
    }
  }

  bool _samePath(String a, String b) => context.fileSystem.path.equals(
        context.fileSystem.path.normalize(a),
        context.fileSystem.path.normalize(b),
      );
}

/// Detects leoafarias/fvm with this run's filesystem and environment.
OtherFvm detectOtherFvm(FvmContext context) => OtherFvmDetector(
      fileSystem: context.fileSystem,
      paths: context.paths,
      environment: context.environment,
      executablePath: context.executablePath,
    ).detect();

/// Tells the user about leoafarias/fvm after `fvm setup`, and migrates when
/// they say yes.
///
/// Returns false only when a migration was attempted and part of it failed.
Future<bool> offerMigration(FvmContext context) async {
  final other = detectOtherFvm(context);
  if (!other.isPresent) return true;

  final styles = context.styles;
  context.out
    ..writeln()
    ..writeln(styles.heading('leoafarias/fvm is also on this machine.'));
  for (final install in other.installs) {
    context.out.writeln(styles.detail(
      '  installed with ${install.source.description}: ${install.location}',
    ));
  }
  if (other.globalPin != null) {
    context.out.writeln(styles.detail('  global version: ${other.globalPin}'));
  }
  if (other.projects.isNotEmpty) {
    context.out.writeln(styles.detail(
      '  projects it set up: ${other.projects.length}',
    ));
  }

  if (!context.prompter.isInteractive) {
    context.out.writeln(
      '${styles.detail('Move them over to this fvm with: ')}'
      '${styles.command('fvm migrate')}',
    );
    return true;
  }

  final yes = context.prompter.confirm(
    'Migrate its global version and projects to this fvm now?',
    defaultValue: true,
  );
  if (!yes) {
    context.out.writeln(
      '${styles.detail('Skipped. Migrate any time with: ')}'
      '${styles.command('fvm migrate')}',
    );
    return true;
  }
  return Migration(context: context, other: other)
      .run(projects: other.projects, uninstall: null);
}

/// One run of moving from leoafarias/fvm: the global version, then each
/// project, then (optionally) uninstalling it.
class Migration {
  Migration({
    required this.context,
    required this.other,
    this.dryRun = false,
  });

  final FvmContext context;
  final OtherFvm other;
  final bool dryRun;

  /// Concrete versions already prepared, keyed by the other fvm's pin, so ten
  /// projects on `stable` cost one lookup and one install.
  final Map<String, String?> _prepared = {};

  /// Pins this run could not carry over. Any of them means the other fvm may
  /// still be needed, so uninstalling it stops being the default answer.
  final List<String> _unsupported = [];

  bool _failed = false;
  bool _installedAny = false;

  FileSystem get _fs => context.fileSystem;

  /// Runs the migration. [uninstall] null means ask, or print the commands
  /// when nobody can be asked. Returns false when anything failed.
  Future<bool> run({
    required List<Directory> projects,
    required bool? uninstall,
  }) async {
    final styles = context.styles;
    context.out
      ..writeln()
      ..writeln(styles.heading(dryRun
          ? 'Migrating from leoafarias/fvm (dry run: nothing will change)'
          : 'Migrating from leoafarias/fvm'));

    await _migrateGlobal();
    for (final project in projects) {
      await _migrateProject(project);
    }
    if (projects.isEmpty) {
      context.out.writeln(styles.detail(
        'No projects to migrate. In a project the other fvm set up, run: '
        'fvm migrate',
      ));
    }
    _reportUnusedVersions();

    if (_installedAny && !dryRun) await setupIfMissing(context);

    await _uninstall(uninstall);
    return !_failed;
  }

  Future<void> _migrateGlobal() async {
    final pin = other.globalPin;
    if (pin == null) return;
    final styles = context.styles;

    final current = context.config.read().global;
    if (current == pin) return;
    if (current != null) {
      context.out.writeln(styles.detail(
        'Kept your global version $current; the other fvm used $pin.',
      ));
      return;
    }

    final version = await _prepare(ForeignPin.parse(pin), subject: 'global');
    if (version == null) return;
    if (!dryRun) {
      final config = context.config.read();
      context.config.write(config.copyWith(global: version));
    }
    context.out.writeln(styles.ok(
      '${dryRun ? 'Would set' : 'Set'} the global version to Flutter '
      '$version${_via(pin, version)}.',
    ));
  }

  Future<void> _migrateProject(Directory project) async {
    final styles = context.styles;
    final name = context.display(project.path);
    final found = _readProjectPin(project);
    if (found == null) {
      context.out
          .writeln(styles.detail('Skipped $name: it pins no Flutter version.'));
      return;
    }
    final (:pin, :extras, :flavors) = found;

    // Parsed before anything else: a pin this fvm cannot install must be
    // reported as such, never waved through as already migrated.
    final parsed = ForeignPin.parse(pin);
    final leftovers = _leftovers(project);
    if (parsed is! UnsupportedPin &&
        extras.isEmpty &&
        flavors.isEmpty &&
        leftovers.isEmpty) {
      context.out.writeln(styles.detail(
        'Skipped $name: its .fvmrc already works with this fvm.',
      ));
      return;
    }

    final version = await _prepare(parsed, subject: name);
    if (version == null) return;

    final vscode = _vscodeFilesToUpdate(project);
    if (!dryRun) {
      try {
        context.fvmrc.write(context.paths.fvmrcFile(project), version);
        for (final entity in leftovers) {
          entity.deleteSync(recursive: entity is Directory);
        }
        linkProjectSdk(
          link: context.paths.projectSdkLink(project),
          target: context.paths.versionDir(version),
          verbose: context.verbose,
        );
        for (final file in vscode) {
          file.writeAsStringSync(_pointAtFlutterSdk(file.readAsStringSync()));
        }
      } on FileSystemException catch (error) {
        _fail('Could not migrate $name: ${error.message} (${error.path}).');
        return;
      } on FvmException catch (error) {
        _fail('Could not migrate $name: ${error.message}');
        return;
      }
    }

    context.out.writeln(styles.ok(
      '${dryRun ? 'Would migrate' : 'Migrated'} $name to Flutter '
      '$version${_via(pin, version)}.',
    ));
    for (final file in vscode) {
      context.out.writeln(styles.detail(
        '  ${context.display(file.path)}: dart.flutterSdkPath -> '
        '.fvm/flutter_sdk',
      ));
    }
    if (flavors.isNotEmpty) {
      context.out.writeln(styles.warn(
        '  ${dryRun ? 'Would remove' : 'Removed'} flavors '
        '${flavors.join(', ')}: this fvm pins one Flutter version per '
        'project.',
      ));
    }
    if (extras.isNotEmpty) {
      context.out.writeln(styles.warn(
        '  Settings with no equivalent here ${dryRun ? 'would be' : 'were'} '
        'removed from .fvmrc: ${extras.join(', ')}.',
      ));
    }
  }

  /// The pin in [project]'s `.fvmrc`, or in `.fvm/fvm_config.json` for
  /// projects set up by the other fvm before 3.0, plus the keys that have no
  /// place in this fvm's `.fvmrc`.
  ({String pin, List<String> extras, List<String> flavors})? _readProjectPin(
    Directory project,
  ) {
    final rc = context.paths.fvmrcFile(project);
    final legacy = _legacyConfig(context, project);
    final source = rc.existsSync() ? rc : legacy;
    if (!source.existsSync()) return null;

    final contents = source.readAsStringSync();
    final Object? decoded;
    try {
      decoded = jsonDecode(contents);
    } on FormatException {
      // Not JSON: this fvm's bare-version form, which needs no migrating.
      final pin = contents.trim();
      return pin.isEmpty || pin.contains('\n')
          ? null
          : (pin: pin, extras: const [], flavors: const []);
    }
    if (decoded is String) {
      return (pin: decoded.trim(), extras: const [], flavors: const []);
    }
    if (decoded is! Map<String, Object?>) return null;

    final pin = decoded['flutter'] ?? decoded['flutterSdkVersion'];
    if (pin is! String || pin.trim().isEmpty) return null;
    final flavors = decoded['flavors'];
    return (
      pin: pin.trim(),
      flavors: flavors is Map ? [for (final key in flavors.keys) '$key'] : [],
      extras: [
        for (final key in decoded.keys)
          if (key != 'flutter' &&
              key != 'flutterSdkVersion' &&
              key != 'flavors')
            key,
      ],
    );
  }

  /// What the other fvm keeps in `.fvm/` beyond the `flutter_sdk` link this fvm
  /// also uses: its old config file, its version markers, and a `versions/`
  /// directory of links into its own cache.
  List<FileSystemEntity> _leftovers(Directory project) {
    final dir = context.paths.projectFvmDir(project).path;
    return [
      for (final name in const ['fvm_config.json', 'release', 'version'])
        if (_fs.file(_fs.path.join(dir, name)).existsSync())
          _fs.file(_fs.path.join(dir, name)),
      if (_fs.directory(_fs.path.join(dir, 'versions')).existsSync())
        _fs.directory(_fs.path.join(dir, 'versions')),
      // A flutter_sdk link into the other fvm's cache breaks when it is
      // uninstalled, even if everything else is already in order.
      if (_linksIntoOtherCache(context.paths.projectSdkLink(project)))
        context.paths.projectSdkLink(project),
    ];
  }

  bool _linksIntoOtherCache(Link link) {
    final cache = other.cacheDir;
    if (cache == null) return false;
    if (_fs.typeSync(link.path, followLinks: false) !=
        FileSystemEntityType.link) {
      return false;
    }
    try {
      final target = link.targetSync();
      final absolute = _fs.path.isAbsolute(target)
          ? target
          : _fs.path.normalize(_fs.path.join(link.parent.path, target));
      return _fs.path.isWithin(cache.path, absolute);
    } on FileSystemException {
      return false;
    }
  }

  /// VS Code settings the other fvm pointed at `.fvm/versions/<version>`,
  /// which migrating removes. `.fvm/flutter_sdk` is what this fvm maintains.
  List<File> _vscodeFilesToUpdate(Directory project) {
    final candidates = <File>[
      _fs.file(_fs.path.join(project.path, '.vscode', 'settings.json')),
      for (final entity in project.listSync())
        if (entity is File && entity.path.endsWith('.code-workspace')) entity,
    ];
    return [
      for (final file in candidates)
        if (file.existsSync() &&
            _versionsPath.hasMatch(file.readAsStringSync()))
          file,
    ];
  }

  static final RegExp _versionsPath = RegExp(r'\.fvm/versions/[^"]+');

  String _pointAtFlutterSdk(String contents) =>
      contents.replaceAll(_versionsPath, '.fvm/flutter_sdk');

  /// Installs what [pin] names and returns the concrete version, or null when
  /// it cannot be carried over — having already said why.
  Future<String?> _prepare(ForeignPin pin, {required String subject}) async {
    if (_prepared.containsKey(pin.original)) {
      final version = _prepared[pin.original];
      if (version == null) {
        context.out.writeln(context.styles.warn(
          'Skipped $subject: it pins "${pin.original}" too (see above).',
        ));
      }
      return version;
    }
    final version = await _prepareOnce(pin, subject: subject);
    _prepared[pin.original] = version;
    return version;
  }

  Future<String?> _prepareOnce(
    ForeignPin pin, {
    required String subject,
  }) async {
    final styles = context.styles;
    switch (pin) {
      case UnsupportedPin(:final reason):
        _unsupported.add(pin.original);
        context.out.writeln(styles.warn(
          'Skipped $subject: it pins "${pin.original}", which this fvm cannot '
          'install because $reason. Left unchanged.',
        ));
        return null;
      case ReleasePin(:final version, :final channel):
        return await _install(version, channel: channel) ? version : null;
      case ChannelPin(:final channel):
        final recorded = context.config.read().versionForChannel(channel);
        final String version;
        if (recorded != null && context.installer.isInstalled(recorded)) {
          version = recorded;
        } else {
          try {
            version = await context.releases.latestVersion(channel);
          } on Exception catch (error) {
            _fail('Could not look up the current ${channel.token} release '
                'for $subject: $error');
            return null;
          }
        }
        if (!await _install(version, channel: channel)) return null;
        if (!dryRun) _recordChannel(channel, version);
        return version;
    }
  }

  Future<bool> _install(String version, {Channel? channel}) async {
    if (context.installer.isInstalled(version)) return true;
    if (dryRun) {
      context.out.writeln(
        context.styles.detail('Would install Flutter $version.'),
      );
      return true;
    }
    context.out.writeln('Installing Flutter $version.');
    try {
      await context.installer.install(version, channel: channel);
    } on FvmException catch (error) {
      _fail('Could not install Flutter $version: ${error.message}');
      return false;
    } on Exception catch (error) {
      _fail('Could not install Flutter $version: $error');
      return false;
    }
    if (!context.installer.isInstalled(version)) {
      _fail('Installing Flutter $version finished without leaving an SDK.');
      return false;
    }
    _installedAny = true;
    return true;
  }

  /// The same record `fvm install stable` keeps, so `stable` goes on meaning
  /// this version for `fvm use stable` and friends.
  void _recordChannel(Channel channel, String version) {
    final config = context.config.read();
    if (config.channels[channel.token] == version) return;
    context.config.write(config.copyWith(
      channels: {...config.channels, channel.token: version},
    ));
  }

  void _reportUnusedVersions() {
    final used = _prepared.values.whereType<String>().toSet();
    final unused = [
      for (final version in other.cachedVersions)
        if (!used.contains(version) && !context.installer.isInstalled(version))
          version,
    ];
    if (unused.isEmpty) return;
    context.out.writeln(context.styles.detail(
      'The other fvm also has ${unused.join(', ')}; no migrated project uses '
      '${unused.length == 1 ? 'it' : 'them'}. Install any you still want '
      'with: fvm install <version>',
    ));
  }

  Future<void> _uninstall(bool? requested) async {
    final installs = other.installs;
    final styles = context.styles;
    if (installs.isEmpty) {
      _reportLeftovers();
      return;
    }

    final bool proceed;
    if (requested != null) {
      proceed = requested;
    } else if (dryRun || !context.prompter.isInteractive) {
      proceed = false;
    } else {
      if (_unsupported.isNotEmpty) {
        context.out.writeln(styles.warn(
          'Some pins could not be migrated (${_unsupported.join(', ')}); you '
          'may still need the other fvm for them.',
        ));
      }
      final names =
          installs.map((install) => install.source.description).join(', ');
      proceed = context.prompter.confirm(
        'Uninstall leoafarias/fvm ($names)?',
        defaultValue: _unsupported.isEmpty,
      );
    }

    if (!proceed || dryRun) {
      if (dryRun && requested != false) {
        context.out.writeln(styles.detail('Would uninstall leoafarias/fvm:'));
      } else {
        context.out.writeln(
            styles.detail('Kept leoafarias/fvm. To uninstall it yourself:'));
      }
      for (final install in installs) {
        context.out.writeln('  ${styles.command(install.manualCommand)}');
      }
      return;
    }

    for (final install in installs) {
      await _uninstallOne(install);
    }
    _reportLeftovers();
  }

  Future<void> _uninstallOne(OtherFvmInstall install) async {
    final styles = context.styles;
    final command = install.command;
    if (command != null) {
      context.out.writeln(styles.detail('Running: ${command.join(' ')}'));
      int code;
      try {
        code = await context.processes.run(command.first, command.sublist(1));
      } on Exception {
        code = -1;
      }
      if (code == 0) {
        context.out.writeln(styles.ok(
          'Uninstalled the copy installed with ${install.source.description}.',
        ));
      } else {
        _fail('Could not uninstall the copy installed with '
            '${install.source.description}. Run it yourself: '
            '${install.manualCommand}');
      }
      return;
    }

    if (install.remove.isEmpty) {
      context.out.writeln(styles.warn(
        'Uninstall the copy installed with ${install.source.description} '
        'yourself: ${install.manualCommand}',
      ));
      return;
    }

    try {
      for (final entity in install.remove) {
        final type = _fs.typeSync(entity.path, followLinks: false);
        if (type == FileSystemEntityType.notFound) continue;
        // A link is deleted as a link, never followed.
        if (type == FileSystemEntityType.link) {
          _fs.link(entity.path).deleteSync();
        } else {
          entity.deleteSync(recursive: true);
        }
        context.out.writeln(styles.detail('Removed ${entity.path}'));
      }
      context.out.writeln(styles.ok(
        'Uninstalled the copy installed with ${install.source.description}.',
      ));
    } on FileSystemException catch (error) {
      _fail('Could not remove ${error.path ?? install.location}: '
          '${error.message}. Run it yourself: ${install.manualCommand}');
    }
  }

  /// What uninstalling deliberately leaves: the SDK cache, which the other
  /// fvm's own uninstaller keeps too, and PATH lines in startup files, which
  /// this fvm never edits beyond its own marked line.
  void _reportLeftovers() {
    final styles = context.styles;
    final cache = other.cacheDir;
    if (cache != null &&
        (other.cachedVersions.isNotEmpty || other.globalPin != null)) {
      context.out.writeln(styles.detail(
        'The other fvm\'s SDKs are still in ${cache.path}. Delete that '
        'directory when you no longer need them.',
      ));
    }

    final lines = _startupLinesForOtherFvm();
    if (lines.isEmpty) return;
    context.out.writeln(styles.warn(
      'These startup file lines still point at the other fvm. Remove them, '
      'then open a new terminal:',
    ));
    for (final line in lines) {
      context.out.writeln('  $line');
    }
  }

  List<String> _startupLinesForOtherFvm() {
    final shell = ShellFacts(
      fileSystem: _fs,
      environment: context.environment,
    );
    final cache = other.cacheDir?.path;
    final markers = [
      if (cache != null) cache,
      r'$HOME/fvm/',
      r'${HOME}/fvm/',
      '~/fvm/',
      '.fvm_flutter',
    ];
    final found = <String>[];
    for (final file in shell.rcCandidates) {
      if (!file.existsSync()) continue;
      final List<String> lines;
      try {
        lines = file.readAsLinesSync();
      } on FileSystemException {
        continue;
      }
      for (var i = 0; i < lines.length; i++) {
        final text = lines[i].trim();
        if (text.isEmpty || text.startsWith('#')) continue;
        if (markers.any(text.contains)) {
          found.add('${file.path}:${i + 1}: $text');
        }
      }
    }
    return found;
  }

  void _fail(String message) {
    _failed = true;
    context.err.writeln(context.styles.fail(message));
  }

  /// ` (was "stable")` when the recorded pin changes spelling.
  String _via(String pin, String version) =>
      pin == version ? '' : ' (was "$pin")';
}

File _legacyConfig(FvmContext context, Directory project) =>
    context.fileSystem.file(context.fileSystem.path.join(
      context.paths.projectFvmDir(project).path,
      'fvm_config.json',
    ));
