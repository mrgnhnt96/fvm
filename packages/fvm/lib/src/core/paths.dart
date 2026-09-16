import 'package:file/file.dart';
import 'package:path/path.dart' as p;

import 'exceptions.dart';

/// The `~/.fvm` layout, as a type.
///
/// Nothing else in the CLI may spell these paths by hand: a second spelling of
/// `versions/` is a bug that only shows up on someone else's machine.
class FvmPaths {
  FvmPaths({required this.fileSystem, required Map<String, String> environment})
      : _environment = environment;

  final FileSystem fileSystem;
  final Map<String, String> _environment;

  /// Overrides the fvm home. Set by tests, by CI, and by users who keep their
  /// SDKs on another volume.
  static const String homeVariable = 'FVM_HOME';

  /// The fvm home directory — `$FVM_HOME`, else `~/.fvm`.
  ///
  /// Lazy so that constructing [FvmPaths] never throws: `fvm --help` has to
  /// work on a machine with no `HOME` set.
  late final Directory home = _resolveHome();

  Directory get versionsDir => _child(home, 'versions');
  Directory get shimsDir => _child(home, 'shims');

  /// Where `install.sh` puts the `fvm` binary itself.
  ///
  /// Nothing in the CLI reads this directory — fvm never looks for itself. It
  /// is here so `setup` can ask one question it cannot otherwise answer: is
  /// the binary that is running me at the one location an install puts it, and
  /// therefore a directory worth adding to the user's PATH? See
  /// `_pathDirectories` in `commands/setup_command.dart`.
  Directory get binDir => _child(home, 'bin');
  Directory get cacheDir => _child(home, 'cache');
  File get configFile => fileSystem.file(_join(home.path, 'config.json'));

  /// Where the SDK for [version] is installed. Existence is not implied.
  Directory versionDir(String version) => _child(versionsDir, version);

  /// The `flutter` executable inside an extracted SDK at [sdkDir].
  File flutterExecutable(Directory sdkDir) =>
      fileSystem.file(_join(sdkDir.path, 'bin', flutterExecutableName));

  /// `flutter` everywhere, `flutter.bat` on Windows.
  String get flutterExecutableName => isWindows ? 'flutter.bat' : 'flutter';

  /// The names a real `flutter` can have on PATH, most likely first.
  ///
  /// Windows resolves a bare `flutter` through PATHEXT, so both spellings have to
  /// be probed when scanning PATH by hand.
  List<String> get pathExecutableNames =>
      isWindows ? const ['flutter.bat', 'flutter.exe'] : const ['flutter'];

  /// The shim fvm installs on PATH.
  File get flutterShim => fileSystem
      .file(_join(shimsDir.path, isWindows ? 'flutter.bat' : 'flutter'));

  /// The gitignored per-project directory holding the IDE symlink.
  Directory projectFvmDir(Directory project) => _child(project, '.fvm');

  /// The gitignored per-project symlink to the resolved SDK, for IDEs.
  Link projectSdkLink(Directory project) =>
      fileSystem.link(_join(project.path, '.fvm', 'flutter_sdk'));

  /// The committed pin file for [project].
  File fvmrcFile(Directory project) =>
      fileSystem.file(_join(project.path, fvmrcFileName));

  /// The name of the per-project pin file.
  static const String fvmrcFileName = '.fvmrc';

  /// Whether the paths this resolves are Windows paths.
  ///
  /// The FILESYSTEM's style rather than the host's, because every path
  /// question here is about the filesystem being written to -- which under
  /// test is an injected one that may be styled differently from the machine
  /// running the suite.
  bool get isWindows => fileSystem.path.style == p.Style.windows;

  String _join(String a, [String? b, String? c]) =>
      fileSystem.path.join(a, b, c);

  Directory _child(Directory parent, String name) =>
      fileSystem.directory(_join(parent.path, name));

  Directory _resolveHome() {
    final override = _environment[homeVariable]?.trim();
    if (override != null && override.isNotEmpty) {
      return fileSystem.directory(_absolute(override));
    }

    // USERPROFILE first on Windows, HOME first elsewhere, but accept either:
    // Git Bash and MSYS set HOME on Windows, and some containers set only
    // USERPROFILE.
    final candidates = isWindows
        ? const ['USERPROFILE', 'HOME']
        : const ['HOME', 'USERPROFILE'];
    for (final variable in candidates) {
      final value = _environment[variable]?.trim();
      if (value != null && value.isNotEmpty) {
        return fileSystem.directory(_absolute(_join(value, '.fvm')));
      }
    }

    throw ConfigException(
      'Cannot work out where to keep your SDKs: neither $homeVariable nor '
      '${candidates.join(' nor ')} is set in the environment. '
      'Set $homeVariable to the directory fvm should use.',
    );
  }

  String _absolute(String path) {
    final normalized = fileSystem.path.normalize(path);
    if (fileSystem.path.isAbsolute(normalized)) return normalized;
    return fileSystem.path.normalize(
      _join(fileSystem.currentDirectory.path, normalized),
    );
  }
}
