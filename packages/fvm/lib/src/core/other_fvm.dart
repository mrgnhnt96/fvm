import 'dart:convert';

import 'package:file/file.dart';
import 'package:path/path.dart' as p;

import 'channel.dart';
import 'paths.dart';

/// How a copy of leoafarias/fvm got onto this machine, which decides how it
/// comes off again.
enum OtherFvmSource {
  /// fvm.app/install.sh: a binary in `~/fvm/bin`, or `~/.fvm_flutter/bin`
  /// with a `/usr/local/bin/fvm` symlink for the older installer.
  installScript('its install script'),

  /// `brew install fvm`.
  homebrew('Homebrew'),

  /// `dart pub global activate fvm`.
  pubGlobal('dart pub global'),

  /// `choco install fvm`.
  chocolatey('Chocolatey');

  const OtherFvmSource(this.description);

  /// How the install is named in output: "installed with Homebrew".
  final String description;
}

/// One installed copy of the other fvm executable.
class OtherFvmInstall {
  const OtherFvmInstall({
    required this.source,
    required this.location,
    required this.manualCommand,
    this.command,
    this.remove = const [],
  });

  final OtherFvmSource source;

  /// Where it was found, for output.
  final String location;

  /// The command that uninstalls it, run by `fvm migrate`. Null when it has to
  /// be run by the user instead (Chocolatey needs an administrator shell).
  final List<String>? command;

  /// Paths `fvm migrate` deletes to uninstall it, when there is no command.
  final List<FileSystemEntity> remove;

  /// What the user runs to uninstall it themselves.
  final String manualCommand;
}

/// Everything leoafarias/fvm left on this machine that `fvm migrate` reads.
class OtherFvm {
  const OtherFvm({
    required this.cacheDir,
    required this.installs,
    required this.globalPin,
    required this.cachedVersions,
    required this.projects,
  });

  /// Where it keeps its SDKs: `~/fvm` unless `FVM_CACHE_PATH` or its settings
  /// file moved it. Null when that is this fvm's own home, or unknowable.
  final Directory? cacheDir;

  final List<OtherFvmInstall> installs;

  /// What its `default` link points at, the way it would be written in a
  /// `.fvmrc`, or null when it has no global version.
  final String? globalPin;

  /// The SDKs in its cache.
  final List<String> cachedVersions;

  /// The project roots it tracked that still exist.
  final List<Directory> projects;

  /// Whether there is anything to migrate or uninstall.
  bool get isPresent =>
      installs.isNotEmpty ||
      globalPin != null ||
      cachedVersions.isNotEmpty ||
      projects.isNotEmpty;
}

/// Finds leoafarias/fvm's installs, cache, global version and projects.
///
/// Reads the filesystem and environment only. It never runs the other fvm,
/// which may be broken, may be the thing about to be uninstalled, and would
/// print its own update notices into our output.
class OtherFvmDetector {
  OtherFvmDetector({
    required this.fileSystem,
    required this.paths,
    required Map<String, String> environment,
    this.executablePath = '',
  }) : _environment = environment;

  final FileSystem fileSystem;
  final FvmPaths paths;
  final Map<String, String> _environment;

  /// The running fvm. Anything that resolves to it is ours, not the other one.
  final String executablePath;

  p.Context get _path => fileSystem.path;
  bool get _isWindows => _path.style == p.Style.windows;

  OtherFvm detect() {
    final cacheDir = _cacheDir();
    // FVM_HOME is also the other fvm's legacy name for its cache. Someone who
    // set it for that tool now has both tools sharing one directory, and there
    // is no telling which files are whose.
    final shared = cacheDir != null && _same(cacheDir.path, paths.home.path);
    final usable = shared ? null : cacheDir;

    return OtherFvm(
      cacheDir: usable,
      installs: _installs(),
      globalPin: usable == null ? null : _globalPin(usable),
      cachedVersions: usable == null ? const [] : _cachedVersions(usable),
      projects: usable == null ? const [] : _projects(usable),
    );
  }

  String? get _home {
    for (final variable in _isWindows
        ? const ['USERPROFILE', 'HOME']
        : const ['HOME', 'USERPROFILE']) {
      final value = _environment[variable]?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  /// `FVM_CACHE_PATH`, then `cachePath` in its settings file, then `~/fvm`.
  Directory? _cacheDir() {
    final fromEnv = _environment['FVM_CACHE_PATH']?.trim();
    if (fromEnv != null && fromEnv.isNotEmpty) {
      return fileSystem.directory(fromEnv);
    }
    for (final settings in _settingsFiles()) {
      final cachePath = _readJson(settings)?['cachePath'];
      if (cachePath is String && cachePath.trim().isNotEmpty) {
        return fileSystem.directory(cachePath.trim());
      }
    }
    final home = _home;
    return home == null ? null : fileSystem.directory(_path.join(home, 'fvm'));
  }

  /// Its machine-wide settings: `<config home>/fvm/.fvmrc`.
  List<File> _settingsFiles() {
    final home = _home;
    final roots = <String>[
      if (_isWindows && _environment['APPDATA'] != null)
        _environment['APPDATA']!,
      if (!_isWindows && home != null) ...[
        _path.join(home, 'Library', 'Application Support'),
        _environment['XDG_CONFIG_HOME'] ?? _path.join(home, '.config'),
      ],
    ];
    return [
      for (final root in roots)
        fileSystem.file(_path.join(root, 'fvm', FvmPaths.fvmrcFileName)),
    ];
  }

  String? _globalPin(Directory cacheDir) {
    final link = fileSystem.link(_path.join(cacheDir.path, 'default'));
    if (!link.existsSync()) return null;
    final String target;
    try {
      target = link.targetSync();
    } on FileSystemException {
      return null;
    }
    final versions = _path.join(cacheDir.path, 'versions');
    final absolute = _path.isAbsolute(target)
        ? target
        : _path.normalize(_path.join(cacheDir.path, target));
    if (!_path.isWithin(versions, absolute)) return null;
    // A fork lives one level deeper, as versions/<fork>/<version>, and is
    // written `<fork>/<version>` in a `.fvmrc`.
    return _path.split(_path.relative(absolute, from: versions)).join('/');
  }

  List<String> _cachedVersions(Directory cacheDir) {
    final versions =
        fileSystem.directory(_path.join(cacheDir.path, 'versions'));
    if (!versions.existsSync()) return const [];
    return [
      for (final entity in versions.listSync())
        if (entity is Directory) _path.basename(entity.path),
    ]..sort();
  }

  /// The projects in its registry, `<cache>/projects.json`.
  List<Directory> _projects(Directory cacheDir) {
    final registry = _readJson(
      fileSystem.file(_path.join(cacheDir.path, 'projects.json')),
    );
    final projects = registry?['projects'];
    if (projects is! List) return const [];
    return [
      for (final project in projects)
        if (project is String && fileSystem.directory(project).existsSync())
          fileSystem.directory(project),
    ];
  }

  List<OtherFvmInstall> _installs() {
    final home = _home;
    return [
      ..._scriptInstalls(home),
      if (_homebrewInstall() case final install?) install,
      if (_pubInstall(home) case final install?) install,
      if (_chocolateyInstall() case final install?) install,
    ];
  }

  List<OtherFvmInstall> _scriptInstalls(String? home) {
    const uninstall =
        'curl -fsSL https://fvm.app/install.sh | bash -s -- --uninstall';
    final installs = <OtherFvmInstall>[];

    final configuredBase = _environment['FVM_INSTALL_DIR']?.trim();
    final base = (configuredBase != null && configuredBase.isNotEmpty)
        ? configuredBase
        : (home == null ? null : _path.join(home, 'fvm'));
    if (base != null) {
      final bin = fileSystem.directory(_path.join(base, 'bin'));
      final binary = fileSystem.file(_path.join(bin.path, 'fvm'));
      // Never our own bin directory, however FVM_INSTALL_DIR is set.
      if (binary.existsSync() &&
          !_same(bin.path, paths.binDir.path) &&
          !_isOurs(binary.path)) {
        installs.add(OtherFvmInstall(
          source: OtherFvmSource.installScript,
          location: binary.path,
          remove: [bin],
          manualCommand: uninstall,
        ));
      }
    }

    // The first installer's layout, which its current installer also cleans
    // up: everything under ~/.fvm_flutter, plus a /usr/local/bin/fvm symlink.
    if (home != null) {
      final legacy = fileSystem.directory(_path.join(home, '.fvm_flutter'));
      if (legacy.existsSync()) {
        final systemLink = fileSystem.link('/usr/local/bin/fvm');
        final target = _linkTarget(systemLink);
        final linksHere = target != null && _path.isWithin(legacy.path, target);
        installs.add(OtherFvmInstall(
          source: OtherFvmSource.installScript,
          location: legacy.path,
          remove: [legacy, if (linksHere) systemLink],
          manualCommand: uninstall,
        ));
      }
    }
    return installs;
  }

  OtherFvmInstall? _homebrewInstall() {
    if (_isWindows) return null;
    for (final location in const [
      '/opt/homebrew/bin/fvm',
      '/usr/local/bin/fvm',
      '/home/linuxbrew/.linuxbrew/bin/fvm',
    ]) {
      final target = _linkTarget(fileSystem.link(location));
      if (target != null && target.contains('/Cellar/fvm/')) {
        return OtherFvmInstall(
          source: OtherFvmSource.homebrew,
          location: location,
          command: const ['brew', 'uninstall', 'fvm'],
          manualCommand: 'brew uninstall fvm',
        );
      }
    }
    return null;
  }

  OtherFvmInstall? _pubInstall(String? home) {
    final configured = _environment['PUB_CACHE']?.trim();
    final String? pubCache;
    if (configured != null && configured.isNotEmpty) {
      pubCache = configured;
    } else if (_isWindows) {
      final local = _environment['LOCALAPPDATA'];
      pubCache = local == null ? null : _path.join(local, 'Pub', 'Cache');
    } else {
      pubCache = home == null ? null : _path.join(home, '.pub-cache');
    }
    if (pubCache == null) return null;

    final activated = fileSystem
        .directory(_path.join(pubCache, 'global_packages', 'fvm'))
        .existsSync();
    if (!activated) return null;
    return OtherFvmInstall(
      source: OtherFvmSource.pubGlobal,
      location: _path.join(pubCache, 'bin', _isWindows ? 'fvm.bat' : 'fvm'),
      command: const ['dart', 'pub', 'global', 'deactivate', 'fvm'],
      manualCommand: 'dart pub global deactivate fvm',
    );
  }

  OtherFvmInstall? _chocolateyInstall() {
    if (!_isWindows) return null;
    final root =
        _environment['ChocolateyInstall'] ?? r'C:\ProgramData\chocolatey';
    final package = fileSystem.directory(_path.join(root, 'lib', 'fvm'));
    if (!package.existsSync()) return null;
    return OtherFvmInstall(
      source: OtherFvmSource.chocolatey,
      location: package.path,
      // Chocolatey refuses to uninstall from a shell that is not elevated, and
      // fvm must not ask for elevation on its own.
      manualCommand: 'choco uninstall fvm   (from an administrator shell)',
    );
  }

  /// Where [link] points, absolute, or null when it is not a symlink.
  String? _linkTarget(Link link) {
    if (fileSystem.typeSync(link.path, followLinks: false) !=
        FileSystemEntityType.link) {
      return null;
    }
    try {
      final target = link.targetSync();
      return _path.isAbsolute(target)
          ? target
          : _path.normalize(_path.join(_path.dirname(link.path), target));
    } on FileSystemException {
      return null;
    }
  }

  bool _isOurs(String candidate) =>
      executablePath.isNotEmpty && _same(candidate, executablePath);

  bool _same(String a, String b) =>
      _path.equals(_path.normalize(a), _path.normalize(b));

  Map<String, Object?>? _readJson(File file) {
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }
}

/// A pin written by the other fvm, in terms this fvm can act on.
sealed class ForeignPin {
  const ForeignPin(this.original);

  /// Exactly what the other fvm had recorded.
  final String original;

  /// Reads a pin the way the other fvm writes them: a release (`3.19.0`,
  /// optionally `3.19.0@beta`), a channel, `master`/`main`, a fork
  /// (`myfork/3.19.0`), a commit, or a `custom_` SDK.
  static ForeignPin parse(String pin) {
    final trimmed = pin.trim();
    if (trimmed.startsWith('custom_')) {
      return UnsupportedPin(
        trimmed,
        'it is a custom SDK, which only the other fvm knows how to find',
      );
    }
    if (trimmed.contains('/')) {
      return UnsupportedPin(
        trimmed,
        'it is a fork, and fvm installs only official Flutter releases',
      );
    }
    if (trimmed == 'master' || trimmed == 'main') {
      return UnsupportedPin(
        trimmed,
        'Flutter publishes no release archive for the $trimmed branch',
      );
    }
    if (RegExp(r'^[0-9a-f]{7,40}$').hasMatch(trimmed)) {
      return UnsupportedPin(
        trimmed,
        'it is a Git commit, and fvm installs only published releases',
      );
    }

    // `3.19.0@beta` names a release and the channel it came from.
    final at = trimmed.indexOf('@');
    final version = at == -1 ? trimmed : trimmed.substring(0, at);
    final suffix = at == -1 ? null : trimmed.substring(at + 1);

    final channel = Channel.tryParse(version);
    if (channel != null) return ChannelPin(trimmed, channel);

    if (suffix != null && Channel.tryParse(suffix) == null) {
      return UnsupportedPin(
        trimmed,
        '"@$suffix" is not a channel fvm installs from',
      );
    }
    return ReleasePin(
      trimmed,
      version,
      channel: suffix == null ? null : Channel.tryParse(suffix),
    );
  }
}

/// A concrete release.
class ReleasePin extends ForeignPin {
  const ReleasePin(super.original, this.version, {this.channel});

  final String version;

  /// The channel named after `@`, when there was one.
  final Channel? channel;
}

/// `stable`, `beta` or `dev`.
class ChannelPin extends ForeignPin {
  const ChannelPin(super.original, this.channel);

  final Channel channel;
}

/// A pin with no equivalent here.
class UnsupportedPin extends ForeignPin {
  const UnsupportedPin(super.original, this.reason);

  /// Why, as a clause: "it is a fork, and …".
  final String reason;
}
