import 'package:fvm/fvm.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

/// Every command in ARCHITECTURE.md's command-surface table, plus `update`
/// from its "Distribution" section.
///
/// Other parts of the CLI fill these in one file at a time; if one of them ever
/// has to touch `lib/fvm.dart` to be reachable, this list was wrong.
const List<String> commandSurface = [
  'install',
  'use',
  'list',
  'list-remote',
  'remove',
  'alias',
  'unalias',
  'global',
  'which',
  'flutter',
  'exec',
  'setup',
  'dart',
  'doctor',
  'update',
];

/// The two spellings the table gives as alternatives.
const Map<String, String> commandAliases = {'ls': 'list', 'current': 'which'};

/// The commands that hand every argument to the SDK, `--help` included.
const List<String> passThroughCommands = ['flutter', 'dart', 'exec'];

void main() {
  late MemoryFileSystem fs;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() {
    fs = MemoryFileSystem.test();
    out = StringBuffer();
    err = StringBuffer();
  });

  /// Drives the real entrypoint against a memory filesystem and a fake
  /// environment, so no test can reach the real ~/.fvm.
  Future<int> runFvm(List<String> args) => run(
        args,
        fileSystem: fs,
        environment: {'HOME': '/home/dev'},
        platformVersion: '3.13.2 (stable) (Tue Aug 25 2026) on "macos_arm64"',
        out: out,
        err: err,
      );

  test('run returns a success exit code', () async {
    expect(await runFvm([]), 0);
  });

  test('--help lists every command in the surface', () async {
    expect(await runFvm(['--help']), 0);

    // Anchored to the start of a line: a bare `contains('flutter')` would pass
    // on the word appearing anywhere in the prose.
    for (final command in commandSurface) {
      expect(
        out.toString(),
        matches(RegExp('^\\s+$command\\s', multiLine: true)),
        reason: '`$command` is missing from fvm --help',
      );
    }
  });

  test('every command in the surface is registered', () {
    final runner = FvmCommandRunner(
      FvmContext.wire(
        fileSystem: fs,
        environment: {'HOME': '/home/dev'},
        platformVersion: 'on "macos_arm64"',
        out: out,
        err: err,
      ),
    );

    for (final command in commandSurface) {
      expect(runner.commands, contains(command));
    }
    for (final entry in commandAliases.entries) {
      expect(runner.commands[entry.key]?.name, entry.value);
    }
  });

  test('every command in the surface runs and describes itself', () async {
    final runner = FvmCommandRunner(
      FvmContext.wire(
        fileSystem: fs,
        environment: {'HOME': '/home/dev'},
        platformVersion: 'on "macos_arm64"',
        out: out,
        err: err,
      ),
    );

    var exercised = 0;
    for (final command in commandSurface) {
      // `fvm flutter` and `fvm exec` parse with `ArgParser.allowAnything()`, so
      // `--help` is the child SDK's and never fvm's. Asking the parser which
      // commands own the flag keeps that exception from being a list here
      // that a later pass-through command would have to be added to.
      final registered = runner.commands[command];
      expect(
        registered,
        isNotNull,
        reason: '`$command` is in the surface but was never registered',
      );
      if (!registered!.argParser.options.containsKey('help')) continue;
      out.clear();
      err.clear();

      // Driven through `run`, the real entrypoint, rather than through the
      // command object: registration is not reachability, and this is the
      // path a user's shell actually takes.
      expect(
        await runFvm([command, '--help']),
        0,
        reason: '`fvm $command --help` should exit 0; stderr was: $err',
      );
      // The OUTPUT, not just the exit code: a command that is dispatched to
      // but prints nothing is not wired up, and exits 0 either way.
      expect(
        out.toString(),
        contains('fvm $command'),
        reason: '`fvm $command --help` did not print its own usage',
      );
      exercised++;
    }

    // The predecessor of this test skipped every command it looped over and
    // passed by asserting nothing. A count makes that failure loud instead.
    expect(
      exercised,
      commandSurface.length - passThroughCommands.length,
      reason: 'every command except the pass-through ones should be exercised',
    );
  });

  test('the pass-through commands keep --help for the child SDK', () async {
    final runner = FvmCommandRunner(
      FvmContext.wire(
        fileSystem: fs,
        environment: {'HOME': '/home/dev'},
        platformVersion: 'on "macos_arm64"',
        out: out,
        err: err,
      ),
    );

    for (final command in passThroughCommands) {
      expect(
        runner.commands[command]!.argParser.options.containsKey('help'),
        isFalse,
        reason: '`fvm $command` must forward --help to the SDK, not answer it',
      );
    }
  });

  test('an unknown command is a usage error, not a crash', () async {
    expect(await runFvm(['nope']), usageExitCode);
    expect(err.toString(), contains('Could not find a command named "nope"'));
  });

  test('--version prints the build version', () async {
    expect(await runFvm(['--version']), 0);
    expect(out.toString().trim(), 'fvm ${version()}');
  });

  test('flutter and exec pass their arguments through untouched', () {
    final runner = FvmCommandRunner(
      FvmContext.wire(
        fileSystem: fs,
        environment: {'HOME': '/home/dev'},
        platformVersion: 'on "macos_arm64"',
        out: out,
        err: err,
      ),
    );

    // Without allowAnything(), `--version` here would be parsed as fvm's own
    // flag instead of being handed to the child.
    for (final name in ['flutter', 'dart', 'exec']) {
      final results = runner.commands[name]!.argParser.parse([
        '--version',
        'run',
        '--define=x=1',
      ]);
      expect(results.rest, ['--version', 'run', '--define=x=1']);
    }
  });
}
