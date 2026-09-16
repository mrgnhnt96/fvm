import 'dart:io' as io;

import 'package:archive/archive_io.dart';
import 'package:file/local.dart';
import 'package:file/file.dart';

import 'flutter_archive_exception.dart';

/// Reports extraction progress as `(bytesWritten, bytesTotal)`.
typedef ExtractionProgress = void Function(int completed, int total);

/// Unpacks an SDK zip into a directory.
///
/// A seam rather than a bare function call so that a test can make an extract
/// fail halfway through and assert that nothing was left behind.
abstract class SdkExtractor {
  /// Extracts [archive] into [destination].
  ///
  /// Returns the unix mode recorded in the zip for each extracted path. The
  /// modes are returned rather than applied because applying them is a
  /// platform-specific step the caller may skip entirely — see [ModeApplier].
  ///
  /// [onProgress] is called with `(bytesWritten, bytesTotal)` — UNCOMPRESSED
  /// bytes — once before any entry is written and again after each one. It
  /// exists because extracting a 215MB SDK is the longest stretch of an
  /// install and used to print nothing at all: the download bar reached 100%
  /// and the process then went silent, which reads as a hang precisely
  /// because the user has just been told the work finished.
  Future<Map<String, int>> extract({
    required File archive,
    required Directory destination,
    ExtractionProgress? onProgress,
  });
}

/// Extracts Flutter ZIP and tar.xz bundles using file-backed streams.
class ArchiveSdkExtractor implements SdkExtractor {
  const ArchiveSdkExtractor();

  @override
  Future<Map<String, int>> extract({
    required File archive,
    required Directory destination,
    ExtractionProgress? onProgress,
  }) async {
    final Archive decoded;
    InputFileStream? input;
    File? tarFile;
    try {
      if (archive.fileSystem is LocalFileSystem) {
        var source = archive;
        if (archive.path.endsWith('.tar.xz')) {
          tarFile = archive.fileSystem.file('${archive.path}.tar');
          final compressed = InputFileStream(archive.path);
          final output = OutputFileStream(tarFile.path);
          try {
            XZDecoder().decodeStream(compressed, output,
                verify: true, throwOnError: true);
          } finally {
            compressed.closeSync();
            output.closeSync();
          }
          source = tarFile;
        }
        input = InputFileStream(source.path);
        decoded = tarFile != null
            ? TarDecoder().decodeStream(input)
            : ZipDecoder().decodeStream(input);
      } else {
        final bytes = archive.readAsBytesSync();
        decoded = archive.path.endsWith('.tar.xz')
            ? TarDecoder().decodeBytes(XZDecoder()
                .decodeBytes(bytes, verify: true, throwOnError: true))
            : ZipDecoder().decodeBytes(bytes);
      }
    } on Object catch (error) {
      input?.closeSync();
      if (tarFile?.existsSync() ?? false) tarFile!.deleteSync();
      throw FlutterArchiveException(
        'Could not unpack ${archive.basename}: $error',
      );
    }

    destination.createSync(recursive: true);
    final modes = <String, int>{};

    // Report uncompressed bytes as entries are written.
    var written = 0;
    final total = _uncompressedBytes(decoded, destination);
    onProgress?.call(0, total);

    try {
      final links = <String, String>{};
      for (final entry in decoded) {
        final target = _safeJoin(destination, entry.name);
        // A zip entry naming `../` outside the destination is how an archive
        // escapes the directory it is supposed to be unpacked into. Skip it
        // rather than trusting the archive's own paths.
        if (target == null) continue;

        if (entry.isSymbolicLink) {
          final context = destination.fileSystem.path;
          final link = entry.symbolicLink!;
          final resolved =
              context.normalize(context.join(context.dirname(target), link));
          if (context.isAbsolute(link) ||
              !context.isWithin(destination.path, resolved)) {
            throw const FlutterArchiveException(
                'Archive contains an escaping symbolic link.');
          }
          links[target] = link;
          written += entry.size;
          onProgress?.call(written, total);
          continue;
        }
        if (entry.isDirectory) {
          destination.fileSystem.directory(target).createSync(recursive: true);
          continue;
        }

        final file = destination.fileSystem.file(target);
        file.parent.createSync(recursive: true);
        if (archive.fileSystem is LocalFileSystem) {
          final output = OutputFileStream(file.path);
          try {
            entry.writeContent(output);
          } finally {
            output.closeSync();
          }
        } else {
          file.writeAsBytesSync(entry.readBytes() ?? const <int>[]);
        }
        modes[target] = entry.mode;

        written += entry.size;
        onProgress?.call(written, total);
      }

      // Write links last so no archive entry can write through an earlier link.
      for (final link in links.entries) {
        final target = destination.fileSystem.link(link.key);
        target.parent.createSync(recursive: true);
        target.createSync(link.value);
      }
      return modes;
    } finally {
      input?.closeSync();
      if (tarFile?.existsSync() ?? false) tarFile!.deleteSync();
    }
  }

  /// How many uncompressed bytes this extraction will actually write.
  ///
  /// Skipped entries are excluded by running the same [_safeJoin] check the
  /// loop does, so a zip carrying escaping entries cannot leave the bar stuck
  /// short of 100%. Purely lexical and over ~1000 entries, so it costs nothing
  /// next to the extraction it is measuring.
  int _uncompressedBytes(Archive decoded, Directory destination) {
    var total = 0;
    for (final entry in decoded) {
      if (entry.isDirectory) continue;
      if (_safeJoin(destination, entry.name) == null) continue;
      total += entry.size;
    }
    return total;
  }

  /// [name] resolved inside [destination], or null if it escapes it.
  String? _safeJoin(Directory destination, String name) {
    final context = destination.fileSystem.path;
    final root = context.canonicalize(destination.path);
    final target = context.canonicalize(
      context.join(destination.path, context.normalize(name)),
    );
    if (target == root || !context.isWithin(root, target)) return null;
    return target;
  }
}

/// Applies the unix modes an SDK zip carries.
///
/// `package:archive` records `ArchiveFile.mode` but the `Archive`-based
/// extraction helpers never apply it, so without this pass everything under
/// `bin/` lands non-executable and the installed SDK is inert.
abstract class ModeApplier {
  Future<void> apply(Map<String, int> modeByPath);
}

/// Applies modes by shelling out to `chmod`.
///
/// Dart exposes no `chmod`, so a subprocess is the only route that does not
/// pull in an FFI dependency. Paths are grouped by mode and passed in batches:
/// an SDK is a few thousand files but only a couple of distinct modes, so this
/// is two or three `chmod` calls rather than thousands.
class ChmodModeApplier implements ModeApplier {
  const ChmodModeApplier();

  /// How many paths to hand a single `chmod`, well under any ARG_MAX.
  static const int _batchSize = 500;

  @override
  Future<void> apply(Map<String, int> modeByPath) async {
    // Windows has no unix modes and no chmod; the zip's mode bits mean nothing
    // there and executability comes from the file extension instead.
    if (io.Platform.isWindows) return;

    final byMode = <int, List<String>>{};
    for (final entry in modeByPath.entries) {
      // Only the permission bits; the high bits are the file type.
      final permissions = entry.value & 0xFFF;
      if (permissions == 0) continue;
      byMode.putIfAbsent(permissions, () => <String>[]).add(entry.key);
    }

    for (final entry in byMode.entries) {
      final mode = entry.value.isEmpty
          ? null
          : entry.key.toRadixString(8).padLeft(3, '0');
      if (mode == null) continue;
      for (var i = 0; i < entry.value.length; i += _batchSize) {
        final batch = entry.value.sublist(
          i,
          (i + _batchSize).clamp(0, entry.value.length),
        );
        final result = await io.Process.run('chmod', [mode, ...batch]);
        if (result.exitCode != 0) {
          throw FlutterArchiveException(
            'Could not set permissions on the extracted SDK: '
            '${result.stderr}',
          );
        }
      }
    }
  }
}

/// A [ModeApplier] that does nothing, for hosts and tests without a real
/// filesystem underneath.
class NoopModeApplier implements ModeApplier {
  const NoopModeApplier();

  @override
  Future<void> apply(Map<String, int> modeByPath) async {}
}

/// The directory inside [extracted] that is actually the SDK root.
///
/// The published zips wrap everything in a single top-level `flutter-sdk/`, so
/// renaming the extraction directory itself into `versions/<version>` would
/// give `versions/3.13.2/flutter-sdk/bin/flutter`. Finding `bin/` instead of
/// hardcoding the wrapper's name keeps this working if it is ever dropped.
Directory sdkRootWithin(Directory extracted, String flutterExecutableName) {
  // The CANDIDATE's own path context, not the top-level `p`. The latter is
  // whatever style the host runs, and this function is handed a directory that
  // may belong to an injected filesystem with a style of its own. Joining with
  // the host's separator produced the literal filename `bin\flutter` on a
  // posix-style filesystem when the suite first ran on Windows, and every
  // install in the suite failed with "no bin/flutter was found in it".
  bool looksLikeSdk(Directory candidate) => candidate.fileSystem
      .file(candidate.fileSystem.path.join(
        candidate.path,
        'bin',
        flutterExecutableName,
      ))
      .existsSync();

  if (looksLikeSdk(extracted)) return extracted;

  final children = extracted.listSync().whereType<Directory>();
  for (final child in children) {
    if (looksLikeSdk(child)) return child;
  }

  throw FlutterArchiveException(
    'The downloaded archive does not contain a Flutter SDK: no '
    'bin/$flutterExecutableName was found in it.',
  );
}
