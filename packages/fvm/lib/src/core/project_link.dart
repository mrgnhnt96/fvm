import 'dart:io' as io;

import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:path/path.dart' as p;

import 'exceptions.dart';
import 'verbose.dart';

/// Points [link] at [target], replacing whatever link was there before.
///
/// This is `.fvm/flutter_sdk`, the one thing fvm leaves inside a project. It
/// exists so an IDE can be told where the SDK is with a path that does not
/// change when the pin does — VS Code's `flutter.sdkPath` and IntelliJ's Flutter SDK
/// setting are both plain paths, and both reach the SDK through ordinary file
/// APIs, so anything the filesystem resolves transparently will do.
///
/// It lives here rather than inside `fvm use` because creating it is a
/// platform question with a real answer on each platform, and because `use`
/// should read as one line about linking rather than twenty about Windows.
Link linkProjectSdk({
  required Link link,
  required Directory target,
  SdkLinker? linker,
  VerboseLog? verbose,
}) {
  final log = verbose ?? VerboseLog.disabled;
  final fileSystem = link.fileSystem;
  link.parent.createSync(recursive: true);

  // followLinks: false — an existing link whose target was removed still
  // has to be replaced, and following it would report it as missing. A
  // Windows junction is a reparse point, which is reported as a link here
  // too, so a junction from a previous `fvm use` is replaced the same way.
  final existing = fileSystem.typeSync(link.path, followLinks: false);
  if (existing == FileSystemEntityType.link) {
    log.log(
      VerboseArea.fs,
      () => 'replacing the existing link at ${link.path} '
          '(was -> ${link.targetSync()})',
    );
    link.deleteSync();
  } else if (existing != FileSystemEntityType.notFound) {
    // ABSOLUTE, unlike the `.fvm/flutter_sdk` that `fvm use` prints on success.
    // Two reasons, and both are why this is not an oversight: this helper is
    // core, it has no [FvmContext] and therefore no `display`, and the same
    // is true of the `WindowsSdkLinker` failure below — which sits behind a
    // `const` seam with nowhere to inject one. Converting only the half that
    // is reachable would leave fvm printing one path two ways in adjacent
    // failure modes. And a message telling somebody to go and delete a file
    // by hand is the one place a path is worth spelling out in full.
    throw ConfigException(
      '${link.path} already exists and is not a symlink, so fvm will not '
      'replace it. Delete it and run this again.',
    );
  }

  (linker ?? defaultSdkLinker(fileSystem)).create(link, target);
  log.log(VerboseArea.fs, () => 'linked ${link.path} -> ${target.path}');
  return link;
}

/// How [linkProjectSdk] creates the link once the path is clear.
///
/// A seam rather than a bare call so that a test can drive the Windows answer
/// on a machine that is not Windows, and the plain answer on one that is.
abstract class SdkLinker {
  /// Creates a link at [link] resolving to [target].
  void create(Link link, Directory target);
}

/// A plain symbolic link.
///
/// Everything POSIX, and every in-memory filesystem, where a symlink is
/// unprivileged and there is nothing to fall back to.
class SymlinkSdkLinker implements SdkLinker {
  const SymlinkSdkLinker();

  @override
  void create(Link link, Directory target) => link.createSync(target.path);
}

/// A symbolic link where Windows allows one, a directory junction where it
/// does not.
///
/// **Windows does not let an ordinary user create a symlink.** It needs either
/// Developer Mode or an elevated process, and a stock machine has neither — so
/// `Link.createSync` there fails with "A required privilege is not held by the
/// client" and `fvm use`, the command this tool exists for, does not work.
///
/// A junction is the answer because it needs no privilege at all and it is
/// resolved by the filesystem itself, so everything that opens a path through
/// it — an IDE looking for `bin/flutter.bat`, an analyzer walking the SDK — sees
/// exactly what it would see through a symlink. Its limitations are ones this
/// link does not run into: a junction points only at a directory, which is
/// what `.fvm/flutter_sdk` always is, and only on a local volume, which `~/.fvm`
/// is on any machine that can install an SDK into it.
///
/// The symlink is still tried first. A developer with Developer Mode on gets
/// the more general object, and on a machine where both work the two are
/// indistinguishable to everything that reads them.
class WindowsSdkLinker implements SdkLinker {
  const WindowsSdkLinker();

  @override
  void create(Link link, Directory target) {
    final io.FileSystemException symlinkFailure;
    try {
      link.createSync(target.path);
      return;
    } on io.FileSystemException catch (error) {
      symlinkFailure = error;
    }

    final junction = makeJunction(link.path, target.path);
    if (junction != null) {
      throw ConfigException(
        'Could not link ${link.path} to ${target.path}.\n'
        'As a symbolic link: '
        '${symlinkFailure.osError?.message ?? symlinkFailure.message}\n'
        'As a directory junction: $junction\n'
        'Your IDE needs this link to find the SDK; fvm flutter and fvm exec work '
        'without it.',
      );
    }
  }

  /// Creates the junction. Overridden by tests so the fallback can be reached
  /// on a machine that is not Windows.
  String? makeJunction(String link, String target) =>
      createDirectoryJunction(link, target);
}

/// Creates a directory junction at [link] resolving to [target].
///
/// Returns null on success, or a sentence describing the failure.
///
/// `mklink` is a builtin of `cmd.exe` rather than a program, so there is no
/// executable to invoke directly. Shelling out is the same trade
/// `ChmodModeApplier` makes for the executable bit: one subprocess against an
/// FFI dependency and a hand-built `FSCTL_SET_REPARSE_POINT` buffer, for an
/// operation that happens once per `fvm use`.
String? createDirectoryJunction(String link, String target) {
  final io.ProcessResult result;
  try {
    result = io.Process.runSync(
      'cmd.exe',
      <String>['/c', 'mklink', '/J', link, target],
    );
  } on io.ProcessException catch (error) {
    return 'could not run cmd.exe (${error.message})';
  }

  if (result.exitCode == 0) return null;
  // mklink's messages are localised, so the text is passed through rather
  // than matched on.
  final said = '${result.stdout}${result.stderr}'.trim();
  return said.isEmpty ? 'mklink exited ${result.exitCode}' : said;
}

/// The linker to use for [fileSystem].
///
/// The Windows answer runs a real subprocess against real paths, so it is only
/// chosen when the filesystem being written to is the local one — the same
/// reason `ShimWriter` only reaches for `chmod` on a [LocalFileSystem]. A
/// windows-STYLE memory filesystem gets the plain symlink, which is what it can
/// actually do.
SdkLinker defaultSdkLinker(FileSystem fileSystem) =>
    fileSystem is LocalFileSystem && fileSystem.path.style == p.Style.windows
        ? const WindowsSdkLinker()
        : const SymlinkSdkLinker();
