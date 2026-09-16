import 'package:args/command_runner.dart';
import 'package:file/file.dart';
import 'package:pub_semver/pub_semver.dart';

import '../core/context.dart';
import '../core/exceptions.dart';
import '../core/resolver.dart';
import 'version_ref.dart';

/// `fvm list` — List installed SDKs, marking the global and the current project. (alias: ls)
class ListCommand extends Command<int> {
  ListCommand({required this.context});

  final FvmContext context;

  @override
  String get name => 'list';

  @override
  String get description =>
      'List installed SDKs, marking the global and the current project. (alias: ls)';

  @override
  List<String> get aliases => const ['ls'];

  @override
  Future<int> run() async {
    final versions = _installedVersions();
    if (versions.isEmpty) {
      context.out.writeln(
        'No Flutter SDKs are installed in '
        '${context.display(context.paths.versionsDir.path)}.\n'
        'Install one with: fvm install stable',
      );
      return 0;
    }

    final config = context.config.read();
    final project = _resolveProject();
    final namesFor = _namesByVersion(config.aliases, 'alias');
    final channelsFor = _namesByVersion(config.channels, 'channel');
    final width = versions.map((v) => v.length).reduce((a, b) => a > b ? a : b);

    context.out
      ..writeln('Installed Flutter SDKs in '
          '${context.display(context.paths.versionsDir.path)}:')
      ..writeln();

    for (final version in versions) {
      final tags = <String>[
        if (project.sdk?.version == version) 'this project',
        if (config.global == version) 'global default',
        ...?channelsFor[version],
        ...?namesFor[version],
        if (!context.installer.isInstalled(version)) 'BROKEN: no bin/flutter',
      ];
      final marker = project.sdk?.version == version ? '*' : ' ';
      final suffix = tags.isEmpty ? '' : '  ${tags.join(', ')}';
      context.out.writeln('$marker ${version.padRight(width)}$suffix');
    }

    context.out.writeln();
    context.out.writeln(project.summary);

    final global = config.global;
    if (global != null && !versions.contains(global)) {
      context.err.writeln(
        'The global default names $global, which is not installed. '
        'Run: fvm install $global',
      );
    }
    return 0;
  }

  /// Every directory under `versions/`, newest first.
  ///
  /// Directories that are not usable SDKs are listed rather than hidden: a
  /// half-removed version taking up disk is something the user came here to
  /// find out about.
  List<String> _installedVersions() {
    final directory = context.paths.versionsDir;
    if (!directory.existsSync()) return const [];

    final names = [
      for (final entity in directory.listSync())
        if (entity is Directory) context.fileSystem.path.basename(entity.path),
    ];
    names.sort(_newestFirst);
    return names;
  }

  /// Semver order, newest first, with anything unparseable sorted after by
  /// name — the archive's Flutter 1 build numbers land there, and so does
  /// whatever a user happened to drop into `versions/`.
  int _newestFirst(String a, String b) {
    final left = _tryVersion(a);
    final right = _tryVersion(b);
    if (left != null && right != null) return right.compareTo(left);
    if (left != null) return -1;
    if (right != null) return 1;
    return a.compareTo(b);
  }

  /// pub_semver only offers a throwing parse, and `versions/` can hold names
  /// that are not semver at all.
  Version? _tryVersion(String value) {
    try {
      return Version.parse(value);
    } on FormatException {
      return null;
    }
  }

  /// Groups the names in [mapping] under the concrete version each resolves to.
  Map<String, List<String>> _namesByVersion(
    Map<String, String> mapping,
    String kind,
  ) {
    final result = <String, List<String>>{};
    for (final entry in mapping.entries) {
      // An alias can point at a channel or at another alias, so the target is
      // followed rather than compared directly. A broken one is skipped here
      // and reported by `fvm alias list`, which is where a user is looking
      // when they care about it.
      final version = _tryResolve(entry.key)?.version ?? entry.value;
      result.putIfAbsent(version, () => []).add('$kind: ${entry.key}');
    }
    return result;
  }

  VersionRef? _tryResolve(String pin) {
    try {
      return resolveVersionRef(context, pin);
    } on FvmException {
      return null;
    }
  }

  /// What this directory resolves to right now, and why — the same question
  /// `which` answers, summarised in one line under the list.
  _ProjectResolution _resolveProject() {
    final ResolvedSdk resolved;
    try {
      resolved = context.resolver.resolve(from: context.workingDirectory);
    } on FvmException catch (error) {
      return _ProjectResolution(
        null,
        // The working directory itself, so absolute by the display rule and
        // by intent: the line says where "here" is.
        '* nothing: ${context.workingDirectory.path} does not resolve to an '
        'installed SDK.\n  ${error.message.split('\n').first}',
      );
    }

    if (!resolved.isManaged) {
      return _ProjectResolution(
        null,
        '* none of these: ${context.workingDirectory.path} falls through to '
        '${context.display(resolved.executable.path)} on PATH (rule 4 of 5).',
      );
    }

    final via =
        resolved.requested != null && resolved.requested != resolved.version
            ? ' via "${resolved.requested}"'
            : '';
    // The same wording `fvm which` uses, so the two commands do not describe
    // one resolution in two different vocabularies.
    final why = switch (resolved.rule) {
      ResolutionRule.environmentVariable =>
        'set by ${VersionResolver.versionVariable}',
      ResolutionRule.fvmrc => 'pinned by ${_displaySource(resolved)}',
      ResolutionRule.globalDefault =>
        'the global default in ${_displaySource(resolved)}',
      ResolutionRule.pathFallback => 'found on PATH',
    };
    return _ProjectResolution(
      resolved,
      '* = what ${context.workingDirectory.path} resolves to right now: '
      '$why$via.',
    );
  }

  /// Where the answer came from, formatted for a human. Mirrors
  /// `WhichCommand`'s: nullable in general, set by every rule that names it.
  String _displaySource(ResolvedSdk resolved) {
    final source = resolved.source;
    return source == null ? '(unknown)' : context.display(source);
  }
}

/// The resolved SDK for the working directory, plus the line explaining it.
class _ProjectResolution {
  const _ProjectResolution(this.sdk, this.summary);

  /// Null when nothing resolved, or when what resolved is not fvm-managed —
  /// either way there is no row in the list to mark.
  final ResolvedSdk? sdk;

  final String summary;
}
