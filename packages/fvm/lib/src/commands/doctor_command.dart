import 'package:args/command_runner.dart';
import 'package:file/file.dart';
import 'package:path/path.dart' as p;

import '../core/context.dart';
import '../core/exceptions.dart';
import '../core/path_line.dart';
import '../core/shell.dart';
import '../core/shims.dart';
import '../core/style.dart';
import 'version_ref.dart';

/// How bad a finding is.
///
/// Only [fail] changes the exit code. The split exists so that `doctor` can be
/// run in CI as a gate — `fvm doctor || exit 1` — without a machine that merely
/// still has the old tool's directories lying around failing the build.
enum DoctorSeverity {
  ok('ok  '),
  warn('warn'),
  fail('FAIL');

  const DoctorSeverity(this.label);

  /// A fixed-width marker, so the findings line up in a terminal.
  final String label;

  /// [label] in this severity's colour — the token a reader's eye lands on
  /// when skimming a screen of findings, and the only part of the line that is
  /// coloured. Colouring the summary too would make the whole screen loud,
  /// which is the opposite of skimmable.
  String render(Styles styles) => switch (this) {
        DoctorSeverity.ok => styles.ok(label),
        DoctorSeverity.warn => styles.warn(label),
        DoctorSeverity.fail => styles.fail(label),
      };
}

/// What to do about a finding, split so the part the user has to TYPE can be
/// highlighted apart from the prose leading into it.
///
/// One opaque string would force a heuristic — "colour whatever follows the
/// last colon" — and a heuristic that is wrong once puts an escape sequence
/// into the middle of a sentence. Splitting it where the remedy is WRITTEN
/// costs one argument and cannot be wrong.
class DoctorRemedy {
  /// Prose leading into a command, with an optional note after it.
  const DoctorRemedy(this.lead, String this.command, {this.trail = ''});

  /// A remedy with nothing to type: "Remove the line(s) above, then start a
  /// new shell."
  const DoctorRemedy.prose(this.lead)
      : command = null,
        trail = '';

  /// A bare command — the `export PATH=…` line, which is the whole answer.
  const DoctorRemedy.run(String this.command)
      : lead = '',
        trail = '';

  /// What comes before [command]. Dimmed: it explains, it is not the answer.
  final String lead;

  /// The thing to type. Null when the remedy is prose all the way through.
  final String? command;

  /// A parenthetical after the command — `  (or run: fvm setup)`. Dimmed with
  /// [lead], because a remedy with two highlighted commands has none.
  final String trail;

  /// The remedy as one line, behind [indent].
  ///
  /// [indent] is dimmed together with [lead] rather than separately: they are
  /// adjacent and the same role, and two escape pairs where one will do is
  /// noise to anything reading the raw bytes. With colour off this is exactly
  /// `indent + lead + command + trail`, byte for byte the string this type
  /// replaced.
  String render(Styles styles, {String indent = ''}) =>
      '${styles.detail('$indent$lead')}'
      '${command == null ? '' : styles.command(command!)}'
      '${styles.detail(trail)}';
}

/// One thing `doctor` looked at, and what it found.
class DoctorFinding {
  DoctorFinding({
    required this.severity,
    required this.area,
    required this.summary,
    this.details = const [],
    this.remedy,
  });

  final DoctorSeverity severity;

  /// Which check produced this — `PATH`, `shims`, `config`, `project`.
  final String area;

  /// One line saying what is true.
  final String summary;

  /// Supporting lines: the actual PATH order, the offending rc lines.
  final List<String> details;

  /// What to run or edit. Present on everything that is not [DoctorSeverity.ok].
  final DoctorRemedy? remedy;
}

/// `fvm doctor` — Check PATH order, shim health, symlinks and config validity.
///
/// Every finding names the file it is about and what to do about it. The single
/// most valuable check is the shadowing one: on a machine that carried the
/// older shell-based version manager, `fvm` is a shell *function* sourced from `.zshrc`, and a
/// shell function is resolved before PATH is ever searched — so the newly
/// installed binary is never reached and nothing on screen says why.
class DoctorCommand extends Command<int> {
  DoctorCommand({required this.context});

  final FvmContext context;

  @override
  String get name => 'doctor';

  @override
  String get description =>
      'Check PATH order, shim health, symlinks and config validity.';

  @override
  Future<int> run() async {
    final shell = ShellFacts(
      fileSystem: context.fileSystem,
      environment: context.environment,
    );

    final findings = <DoctorFinding>[
      _checkBuild(),
      ..._checkPath(shell),
      ..._checkShims(),
      ..._checkShell(shell),
      ..._checkConfig(),
      ..._checkProject(),
    ];

    final styles = context.styles;
    context.out.writeln(styles.heading('fvm doctor'));
    for (final finding in findings) {
      context.out.writeln(
        '  ${finding.severity.render(styles)}  '
        '${finding.area}: ${finding.summary}',
      );
      for (final detail in finding.details) {
        // Dimmed as a block: PATH orders, rc-file listings and "every `flutter`
        // fails until this is fixed" are all context for the summary above,
        // and the summary is what has to be findable.
        context.out.writeln(styles.detail('          $detail'));
      }
      if (finding.remedy case final remedy?) {
        context.out.writeln(remedy.render(styles, indent: '          -> '));
      }
    }

    final failures = findings
        .where((finding) => finding.severity == DoctorSeverity.fail)
        .length;
    final warnings = findings
        .where((finding) => finding.severity == DoctorSeverity.warn)
        .length;

    context.out.writeln();
    if (failures == 0 && warnings == 0) {
      context.out.writeln(styles.ok('Everything checks out.'));
      return 0;
    }
    // The verdict, coloured by the worst thing in it: this is the one line
    // somebody who ran `fvm doctor` and looked away is coming back to.
    final tally = '${_count(failures, 'problem')}, '
        '${_count(warnings, 'warning')}.';
    context.out.writeln(
      failures == 0 ? styles.warn(tally) : styles.fail(tally),
    );
    return failures == 0 ? 0 : 1;
  }

  String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

  /// Which fvm is this — a published release, or a checkout?
  ///
  /// FIRST, because this is where someone looks when confused, and "am I even
  /// running the fvm I think I am?" is the question underneath most of the
  /// others. A binary installed from a release and a `flutter run` of a working
  /// tree behave differently — only the first can replace itself — and nothing
  /// else in the report says which one is speaking.
  DoctorFinding _checkBuild() {
    final updater = context.updater;

    return DoctorFinding(
      severity: DoctorSeverity.ok,
      area: 'build',
      summary: updater.isCompiled
          ? 'fvm ${updater.currentVersion}, a published release.'
          : 'fvm ${updater.currentVersion}, running from source rather than '
              'an installed binary.',
    );
  }

  /// Is the shims directory on PATH, and is it ahead of every other `flutter`?
  ///
  /// Membership is not the question. A `flutter` in an earlier entry is found
  /// first and the shim never runs, which looks exactly like fvm doing nothing.
  List<DoctorFinding> _checkPath(ShellFacts shell) {
    final shims = context.paths.shimsDir;
    // The shims directory alone: this check is about whether `flutter` resolves
    // to the shim. Whether `fvm` itself is on PATH is not in question here —
    // doctor is being run, so it plainly is.
    final line = shell.pathLine([shims]);
    final raw = context.environment['PATH'] ?? context.environment['Path'];

    if (raw == null || raw.isEmpty) {
      return [
        DoctorFinding(
          severity: DoctorSeverity.fail,
          area: 'PATH',
          summary: 'PATH is not set in this environment, so nothing can find '
              'the shims.',
          remedy: DoctorRemedy.run(line),
        ),
      ];
    }

    final entries = raw
        .split(_isWindows ? ';' : ':')
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .toList();

    final shimsCanonical = _canonical(shims.path);
    final shimsIndex =
        entries.indexWhere((entry) => _canonical(entry) == shimsCanonical);

    // Every entry that would answer a bare `flutter`, in the order PATH searches
    // them. This is what gets printed: "is it on PATH" is not actionable,
    // "these three come first" is.
    final providers = <int>[
      for (var index = 0; index < entries.length; index++)
        if (index != shimsIndex && _hasFlutter(entries[index])) index,
    ];

    List<String> order() => [
          'PATH order (entries that provide a flutter):',
          if (shimsIndex >= 0)
            '  ${shimsIndex + 1}. ${entries[shimsIndex]}  <- fvm shims',
          for (final index in providers) '  ${index + 1}. ${entries[index]}',
        ];

    if (shimsIndex < 0) {
      return [
        DoctorFinding(
          severity: DoctorSeverity.fail,
          area: 'PATH',
          summary: '${shims.path} is not on PATH, so '
              '`flutter` does not go through fvm.',
          details: order(),
          remedy: DoctorRemedy('${shell.pathLineAction}: ', line),
        ),
      ];
    }

    final ahead = providers.where((index) => index < shimsIndex).toList();
    if (ahead.isNotEmpty) {
      return [
        DoctorFinding(
          severity: DoctorSeverity.fail,
          area: 'PATH',
          summary: '${shims.path} is on PATH but '
              '${ahead.length == 1 ? 'an entry ahead of it provides' : '${ahead.length} entries ahead of it provide'} '
              'a flutter, so the shim is never reached.',
          details: order(),
          remedy: DoctorRemedy('Put the shims first: ', line),
        ),
      ];
    }

    return [
      DoctorFinding(
        severity: DoctorSeverity.ok,
        area: 'PATH',
        summary: '${shims.path} is on PATH ahead of every '
            'other flutter.',
        details: providers.isEmpty ? const [] : order(),
      ),
    ];
  }

  /// Does the shim exist, can it run, and does it still name a real fvm?
  List<DoctorFinding> _checkShims() {
    final shim = context.paths.flutterShim;
    final writer = ShimWriter(
      fileSystem: context.fileSystem,
      paths: context.paths,
    );

    if (!shim.existsSync()) {
      return [
        DoctorFinding(
          severity: DoctorSeverity.fail,
          area: 'shims',
          summary: '${shim.path} does not exist.',
          remedy: const DoctorRemedy('Run: ', 'fvm setup'),
        ),
      ];
    }

    final String? target;
    try {
      target = writer.targetOf(shim);
    } on FileSystemException catch (error) {
      // Could not look. Reporting this as "not a fvm shim" would be inventing
      // a fact out of a failed read.
      return [
        DoctorFinding(
          severity: DoctorSeverity.fail,
          area: 'shims',
          summary: '${shim.path} exists but could not be read '
              '(${error.message}), so fvm cannot say what it runs.',
          remedy: const DoctorRemedy(
            'Check its permissions, then run: ',
            'fvm setup',
          ),
        ),
      ];
    }

    if (target == null) {
      return [
        DoctorFinding(
          severity: DoctorSeverity.fail,
          area: 'shims',
          summary: '${shim.path} is not recognisable as a '
              'fvm shim.',
          remedy: const DoctorRemedy('Overwrite it with: ', 'fvm setup'),
        ),
      ];
    }

    final findings = <DoctorFinding>[];
    if (!context.fileSystem.file(target).existsSync()) {
      findings.add(
        DoctorFinding(
          severity: DoctorSeverity.fail,
          area: 'shims',
          summary: '${shim.path} runs '
              '$target, which no longer exists.',
          details: const [
            'Every `flutter` on this machine fails until this is fixed.',
          ],
          remedy: const DoctorRemedy(
            'Re-point it at the fvm you have now: ',
            'fvm setup',
          ),
        ),
      );
    }

    // Windows executability comes from the extension, and there is no mode to
    // inspect; asking for one would report a false problem on every machine.
    if (!_isWindows && !_isExecutable(shim)) {
      findings.add(
        DoctorFinding(
          severity: DoctorSeverity.fail,
          area: 'shims',
          summary: '${shim.path} is not executable.',
          // Two things to type, so only the first is highlighted: a line
          // with two commands in it has none.
          remedy: DoctorRemedy(
            '',
            'chmod 755 ${shim.path}',
            trail: '  (or run: fvm setup)',
          ),
        ),
      );
    }

    if (findings.isEmpty) {
      findings.add(
        DoctorFinding(
          severity: DoctorSeverity.ok,
          area: 'shims',
          summary: '${shim.path} runs '
              '$target.',
        ),
      );
    }
    return findings;
  }

  /// Is something in the user's shell going to win over the fvm binary?
  List<DoctorFinding> _checkShell(ShellFacts shell) {
    final scan = shell.scanForShadows(
      shimsLine: ShimsPathLine(
        shimsPath: context.paths.shimsDir.path,
        homePath: shell.home?.path,
      ),
    );
    final findings = <DoctorFinding>[];

    findings.addAll(_checkMisfiledPathLine(shell, scan));

    if (scan.shadows.isEmpty) {
      findings.add(
        DoctorFinding(
          severity: DoctorSeverity.ok,
          area: 'shell',
          summary: 'no shell function or alias named `fvm` in your startup '
              'files.',
        ),
      );
    } else {
      findings.add(
        DoctorFinding(
          severity: DoctorSeverity.fail,
          area: 'shell',
          summary: 'your shell defines its own `fvm`, which is resolved before '
              'PATH is searched — so this fvm never runs.',
          details: [
            for (final shadow in scan.shadows)
              '${shadow.describe()}   (${shadow.kind.description})',
          ],
          remedy: const DoctorRemedy.prose(
            'Remove or comment out the line(s) above, then start a new '
            'shell.',
          ),
        ),
      );
    }

    for (final entry in scan.unreadable.entries) {
      findings.add(
        DoctorFinding(
          severity: DoctorSeverity.warn,
          area: 'shell',
          summary: 'could not read ${entry.key} (${entry.value}), so fvm '
              'cannot say whether it defines a conflicting `fvm`.',
          remedy: const DoctorRemedy.prose(
            'Check the file by hand for a `fvm` function or alias.',
          ),
        ),
      );
    }

    return findings;
  }

  /// A startup file that puts the shims on PATH, while the live PATH does not
  /// have them.
  ///
  /// The precise shape of this leaf's bug, and the reason it survived two
  /// rounds of debugging: the line is real, it is in a real file, `setup` found
  /// it and said "there is nothing to add" — and the shell that ran `setup`
  /// never sources that file, so it has never once taken effect. The PATH check
  /// above already FAILs; this is the sentence that says WHY, and names the
  /// file to look at.
  ///
  /// A [DoctorSeverity.warn] rather than a second failure. It explains a
  /// failure that has already been counted, and counting it twice would turn
  /// one problem into "2 problems" on a machine with one.
  ///
  /// Both readings are stated because fvm cannot distinguish them: a line added
  /// moments ago in this same shell is also "in a file, not on PATH". What
  /// makes the second reading the likely one is [ShellFacts.otherShellRcFiles],
  /// which is listed when it is not empty.
  List<DoctorFinding> _checkMisfiledPathLine(ShellFacts shell, ShellScan scan) {
    final shims = context.paths.shimsDir;
    if (scan.pathLines.isEmpty) return const [];
    if (shell.isOnPath(shims)) return const [];

    final others = shell.otherShellRcFiles;
    return [
      DoctorFinding(
        severity: DoctorSeverity.warn,
        area: 'shell',
        summary: '${shims.path} is put on PATH by a startup file, but it is '
            'not on the PATH of this shell — so that line has never taken '
            'effect here.',
        details: [
          for (final line in scan.pathLines) '${line.describe()}: ${line.text}',
          'Either no new shell has been started since it was added, or the '
              'shell you are in does not read that file.',
          for (final other in others)
            '${other.file.path} is here too, so ${other.shell.token} is in '
                'use on this machine — and it reads its own startup files, '
                'not the one above.',
        ],
        remedy: others.isEmpty
            ? const DoctorRemedy.prose(
                'Start a new shell. If it is still missing, the file above '
                'is not one your shell reads — move the line into the one '
                'it does.',
              )
            : const DoctorRemedy(
                'Move the line into the startup file your shell actually '
                    'reads, or re-run: ',
                'SHELL=<your shell> fvm setup --write-path-line',
              ),
      ),
    ];
  }

  /// Is `~/.fvm/config.json` readable, and does its global still exist?
  List<DoctorFinding> _checkConfig() {
    final file = context.paths.configFile;
    if (!file.existsSync()) {
      return [
        DoctorFinding(
          severity: DoctorSeverity.ok,
          area: 'config',
          summary: 'no ${file.path} yet, which is the '
              'normal state before a '
              'global default is set.',
        ),
      ];
    }

    final String? global;
    try {
      global = context.config.read().global;
    } on FvmException catch (error) {
      return [
        DoctorFinding(
          severity: DoctorSeverity.fail,
          area: 'config',
          summary: error.message,
          remedy: DoctorRemedy.prose(
            'Fix ${file.path}, or delete it to start '
            'over.',
          ),
        ),
      ];
    }

    if (global == null) {
      return [
        DoctorFinding(
          severity: DoctorSeverity.ok,
          area: 'config',
          summary: '${file.path} is valid; no global '
              'default is set.',
        ),
      ];
    }

    // A global naming a version that is gone is what `fvm remove --force`
    // leaves behind, and it breaks every directory that has no .fvmrc.
    final VersionRef ref;
    try {
      ref = resolveVersionRef(context, global);
    } on FvmException catch (error) {
      return [
        DoctorFinding(
          severity: DoctorSeverity.fail,
          area: 'config',
          summary: 'the global default "$global" cannot be resolved: '
              '${error.message}',
          remedy: const DoctorRemedy('Set it again: ', 'fvm global <version>'),
        ),
      ];
    }

    if (!_isInstalled(ref.version)) {
      return [
        DoctorFinding(
          severity: DoctorSeverity.fail,
          area: 'config',
          summary: 'the global default is Flutter ${ref.version}'
              '${ref.isDirect ? '' : ' (${ref.trail})'}, which is not '
              'installed.',
          details: [
            'Nothing is at '
                '${context.paths.versionDir(ref.version).path}',
            'Every directory without a .fvmrc fails until this is fixed.',
          ],
          remedy: DoctorRemedy(
            '',
            'fvm install ${ref.version}',
            trail: '  (or: fvm global <version>)',
          ),
        ),
      ];
    }

    return [
      DoctorFinding(
        severity: DoctorSeverity.ok,
        area: 'config',
        summary: '${file.path} is valid; the global '
            'default Flutter '
            '${ref.version} is installed.',
      ),
    ];
  }

  /// Is this project's pin installed, and is its IDE symlink still good?
  List<DoctorFinding> _checkProject() {
    final rcFile = context.fvmrc.findNearest(context.workingDirectory);
    if (rcFile == null) {
      return [
        DoctorFinding(
          severity: DoctorSeverity.ok,
          area: 'project',
          // The working directory itself: absolute by the display rule, and
          // by intent — the line is about where "here" is.
          summary: 'no .fvmrc at or above ${context.workingDirectory.path}, so '
              'the global default applies here.',
        ),
        ..._checkProjectLink(context.workingDirectory, null),
      ];
    }

    final project = rcFile.parent;
    final String pin;
    try {
      pin = context.fvmrc.read(rcFile)!;
    } on FvmException catch (error) {
      return [
        DoctorFinding(
          severity: DoctorSeverity.fail,
          area: 'project',
          summary: error.message,
          remedy: const DoctorRemedy(
            'Rewrite it with: ',
            'fvm use <version>',
          ),
        ),
      ];
    }

    final VersionRef ref;
    try {
      ref = resolveVersionRef(context, pin);
    } on FvmException catch (error) {
      return [
        DoctorFinding(
          severity: DoctorSeverity.fail,
          area: 'project',
          summary: '${context.display(rcFile.path)} pins "$pin", which '
              'cannot be resolved: '
              '${error.message}',
          remedy: const DoctorRemedy(
            'Pin a version that exists: ',
            'fvm use <version>',
          ),
        ),
      ];
    }

    final findings = <DoctorFinding>[];
    if (_isInstalled(ref.version)) {
      findings.add(
        DoctorFinding(
          severity: DoctorSeverity.ok,
          area: 'project',
          summary: '${context.display(rcFile.path)} pins Flutter ${ref.version}'
              '${ref.isDirect ? '' : ' (${ref.trail})'}, which is installed.',
        ),
      );
    } else {
      findings.add(
        DoctorFinding(
          severity: DoctorSeverity.fail,
          area: 'project',
          summary: '${context.display(rcFile.path)} pins Flutter ${ref.version}'
              '${ref.isDirect ? '' : ' (${ref.trail})'}, which is not '
              'installed.',
          remedy: DoctorRemedy.run('fvm install ${ref.version}'),
        ),
      );
    }

    findings.addAll(_checkProjectLink(project, ref.version));
    return findings;
  }

  /// The gitignored `.fvm/flutter_sdk` symlink IDEs are pointed at.
  ///
  /// It is per-machine and never committed, so it long outlives the version it
  /// names: `fvm remove` the pinned SDK and the IDE keeps following a link into
  /// a directory that is not there any more, which shows up as an analyzer that
  /// stopped working for no visible reason.
  List<DoctorFinding> _checkProjectLink(Directory project, String? version) {
    final link = context.paths.projectSdkLink(project);
    final fileSystem = context.fileSystem;

    final type = fileSystem.typeSync(link.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return const [];
    if (type != FileSystemEntityType.link) {
      return [
        DoctorFinding(
          severity: DoctorSeverity.warn,
          area: 'project',
          summary: '${context.display(link.path)} exists but is not a '
              'symlink, so fvm will not '
              'replace it.',
          remedy: const DoctorRemedy(
            'Delete it, then run: ',
            'fvm use <version>',
          ),
        ),
      ];
    }

    final target = link.targetSync();
    // followLinks defaults to true, so this is the question "does what it
    // points at exist?" rather than "does the link exist?".
    if (fileSystem.typeSync(link.path) == FileSystemEntityType.notFound) {
      return [
        DoctorFinding(
          severity: DoctorSeverity.fail,
          area: 'project',
          summary: '${context.display(link.path)} is a stale symlink: it '
              'points at $target, which has been removed.',
          details: const [
            'An IDE following it will report a broken or missing SDK.',
          ],
          remedy: version == null
              ? const DoctorRemedy(
                  'Pin a version here: ',
                  'fvm use <version>',
                )
              : DoctorRemedy('Re-point it: ', 'fvm use $version'),
        ),
      ];
    }

    if (version != null) {
      final expected = context.paths.versionDir(version).path;
      if (!fileSystem.path.equals(target, expected)) {
        return [
          DoctorFinding(
            severity: DoctorSeverity.warn,
            area: 'project',
            summary: '${context.display(link.path)} points at '
                '$target, but this project pins '
                'Flutter $version.',
            details: ['Expected it to point at $expected'],
            remedy: DoctorRemedy('Re-point it: ', 'fvm use $version'),
          ),
        ];
      }
    }

    return [
      DoctorFinding(
        severity: DoctorSeverity.ok,
        area: 'project',
        summary: '${context.display(link.path)} points at '
            '$target.',
      ),
    ];
  }

  /// Whether [version] is present and usable, checked the way resolution
  /// checks it: the directory alone is not enough, an interrupted install
  /// leaves one behind with no `bin/flutter` in it.
  bool _isInstalled(String version) => context.paths
      .flutterExecutable(context.paths.versionDir(version))
      .existsSync();

  /// Whether [file] has any execute bit set.
  ///
  /// Any, not the owner's: a shim installed by a system package or copied
  /// under a different uid is still executable by the person running it.
  bool _isExecutable(File file) {
    try {
      return file.statSync().mode & _anyExecuteBit != 0;
    } on FileSystemException {
      // Could not stat it. The read check above already reported anything
      // that matters here, and a guess would be worse than silence.
      return true;
    }
  }

  /// `0111`.
  static const int _anyExecuteBit = 0x49;

  bool get _isWindows => context.fileSystem.path.style == p.Style.windows;

  /// A comparable spelling of [path], symlinks followed where possible.
  ///
  /// The same normalization the resolver applies when it skips the shims
  /// directory, so `doctor` and resolution agree about which PATH entry is the
  /// shims one — `$HOME/.fvm/shims`, `~/.fvm/./shims/` and the absolute path
  /// all turn up in real PATHs.
  String _canonical(String path) {
    final fileSystem = context.fileSystem;
    try {
      return fileSystem.path
          .canonicalize(fileSystem.file(path).resolveSymbolicLinksSync());
    } on FileSystemException {
      return fileSystem.path.canonicalize(path);
    }
  }

  /// Whether [entry] contains a `flutter` that is not one of fvm's own shims.
  ///
  /// A *copy* of the shim earlier on PATH — what `ln`/`cp` into `~/.local/bin`
  /// leaves behind — still goes through fvm, so counting it as something that
  /// beats the shims would report a problem the user cannot act on. This is the
  /// same content test the resolver uses to avoid re-entering itself.
  bool _hasFlutter(String entry) {
    final fileSystem = context.fileSystem;
    final writer = ShimWriter(fileSystem: fileSystem, paths: context.paths);

    for (final name in context.paths.pathExecutableNames) {
      final candidate = fileSystem.file(fileSystem.path.join(entry, name));
      if (!candidate.existsSync()) continue;
      try {
        // A real flutter is megabytes; the length check keeps this from reading
        // one. An unreadable or binary file is not one of our shims.
        if (candidate.lengthSync() <= 512 &&
            writer.targetOf(candidate) != null) {
          continue;
        }
      } on FileSystemException {
        // Fall through: it exists, so it answers `flutter`.
      }
      return true;
    }
    return false;
  }
}
