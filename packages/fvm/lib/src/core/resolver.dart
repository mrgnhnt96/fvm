import 'package:file/file.dart';
import 'package:path/path.dart' as p;

import 'channel.dart';
import 'config.dart';
import 'exceptions.dart';
import 'paths.dart';
import 'verbose.dart';

/// Which of the five resolution rules produced an SDK.
///
/// `which` and `current` report this, so the numbering here is the numbering in
/// ARCHITECTURE.md and in the user-facing output. Rule 5 is the failure case
/// and has no member: it throws [ResolutionException].
enum ResolutionRule {
  /// 1. `FVM_FLUTTER_VERSION` in the environment.
  environmentVariable('FVM_FLUTTER_VERSION'),

  /// 2. The nearest `.fvmrc`, walking up from the working directory.
  fvmrc('.fvmrc'),

  /// 3. `global` in `~/.fvm/config.json`.
  globalDefault('global default'),

  /// 4. The next `flutter` on PATH that is not a fvm shim.
  pathFallback('flutter on PATH');

  const ResolutionRule(this.label);

  /// A short human name for `which` output.
  final String label;
}

/// An SDK, and the reason it is the one that got picked.
class ResolvedSdk {
  const ResolvedSdk({
    required this.rule,
    required this.sdkDir,
    required this.executable,
    this.version,
    this.requested,
    this.source,
  });

  /// Which rule matched.
  final ResolutionRule rule;

  /// The SDK root — the directory containing `bin/`, `lib/` and `version`.
  final Directory sdkDir;

  /// The `flutter` binary inside [sdkDir].
  final File executable;

  /// The concrete version, or null under [ResolutionRule.pathFallback], where
  /// the SDK is not fvm-managed and its version is whatever it happens to be.
  final String? version;

  /// The pin exactly as written, before aliases and channels were resolved.
  /// Null when no pin was involved.
  final String? requested;

  /// Where the answer came from: the `.fvmrc` path that matched, the PATH
  /// entry that supplied the binary, the config file, or the env var name.
  final String? source;

  /// Whether this SDK lives in `~/.fvm/versions`.
  bool get isManaged => rule != ResolutionRule.pathFallback;

  /// One line explaining the choice, for `which` and `doctor`.
  String describe() {
    final buffer = StringBuffer('${rule.label}: ');
    buffer.write(sdkDir.path);
    if (version != null) buffer.write(' (Flutter $version)');
    if (requested != null && requested != version) {
      buffer.write(' via "$requested"');
    }
    if (source != null) buffer.write(' from $source');
    return buffer.toString();
  }
}

/// Resolves which Flutter SDK applies right now.
///
/// This is the hot path: the PATH shim runs it on every single `flutter`
/// invocation on the machine. It performs **zero network I/O** — channel names
/// are looked up in the config, where `fvm install` recorded them, and are
/// never re-resolved against the archive here. Nothing in this file's import
/// graph can reach an HTTP client, and a test asserts that.
class VersionResolver {
  VersionResolver({
    required this.fileSystem,
    required this.paths,
    required this.config,
    required this.fvmrc,
    required Map<String, String> environment,
    VerboseLog? verbose,
  })  : _environment = environment,
        _verbose = verbose ?? VerboseLog.disabled;

  final FileSystem fileSystem;
  final FvmPaths paths;
  final ConfigStore config;
  final FvmrcStore fvmrc;
  final Map<String, String> _environment;

  /// Where the walk explains itself. Off unless the user asked, and every
  /// message is built lazily: this runs on every `flutter` on the machine.
  final VerboseLog _verbose;

  /// The CI / one-off escape hatch, checked before anything on disk.
  static const String versionVariable = 'FVM_FLUTTER_VERSION';

  /// How many alias hops to follow before giving up.
  ///
  /// Aliases normally point straight at a version, but nothing stops a user
  /// pointing one at another alias — or, by accident, at itself.
  static const int _maxAliasHops = 8;

  /// Applies the five-step resolution order, first match wins.
  ///
  /// [from] is the directory `.fvmrc` lookup walks up from — the working
  /// directory of the command being run, not necessarily fvm's own.
  ResolvedSdk resolve({required Directory from}) {
    _verbose.log(
      VerboseArea.resolve,
      () => 'resolving a Flutter SDK for ${from.path}',
    );

    // Read the config at most once per resolution: the hot path should not
    // stat config.json more than it has to, and rules 1-3 may all need it.
    final settings = _LazyConfig(config);

    // 1. The environment variable.
    final fromEnvironment = _environment[versionVariable]?.trim();
    if (fromEnvironment != null && fromEnvironment.isNotEmpty) {
      _verbose.log(
        VerboseArea.resolve,
        () => 'rule 1 ($versionVariable): matched "$fromEnvironment"',
      );
      return _fromPin(
        fromEnvironment,
        rule: ResolutionRule.environmentVariable,
        source: versionVariable,
        settings: settings,
      );
    }
    _verbose.log(
      VerboseArea.resolve,
      () => 'rule 1 ($versionVariable): not set',
    );

    // 2. The nearest .fvmrc.
    final rcFile = fvmrc.findNearest(from);
    if (rcFile != null) {
      // A malformed .fvmrc throws out of here rather than falling through to
      // the global default. A user who typo'd their pin has to be told.
      final pin = fvmrc.read(rcFile);
      if (pin != null) {
        _verbose.log(
          VerboseArea.resolve,
          () => 'rule 2 (.fvmrc): ${rcFile.path} pins "$pin"',
        );
        return _fromPin(
          pin,
          rule: ResolutionRule.fvmrc,
          source: rcFile.path,
          settings: settings,
        );
      }
    }
    _verbose.log(VerboseArea.resolve, () => 'rule 2 (.fvmrc): no pin applies');

    // 3. The global default.
    final global = settings.value.global;
    if (global != null && global.isNotEmpty) {
      _verbose.log(
        VerboseArea.resolve,
        () => 'rule 3 (global default): ${paths.configFile.path} '
            'says "$global"',
      );
      return _fromPin(
        global,
        rule: ResolutionRule.globalDefault,
        source: paths.configFile.path,
        settings: settings,
      );
    }
    _verbose.log(
      VerboseArea.resolve,
      () => 'rule 3 (global default): no "global" in '
          '${paths.configFile.path}',
    );

    // 4. The next real flutter on PATH.
    final onPath = findFlutterOnPath();
    if (onPath != null) {
      _verbose.log(
        VerboseArea.resolve,
        () => 'rule 4 (flutter on PATH): chose ${onPath.executable.path} '
            'from ${onPath.source}',
      );
      return onPath;
    }

    // 5. Nothing applies.
    _verbose.log(
      VerboseArea.resolve,
      () => 'rule 5: nothing applies; giving up',
    );
    throw ResolutionException(_nothingAppliesMessage(from));
  }

  /// Turns a pin — a version, an alias or a channel — into an installed SDK.
  ResolvedSdk _fromPin(
    String pin, {
    required ResolutionRule rule,
    required String source,
    required _LazyConfig settings,
  }) {
    final version = _toConcreteVersion(pin, settings, source);
    final sdkDir = paths.versionDir(version);
    final executable = paths.flutterExecutable(sdkDir);

    if (!sdkDir.existsSync()) {
      throw SdkNotInstalledException(
        'Flutter $version is ${_pinPhrase(pin, version)} by $source, but it is '
        'not installed. Run: fvm install $version',
        version: version,
        source: source,
      );
    }
    if (!executable.existsSync()) {
      // An interrupted install should never leave a directory behind that
      // merely looks installed, but if one does, say so rather than exec'ing
      // a path that does not exist.
      throw SdkNotInstalledException(
        'Flutter $version is installed at ${sdkDir.path} but has no flutter '
        'executable at ${executable.path}. Reinstall it: '
        'fvm remove $version && fvm install $version',
        version: version,
        source: source,
      );
    }

    final resolved = ResolvedSdk(
      rule: rule,
      sdkDir: sdkDir,
      executable: executable,
      version: version,
      requested: pin,
      source: source,
    );
    _verbose.log(
      VerboseArea.resolve,
      () => 'selected ${resolved.sdkDir.path} '
          '(${resolved.executable.path}) — ${resolved.describe()}',
    );
    return resolved;
  }

  String _pinPhrase(String pin, String version) =>
      pin == version ? 'pinned' : 'pinned (as "$pin")';

  /// Follows aliases and channels down to a concrete version.
  String _toConcreteVersion(String pin, _LazyConfig settings, String source) {
    var current = pin;
    final seen = <String>{};
    // Every name walked through, so the log can show the whole trail rather
    // than only its two ends. Built even when the log is off — it is at most
    // [_maxAliasHops] short strings and the loop needs the same information
    // to detect a cycle.
    final trail = <String>[pin];

    for (var hop = 0; hop < _maxAliasHops; hop++) {
      if (!seen.add(current)) {
        throw ConfigException(
          'The alias "$current" in ${paths.configFile.path} points at itself. '
          'Fix it with: fvm alias $current <version>',
        );
      }

      final channel = Channel.tryParse(current);
      if (channel != null) {
        final version = settings.value.versionForChannel(channel);
        if (version != null) {
          if (version != current) trail.add(version);
          _verbose.log(
            VerboseArea.resolve,
            () => '  "$pin" is Flutter $version '
                '(${trail.join(' -> ')}; "${channel.token}" is a channel, '
                'read from ${paths.configFile.path} where install recorded '
                'it — never from the network)',
          );
          return version;
        }
        throw SdkNotInstalledException(
          'The "${channel.token}" channel is requested by $source but no '
          '${channel.token} SDK has been installed, so fvm does not know '
          'which version that is. Run: fvm install ${channel.token}',
          version: channel.token,
          source: source,
        );
      }

      final alias = settings.value.aliases[current];
      // Not an alias and not a channel: it is a concrete version.
      if (alias == null) {
        _verbose.log(
          VerboseArea.resolve,
          () => trail.length == 1
              ? '  "$pin" is already a concrete version'
              : '  "$pin" is Flutter $current (${trail.join(' -> ')}, '
                  'through aliases in ${paths.configFile.path})',
        );
        return current;
      }
      current = alias;
      trail.add(alias);
    }

    throw ConfigException(
      'The alias "$pin" in ${paths.configFile.path} goes through more than '
      '$_maxAliasHops aliases without reaching a version. Point it straight '
      'at one: fvm alias $pin <version>',
    );
  }

  /// Rule 4: the next `flutter` on PATH that is not one of fvm's own shims.
  ///
  /// Skipping the shims is not cosmetic. The shim *is* `~/.fvm/shims/flutter`, the
  /// user is told to put that directory first on PATH, and the shim's body is
  /// `exec fvm exec flutter "$@"`. A scan that accepts the first `flutter` it finds
  /// therefore finds the shim, runs it, and re-enters this same function —
  /// forking until the machine gives up. Every `continue` below is one way that
  /// loop gets in.
  ///
  /// Public so `doctor` can report what rule 4 would pick.
  ResolvedSdk? findFlutterOnPath() {
    final rawPath = _environment['PATH'] ?? _environment['Path'];
    if (rawPath == null || rawPath.isEmpty) {
      _verbose.log(
        VerboseArea.resolve,
        () => 'rule 4 (flutter on PATH): PATH is empty',
      );
      return null;
    }

    final shims = _canonical(paths.shimsDir.path);
    final separator = _isWindows ? ';' : ':';

    for (final entry in rawPath.split(separator)) {
      final trimmed = entry.trim();
      if (trimmed.isEmpty) continue;

      final directory = fileSystem.directory(trimmed);
      // (a) the shims directory itself, however it happens to be spelled:
      // `~/.fvm/shims`, `$HOME/.fvm/./shims/` and the absolute path are the
      // same directory and all three turn up in real PATHs.
      if (_canonical(directory.path) == shims) {
        _verbose.log(
          VerboseArea.resolve,
          () => '  $trimmed -> skipped, it is the fvm shims directory',
        );
        continue;
      }

      for (final name in paths.pathExecutableNames) {
        final candidate = fileSystem.file(
          fileSystem.path.join(directory.path, name),
        );
        if (!candidate.existsSync()) continue;

        final resolved = _resolveLinks(candidate.path);
        // (b) a symlink pointing into the shims directory — what
        // `ln -s ~/.fvm/shims/flutter ~/.local/bin/flutter` leaves behind.
        if (_canonical(fileSystem.path.dirname(resolved)) == shims) {
          _verbose.log(
            VerboseArea.resolve,
            () => '  ${candidate.path} -> skipped, it links into the shims '
                'directory ($resolved)',
          );
          continue;
        }
        // (c) a *copy* of the shim, which no path comparison can catch.
        if (_looksLikeShim(candidate)) {
          _verbose.log(
            VerboseArea.resolve,
            () => '  ${candidate.path} -> skipped, its contents are a copy '
                'of a fvm shim',
          );
          continue;
        }

        final binDir = fileSystem.path.dirname(resolved);
        final sdkDir = fileSystem.directory(fileSystem.path.dirname(binDir));
        _verbose.log(
          VerboseArea.resolve,
          () => '  ${candidate.path} -> real flutter at $resolved',
        );
        return ResolvedSdk(
          rule: ResolutionRule.pathFallback,
          sdkDir: sdkDir,
          executable: fileSystem.file(resolved),
          source: trimmed,
        );
      }
    }
    _verbose.log(
      VerboseArea.resolve,
      () => 'rule 4 (flutter on PATH): nothing on PATH is a non-shim flutter',
    );
    return null;
  }

  /// Whether [file] is a fvm shim by content rather than by location.
  ///
  /// The shim is two lines of shell. Reading it costs one stat plus at most
  /// half a kilobyte, and only on the rule-4 path, which by definition means
  /// no `.fvmrc` and no global applied. A real `flutter` is a multi-megabyte
  /// binary and is rejected by the length check without ever being read.
  bool _looksLikeShim(File file) {
    try {
      if (file.lengthSync() > 512) return false;
      return _shimMarker.hasMatch(file.readAsStringSync());
    } on Object {
      // Unreadable, or not text. Either way it is not one of our shims.
      return false;
    }
  }

  static final RegExp _shimMarker = RegExp(
    r'\bfvm(\.exe)?"?\s+exec\s+flutter\b',
  );

  String _nothingAppliesMessage(Directory from) {
    return 'No Flutter SDK applies in ${from.path}.\n'
        '  - $versionVariable is not set\n'
        '  - no .fvmrc here or in any parent directory\n'
        '  - no "global" in ${paths.configFile.path}\n'
        '  - no flutter on PATH that is not a fvm shim\n'
        'Pin one for this project:  fvm use <version>\n'
        'Or set a machine default:  fvm global <version>';
  }

  bool get _isWindows => fileSystem.path.style == p.Style.windows;

  /// A comparable spelling of [path]: symlinks followed where possible, then
  /// normalized and absolutized (and case-folded on Windows).
  String _canonical(String path) =>
      fileSystem.path.canonicalize(_resolveLinks(path));

  String _resolveLinks(String path) {
    try {
      return fileSystem.file(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      // Does not exist yet — a fresh machine has no shims directory. The
      // normalized path is still the right thing to compare.
      return path;
    }
  }
}

/// Reads the config on first use and remembers it for one resolution.
class _LazyConfig {
  _LazyConfig(this._store);

  final ConfigStore _store;
  FvmConfig? _value;

  FvmConfig get value => _value ??= _store.read();
}
