import 'package:file/file.dart';

/// What an edit to the shell startup file did, or declined to do.
enum PathLineOutcome {
  /// The line was appended to a file that already existed.
  written,

  /// The startup file did not exist, so it was created holding the line.
  created,

  /// The file already puts the shims directory on PATH, so nothing was done.
  alreadyPresent,

  /// The fvm block was found and taken back out.
  removed,

  /// A PATH line is there, but fvm did not write it — no markers around it —
  /// so it was left alone. Kept separate from [alreadyPresent] because the
  /// answer to "why is it still there?" is different, and a hand-written line
  /// is the user's to remove.
  foreign,

  /// There is nothing of fvm's in the file, which is a clean no-op.
  absent,
}

/// The result of one [PathLineEditor] call.
class PathLineResult {
  const PathLineResult({
    required this.outcome,
    this.backup,
    this.line,
  });

  final PathLineOutcome outcome;

  /// Where the untouched copy of the file went, when one was made.
  final File? backup;

  /// The 1-based line number of the PATH line that was already there, for the
  /// outcomes that found one.
  final int? line;
}

/// Recognises a line that puts the shims directory on PATH, however it is
/// spelled.
///
/// Pulled out of [PathLineEditor] because two callers need the same answer and
/// a second spelling of it is the kind of bug that only shows up on somebody
/// else's machine: the editor asks "is the line already in the file I am about
/// to write?", and `doctor` asks "is the line in a file — any file — while the
/// live PATH lacks the directory?". A line recognised by one and missed by the
/// other is exactly how a misfiled line goes unreported.
class ShimsPathLine {
  ShimsPathLine({required this.shimsPath, required this.homePath});

  /// The shims directory, as fvm spells it.
  final String shimsPath;

  /// The user's home, so a hand-written line spelled `$HOME/...` or `~/...`
  /// is recognised as the same line.
  final String? homePath;

  /// Whether [raw] is an instruction putting [shimsPath] on PATH.
  ///
  /// Matched by substring rather than equality: the user may have typed the
  /// same instruction with different quoting, spacing, or `$HOME` in place of
  /// their home directory, and appending a second copy of a line that is
  /// already working is exactly the failure this is here to prevent.
  bool matches(String raw) {
    final text = raw.trim();
    if (text.isEmpty || text.startsWith('#')) return false;
    if (!_needles.any(text.contains)) return false;
    // `export PATH=`, `set -gx PATH`, `fish_add_path` — every spelling of the
    // instruction names PATH, and a line that merely mentions the directory
    // (a comment's worth of prose, a `ls` in a script) does not.
    return text.toLowerCase().contains('path');
  }

  /// The index of the first line in [lines] that [matches], or null.
  int? indexIn(List<String> lines) {
    for (var index = 0; index < lines.length; index++) {
      if (matches(lines[index])) return index;
    }
    return null;
  }

  late final List<String> _needles = _buildNeedles();

  List<String> _buildNeedles() {
    final needles = <String>[shimsPath];
    final home = homePath;
    if (home != null && home.isNotEmpty && shimsPath.startsWith('$home/')) {
      final rest = shimsPath.substring(home.length + 1);
      needles.addAll([r'$HOME/' '$rest', r'${HOME}/' '$rest', '~/$rest']);
    }
    return needles;
  }
}

/// Adds and removes fvm's PATH line in a shell startup file.
///
/// Everything fvm writes goes between [beginMarker] and [endMarker]. That is
/// what makes the edit reversible: without a marker there is no way to tell a
/// line fvm added from one the user typed, and a remover that guesses will
/// eventually delete somebody's own line.
///
/// Reads and writes go through the injected [FileSystem], so a test drives
/// this against a memory filesystem rather than a real `$HOME`.
class PathLineEditor {
  PathLineEditor({
    required this.fileSystem,
    required this.rcFile,
    required this.line,
    required this.shimsPath,
    required this.homePath,
    required DateTime Function() now,
  }) : _now = now;

  final FileSystem fileSystem;

  /// The startup file to edit. It need not exist yet.
  final File rcFile;

  /// The line to add — already spelled for the shell in use.
  final String line;

  /// The shims directory, used to recognise a PATH line that is already there.
  final String shimsPath;

  /// The user's home, so a hand-written line spelled `$HOME/...` or `~/...`
  /// is recognised as the same line.
  final String? homePath;

  final DateTime Function() _now;

  /// How a line that is already there is recognised. Shared with `doctor`, so
  /// that a line one of them sees is a line the other sees too.
  late final ShimsPathLine matcher =
      ShimsPathLine(shimsPath: shimsPath, homePath: homePath);

  static const String beginMarker = '# >>> fvm >>>';
  static const String endMarker = '# <<< fvm <<<';

  /// Adds the PATH line, backing the file up first.
  ///
  /// Idempotent: a second run finds the line — fvm's own or a hand-written one
  /// that differs in spacing or quoting — and does nothing. A doubled PATH
  /// entry is the likeliest bug here and the least likely to be noticed.
  PathLineResult install() {
    final existed = rcFile.existsSync();
    final lines = existed ? _read() : const <String>[];

    if (_findExisting(lines) case final found?) {
      return PathLineResult(
        outcome: PathLineOutcome.alreadyPresent,
        line: found + 1,
      );
    }

    final backup = existed ? _backup() : null;
    final content = existed ? rcFile.readAsStringSync() : '';
    final buffer = StringBuffer(content);
    if (content.isNotEmpty) {
      if (!content.endsWith('\n')) buffer.writeln();
      buffer.writeln();
    }
    buffer
      ..writeln(beginMarker)
      ..writeln(line)
      ..writeln(endMarker);

    rcFile.parent.createSync(recursive: true);
    rcFile.writeAsStringSync(buffer.toString());

    return PathLineResult(
      outcome: existed ? PathLineOutcome.written : PathLineOutcome.created,
      backup: backup,
    );
  }

  /// Takes fvm's block back out, leaving anything the user wrote alone.
  PathLineResult remove() {
    if (!rcFile.existsSync()) {
      return const PathLineResult(outcome: PathLineOutcome.absent);
    }

    final lines = _read();
    final begin = lines.indexWhere((line) => line.trim() == beginMarker);
    final end = begin < 0
        ? -1
        : lines.indexWhere((line) => line.trim() == endMarker, begin + 1);

    if (begin < 0 || end < 0) {
      if (_findExisting(lines) case final found?) {
        return PathLineResult(
          outcome: PathLineOutcome.foreign,
          line: found + 1,
        );
      }
      return const PathLineResult(outcome: PathLineOutcome.absent);
    }

    final backup = _backup();
    final kept = [...lines];
    kept.removeRange(begin, end + 1);
    // The blank line install() puts in front of the block is fvm's too, so
    // adding and removing the line leaves the file as it was found.
    if (begin > 0 && kept[begin - 1].trim().isEmpty) {
      kept.removeAt(begin - 1);
    }

    rcFile.writeAsStringSync(kept.isEmpty ? '' : '${kept.join('\n')}\n');
    return PathLineResult(outcome: PathLineOutcome.removed, backup: backup);
  }

  List<String> _read() => rcFile.readAsLinesSync();

  /// Copies the file next to itself before touching it.
  ///
  /// The timestamp is in the name rather than a fixed `.bak`, so a second edit
  /// cannot overwrite the copy taken before the first one — the copy the user
  /// would want if the first edit is the one that went wrong.
  File _backup() {
    final stamp = _stamp(_now());
    final backup = fileSystem.file('${rcFile.path}.fvm-backup-$stamp');
    backup.writeAsStringSync(rcFile.readAsStringSync());
    return backup;
  }

  static String _stamp(DateTime time) {
    String pad(int value) => value.toString().padLeft(2, '0');
    return '${time.year}${pad(time.month)}${pad(time.day)}'
        '-${pad(time.hour)}${pad(time.minute)}${pad(time.second)}';
  }

  /// The index of a line that already puts the shims directory on PATH, or
  /// null.
  int? _findExisting(List<String> lines) => matcher.indexIn(lines);
}
