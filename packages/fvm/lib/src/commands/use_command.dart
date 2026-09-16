import 'package:args/command_runner.dart';
import 'package:file/file.dart';

import '../core/context.dart';
import '../core/project_link.dart';
import 'version_ref.dart';

/// `fvm use` — Pin a version for this project and write .fvmrc.
class UseCommand extends Command<int> {
  UseCommand({required this.context}) {
    argParser
      ..addFlag(
        'global',
        abbr: 'g',
        negatable: false,
        help: 'Set the machine-wide default instead of pinning this project.',
      )
      ..addFlag(
        'here',
        negatable: false,
        help: 'Pin this directory itself, creating a .fvmrc here even when a '
            'parent directory already has one.',
      )
      ..addFlag(
        'gitignore',
        negatable: false,
        help: "Also add `$_ignoreRule` to this project's .gitignore.",
      );
  }

  final FvmContext context;

  @override
  String get name => 'use';

  @override
  String get description => 'Pin a version for this project and write .fvmrc.';

  @override
  String get invocation => 'fvm use <version> [--global] [--here]';

  /// What has to be ignored: the symlink is per-machine and points into
  /// `~/.fvm`, so committing it breaks every other checkout.
  static const String _ignoreRule = '.fvm/';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      throw UsageException(
        'Name a version, channel or alias to use.',
        usage,
      );
    }
    if (rest.length > 1) {
      throw UsageException(
        'Use takes one version at a time, but got: ${rest.join(' ')}',
        usage,
      );
    }

    final ref = resolveVersionRef(context, rest.single);
    await ensureInstalled(context, ref);

    if (argResults!.flag('global')) {
      writeGlobal(context, ref);
      return 0;
    }

    // Absolute and normalized, the same spelling `findNearest` walks from, so
    // that every path printed below is one the user can paste.
    final here = context.fileSystem.directory(
      context.fileSystem.path.normalize(context.workingDirectory.absolute.path),
    );

    // The .fvmrc that GOVERNS this directory, found with the resolver's own
    // walk, not a second one written here: `fvm use` has to edit the file that
    // `flutter` will actually read. Writing to the working directory instead —
    // which is what this used to do, deliberately, to keep a monorepo package
    // from rewriting the repository root's pin — creates a second .fvmrc that
    // *shadows* the first, because resolution rule 2 takes the nearest one
    // walking up. The root pin then silently stops applying below, and nothing
    // tells the user. Write and read have to agree, so the write follows the
    // read.
    //
    // The monorepo case that comment was protecting is now `--here`: a package
    // that wants its own SDK asks for a nested pin explicitly, instead of
    // getting one from whichever directory someone happened to be standing in.
    final governing = context.fvmrc.findNearest(here);
    final pinHere = argResults!.flag('here');
    final rcFile = (governing == null || pinHere)
        ? context.paths.fvmrcFile(here)
        : governing;

    // The .fvmrc defines the scope of the pin, so what goes with it lives
    // beside it: both `.fvm/flutter_sdk` and the .gitignore rule belong in the
    // directory holding the pin, not the one the user was standing in. That
    // keeps one .fvmrc to exactly one symlink, updated together however deep
    // `fvm use` was run from — a link dropped in a nested directory has no pin
    // next to it, so the next repin from the root would leave it aimed at the
    // old SDK with nothing to bring it up to date. It is also where `fvm
    // doctor` already looks: it resolves the project as `rcFile.parent` and
    // checks the link there, so `use` was the one command disagreeing.
    final project = rcFile.parent;

    // Computed before the write, or the file just created would be found as
    // its own ancestor.
    final shadowed =
        (governing != null && governing.path != rcFile.path) ? governing : null;

    context.fvmrc.write(rcFile, ref.version);
    final link = _linkProjectSdk(project, ref.version);

    final via = ref.isDirect ? '' : ' (${ref.trail})';
    context.out.writeln(
        'Pinned Flutter ${ref.version} for ${context.display(project.path)}$via.');
    if (project.path != here.path) {
      // `here` IS the working directory, so it is never relative: the line says
      // where the user is standing, and `.` would not.
      context.out.writeln(
        '  You are in ${here.path}, which that pin covers, so the .fvmrc above '
        'it is the one that changed.',
      );
    }
    context.out
      ..writeln('  ${context.display(rcFile.path)} -> commit this')
      ..writeln('  ${context.display(link.path)} -> '
          '${context.display(context.paths.versionDir(ref.version).path)}'
          ' (for your IDE; do not commit it)');
    if (shadowed != null) {
      context.out.writeln(
        '  This pin shadows ${context.display(shadowed.path)}, which no longer '
        'applies in ${context.display(project.path)} or below it.',
      );
    }

    _reportGitignore(project, pinHere: pinHere);
    return 0;
  }

  /// Points `.fvm/flutter_sdk` at the pinned SDK, replacing whatever link was
  /// there before.
  ///
  /// [project] is the directory holding the governing `.fvmrc`, not the working
  /// directory — take it as a parameter rather than reading
  /// `context.workingDirectory` here, or a nested `fvm use` starts leaving
  /// stray links that no later repin can reach.
  ///
  /// The creating is [linkProjectSdk]'s: on Windows a plain symlink needs a
  /// privilege an ordinary account does not have, and the fallback that makes
  /// `fvm use` work there is a paragraph of platform detail that has nothing
  /// to do with pinning a version.
  Link _linkProjectSdk(Directory project, String version) => linkProjectSdk(
        link: context.paths.projectSdkLink(project),
        target: context.paths.versionDir(version),
        verbose: context.verbose,
      );

  /// Says whether `.fvm/` is ignored, and adds it when asked to.
  ///
  /// [project] is the directory holding the `.fvmrc`, which is where the
  /// symlink went, so this reports on the `.gitignore` that actually covers it.
  ///
  /// The rule is only ever appended on an explicit `--gitignore`: editing a
  /// file the user did not name, in a repository fvm does not own, is not
  /// something to do behind their back. There is no prompt because commands
  /// here have no stdin — output sinks are injected precisely so that every
  /// command stays runnable from a test and from CI.
  void _reportGitignore(Directory project, {required bool pinHere}) {
    final gitignore = context.fileSystem.file(
      context.fileSystem.path.join(project.path, '.gitignore'),
    );

    if (_ignoresFvmDir(gitignore)) {
      context.out.writeln('`$_ignoreRule` is already ignored by '
          '${context.display(gitignore.path)}.');
      return;
    }

    if (!argResults!.flag('gitignore')) {
      // Echo `--here` back: without it the suggested command would walk up and
      // pin somewhere other than the run being described.
      final rerun = [
        'fvm use ${argResults!.rest.single}',
        if (pinHere) '--here',
        '--gitignore',
      ].join(' ');
      // Naming the file matters here for the same reason it does above: it
      // sits next to the .fvmrc, which may be well above where the user is.
      context.out.writeln(
        '`$_ignoreRule` is not ignored yet by '
        '${context.display(gitignore.path)}. Add it with: $rerun',
      );
      return;
    }

    final existing = gitignore.existsSync() ? gitignore.readAsStringSync() : '';
    final separator = existing.isEmpty || existing.endsWith('\n') ? '' : '\n';
    gitignore.writeAsStringSync(
      '$existing$separator'
      "# fvm's per-project SDK symlink; .fvmrc is the part you commit.\n"
      '$_ignoreRule\n',
    );
    context.out
        .writeln('Added `$_ignoreRule` to ${context.display(gitignore.path)}.');
  }

  /// Whether [gitignore] already covers the `.fvm` directory.
  ///
  /// Deliberately literal: it recognises the handful of spellings a person
  /// actually writes, and treats anything cleverer as "not ignored", which
  /// costs an unnecessary line rather than an unignored symlink.
  bool _ignoresFvmDir(File gitignore) {
    if (!gitignore.existsSync()) return false;
    const spellings = {
      '.fvm',
      '.fvm/',
      '/.fvm',
      '/.fvm/',
      '.fvm/*',
      '**/.fvm/'
    };
    return gitignore
        .readAsLinesSync()
        .map((line) => line.trim())
        .any(spellings.contains);
  }
}
