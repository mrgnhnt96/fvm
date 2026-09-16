import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:path/path.dart' as p;

import '../archive/sdk_extractor.dart';
import 'exceptions.dart';
import 'paths.dart';
import 'verbose.dart';

/// Writes and reads `~/.fvm/shims/flutter`.
///
/// The shim is the whole PATH integration: two lines of shell that `exec` into
/// `fvm exec flutter`, so the only cost per `flutter` invocation is a shell start
/// plus fvm's own. `exec` matters — without it the shell stays alive as a
/// parent for the entire life of every Flutter process on the machine.
///
/// The path to the fvm binary is baked in at write time rather than looked up
/// on PATH, because the shim's whole job is to run *before* PATH resolution is
/// trustworthy: a shim that said `exec fvm exec flutter` would find whatever `fvm`
/// the user's shell resolves — which, on a machine carrying the older
/// shell-based version manager, is a shell function that knows nothing about this tool.
class ShimWriter {
  ShimWriter({
    required this.fileSystem,
    required this.paths,
    ModeApplier? modes,
    VerboseLog? verbose,
  })  : _modes = modes ?? _defaultModes(fileSystem),
        _verbose = verbose ?? VerboseLog.disabled;

  final FileSystem fileSystem;
  final FvmPaths paths;
  final ModeApplier _modes;
  final VerboseLog _verbose;

  /// `0755` — readable and executable by everyone, writable by the owner.
  ///
  /// Flutter has no octal literals; this is the same number `chmod 755` sets.
  static const int shimMode = 0x1ED;

  /// Creates the shims directory and writes every shim for this platform.
  ///
  /// [fvmExecutable] must be the absolute path of the fvm binary — normally
  /// `Platform.resolvedExecutable`, resolved by the caller so that a fvm that
  /// was moved or reinstalled elsewhere writes a shim naming where it actually
  /// is.
  ///
  /// Returns the file it wrote.
  Future<File> write(String fvmExecutable) async {
    _validateTarget(fvmExecutable);

    final shim = paths.flutterShim;
    shim.parent.createSync(recursive: true);
    final contents = body(fvmExecutable);
    shim.writeAsStringSync(contents);
    _verbose.logAll(
      VerboseArea.fs,
      () => [
        'wrote ${shim.path}',
        for (final line in contents.trimRight().split(RegExp(r'\r?\n')))
          '  | $line',
      ],
    );

    // Windows has no mode bits: a `.bat` is executable because of its
    // extension, and there is no chmod to call.
    if (!_isWindows) {
      await _modes.apply({shim.path: shimMode});
      _verbose.log(
        VerboseArea.fs,
        () => '  chmod 0${shimMode.toRadixString(8)} ${shim.path}',
      );
    }
    return shim;
  }

  /// The contents of the shim naming [fvmExecutable].
  ///
  /// `"$@"` / `%*` forward the arguments with their word boundaries intact —
  /// unquoted, `dart run tool/x.dart --name "two words"` would arrive as four
  /// arguments.
  String body(String fvmExecutable) {
    if (_isWindows) {
      // No `exec` on cmd; the batch file's exit code is the last command's,
      // which is fvm's, which is the SDK's.
      return '@echo off\r\n"$fvmExecutable" exec flutter %*\r\n';
    }
    return '#!/bin/sh\nexec "$fvmExecutable" exec flutter "\$@"\n';
  }

  /// The fvm binary a shim at [file] names, or null when the file is not a
  /// shim this writer produced.
  ///
  /// Null is deliberately ambiguous between "not ours" and "hand-edited beyond
  /// recognition", because the remedy for both is the same: run `fvm setup`
  /// again. It is never returned for a file that could not be read — that
  /// throws, so a caller cannot mistake a permission error for a verdict.
  String? targetOf(File file) {
    final contents = file.readAsStringSync();
    final match = _targetPattern.firstMatch(contents);
    return match?.group(1);
  }

  /// The quoted path in `exec "<path>" exec flutter` and its `.bat` equivalent.
  ///
  /// Anchored on the `exec flutter` that follows it, so a shim carrying a comment
  /// or a `set -e` above the exec line still parses.
  static final RegExp _targetPattern =
      RegExp(r'"([^"\n]+)"\s+exec\s+flutter\b');

  /// Rejects a target that cannot survive being written into a shell script.
  void _validateTarget(String fvmExecutable) {
    if (fvmExecutable.trim().isEmpty) {
      throw const ConfigException(
        'fvm does not know where its own binary is, so it cannot write a shim '
        'that runs it.',
      );
    }
    // The path is written inside double quotes. A path containing one would
    // end the quoting and turn the rest of the path into arguments — a shim
    // that runs something other than fvm is worse than no shim at all.
    if (fvmExecutable.contains('"') || fvmExecutable.contains('\n')) {
      throw ConfigException(
        'The path to the fvm binary contains a quote or a newline '
        '($fvmExecutable), which cannot be written into a shell script '
        'safely. Move fvm somewhere with a plainer path and run fvm setup '
        'again.',
      );
    }
    if (!fileSystem.path.isAbsolute(fvmExecutable)) {
      throw ConfigException(
        'The path to the fvm binary must be absolute, but it is '
        '"$fvmExecutable". A relative path in a shim resolves against '
        "whatever directory the user happens to be in when they type 'flutter'.",
      );
    }
  }

  bool get _isWindows => fileSystem.path.style == p.Style.windows;

  /// chmod is an operation on the *real* filesystem.
  ///
  /// Running it against a path that came from a `MemoryFileSystem` would not
  /// fail harmlessly: `/etc/hosts` exists in a memory filesystem and on the
  /// machine, and the second one is the one chmod would find. So the real
  /// applier is used only when the filesystem being written to is the local
  /// one, which is also what keeps `fvm setup` testable end to end.
  static ModeApplier _defaultModes(FileSystem fileSystem) =>
      fileSystem is LocalFileSystem
          ? const ChmodModeApplier()
          : const NoopModeApplier();
}
