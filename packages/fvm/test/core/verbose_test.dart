import 'package:fvm/fvm.dart';
import 'package:test/test.dart';

import '../commands/harness.dart';
import '../exec/support.dart';

/// fvm explaining itself.
///
/// The incident this exists for: `fvm use <version>` appeared to do nothing,
/// because an older `fvm` shell function was shadowing the binary and the real
/// fvm never ran. Nothing in the output could have shown that. So the contract
/// under test is two-sided — a verbose run has to say what it decided and why,
/// and a NON-verbose run has to stay byte-for-byte what it was, on stdout and
/// on stderr both.
void main() {
  late CommandHarness harness;

  setUp(() {
    harness = CommandHarness();
    harness.installVersion('3.9.0');
    harness.fileSystem.file('/project/.fvmrc').writeAsStringSync('3.9.0');
  });

  /// Every verbose line, which is every line carrying the `[fvm …]` prefix.
  List<String> verboseLines(String text) => [
        for (final line in text.split('\n'))
          if (line.startsWith('[fvm ')) line,
      ];

  group('activation', () {
    test('the -v flag turns it on', () async {
      expect(await harness.run(['-v', 'which']), 0);
      expect(verboseLines(harness.errors), isNotEmpty);
    });

    test('the --verbose flag turns it on', () async {
      expect(await harness.run(['--verbose', 'which']), 0);
      expect(verboseLines(harness.errors), isNotEmpty);
    });

    test('FVM_VERBOSE=1 turns it on', () async {
      harness.environment['FVM_VERBOSE'] = '1';

      expect(await harness.run(['which']), 0);
      expect(verboseLines(harness.errors), isNotEmpty);
    });

    test('any other non-empty value turns it on', () async {
      // Whatever somebody reaches for in a CI file. The variable exists for
      // the case where nobody is typing a fvm command line, so it should not
      // also demand they guess the one spelling that works.
      for (final value in ['true', 'yes', 'on', '2']) {
        final each = CommandHarness()..installVersion('3.9.0');
        each.fileSystem.file('/project/.fvmrc').writeAsStringSync('3.9.0');
        each.environment['FVM_VERBOSE'] = value;

        expect(await each.run(['which']), 0);
        expect(
          verboseLines(each.errors),
          isNotEmpty,
          reason: 'FVM_VERBOSE=$value should turn verbose output on',
        );
      }
    });

    test('FVM_VERBOSE=0 does NOT turn it on', () async {
      harness.environment['FVM_VERBOSE'] = '0';

      expect(await harness.run(['which']), 0);
      expect(verboseLines(harness.errors), isEmpty);
    });

    test('FVM_VERBOSE=false does NOT turn it on', () async {
      harness.environment['FVM_VERBOSE'] = 'false';

      expect(await harness.run(['which']), 0);
      expect(verboseLines(harness.errors), isEmpty);
    });

    test('an EMPTY FVM_VERBOSE does NOT turn it on', () async {
      // `export FVM_VERBOSE=` is how a shell profile clears an inherited
      // value, so an empty string has to read as off rather than as set.
      harness.environment['FVM_VERBOSE'] = '';

      expect(await harness.run(['which']), 0);
      expect(verboseLines(harness.errors), isEmpty);
    });

    test('neither flag nor variable: nothing extra at all', () async {
      expect(await harness.run(['which']), 0);
      expect(verboseLines(harness.errors), isEmpty);
    });

    test('--verbose is listed in the top-level help', () async {
      await harness.run(['--help']);

      expect(harness.output, contains('--verbose'));
      expect(harness.output, contains('FVM_VERBOSE'));
    });
  });

  group('it goes to stderr, never stdout', () {
    test('a verbose run leaves stdout byte-for-byte unchanged', () async {
      final quiet = CommandHarness()..installVersion('3.9.0');
      quiet.fileSystem.file('/project/.fvmrc').writeAsStringSync('3.9.0');
      await quiet.run(['which']);

      await harness.run(['--verbose', 'which']);

      // The whole reason verbose is on stderr: `fvm which` is read by
      // scripts, and so is everything behind the PATH shim.
      expect(harness.output, quiet.output);
      expect(harness.output, isNot(contains('[fvm ')));
      expect(verboseLines(harness.errors), isNotEmpty);
    });

    test('a NON-verbose run adds nothing to stdout OR stderr', () async {
      // The other half of "this changes no behaviour": the instrumentation is
      // invisible unless asked for, on both streams.
      expect(await harness.run(['which']), 0);

      expect(harness.output, contains('/fvm/versions/3.9.0/bin/flutter'));
      expect(harness.errors, isEmpty);
    });
  });

  group('version resolution', () {
    test('reports the .fvmrc walk, the file that won, and its contents',
        () async {
      // Two directories below the pin, so the walk has steps to report rather
      // than finding the answer where it started.
      harness.fileSystem.directory('/project/pkg/sub').createSync(
            recursive: true,
          );
      harness.fileSystem.currentDirectory = '/project/pkg/sub';

      expect(await harness.run(['-v', 'which']), 0);
      final lines = verboseLines(harness.errors).join('\n');

      expect(lines, contains('.fvmrc walk starts at /project/pkg/sub'));
      expect(lines, contains('/project/pkg/sub -> none'));
      expect(lines, contains('/project/pkg -> none'));
      expect(lines, contains('/project -> found /project/.fvmrc'));
      // The RAW contents, so a pin that is not what the user thinks it is
      // shows up as what is literally in the file.
      expect(lines, contains('read /project/.fvmrc: 3.9.0'));
      expect(lines, contains('rule 2 (.fvmrc): /project/.fvmrc pins "3.9.0"'));
      expect(lines, contains('selected /fvm/versions/3.9.0'));
    });

    test('reports each rule it tried and did not match', () async {
      expect(await harness.run(['-v', 'which']), 0);
      final lines = verboseLines(harness.errors).join('\n');

      expect(lines, contains('rule 1 (FVM_FLUTTER_VERSION): not set'));
      expect(lines, contains('rule 2 (.fvmrc)'));
    });

    test('reports the alias trail an alias resolved through', () async {
      harness.writeConfig(
        const FvmConfig(aliases: {'work': 'team', 'team': '3.9.0'}),
      );
      harness.fileSystem.file('/project/.fvmrc').writeAsStringSync('work');

      expect(await harness.run(['-v', 'which']), 0);

      expect(
        verboseLines(harness.errors).join('\n'),
        contains('"work" is Flutter 3.9.0 (work -> team -> 3.9.0'),
      );
    });

    test('reports a channel resolving out of config.json, not the network',
        () async {
      harness.writeConfig(const FvmConfig(channels: {'stable': '3.9.0'}));
      harness.fileSystem.file('/project/.fvmrc').writeAsStringSync('stable');

      expect(await harness.run(['-v', 'which']), 0);

      expect(
        verboseLines(harness.errors).join('\n'),
        contains('"stable" is Flutter 3.9.0 (stable -> 3.9.0; "stable" is a '
            'channel'),
      );
    });

    test('reports the global default applying when no .fvmrc does', () async {
      harness.fileSystem.file('/project/.fvmrc').deleteSync();
      harness.writeConfig(const FvmConfig(global: '3.9.0'));

      expect(await harness.run(['-v', 'which']), 0);
      final lines = verboseLines(harness.errors).join('\n');

      expect(lines, contains('rule 2 (.fvmrc): no pin applies'));
      expect(
        lines,
        contains('rule 3 (global default): /fvm/config.json says "3.9.0"'),
      );
    });

    test('reports WHY a flutter on PATH was skipped for being a shim',
        () async {
      // The shape of the original incident: something that looks like `flutter`
      // is found first and is not the one that runs. Rule 4 skips it silently
      // in production; verbose is where that decision becomes visible.
      harness.fileSystem.file('/project/.fvmrc').deleteSync();
      harness.fileSystem.file('/fake/bin/flutter')
        ..createSync(recursive: true)
        ..writeAsStringSync(
            '#!/bin/sh\nexec "/somewhere/fvm" exec flutter "\$@"');
      harness.environment['PATH'] = '/fake/bin';

      // Rule 5: the shim is skipped, so nothing on PATH answers.
      expect(await harness.run(['-v', 'which']), 1);
      final lines = verboseLines(harness.errors).join('\n');

      expect(
        lines,
        contains('/fake/bin/flutter -> skipped, its contents are a copy of a '
            'fvm shim'),
      );
      expect(lines, contains('rule 5: nothing applies'));
    });
  });

  group('the shim / exec path', () {
    late FakeProcessRunner processes;

    setUp(() => processes = FakeProcessRunner());

    test('FVM_VERBOSE says which SDK binary ran and which .fvmrc chose it',
        () async {
      // This is the CI-log case, and the reason FVM_VERBOSE exists at all:
      // `~/.fvm/shims/flutter` is `exec fvm exec flutter "$@"`, so nobody types a
      // fvm command line here and the flag can never be passed.
      harness.environment['FVM_VERBOSE'] = '1';

      expect(
        await runWith(harness, ['exec', 'flutter', '--version'],
            processes: processes),
        0,
      );

      final lines = verboseLines(harness.errors).join('\n');
      expect(lines, contains('running /fvm/versions/3.9.0/bin/flutter'));
      expect(
          lines, contains('chosen by .fvmrc (/project/.fvmrc), Flutter 3.9.0'));
      // And it did not disturb what the child was actually asked to run.
      expect(processes.only.executable, '/fvm/versions/3.9.0/bin/flutter');
      expect(processes.only.arguments, ['--version']);
    });

    test('nothing reaches stdout on the exec path', () async {
      // A tool parsing `flutter --version` gets fvm's stdio handed straight to
      // the child; a single stray line on stdout would break it.
      harness.environment['FVM_VERBOSE'] = '1';

      await runWith(harness, ['exec', 'flutter', '--version'],
          processes: processes);

      expect(harness.output, isEmpty);
      expect(verboseLines(harness.errors), isNotEmpty);
    });

    test('`fvm flutter` explains itself the same way `fvm exec` does',
        () async {
      // The two ways into an SDK must not be able to disagree about how they
      // report themselves — the shim only exercises one of them.
      await runWith(harness, ['-v', 'flutter', '--version'],
          processes: processes);

      expect(
        verboseLines(harness.errors).join('\n'),
        contains('running /fvm/versions/3.9.0/bin/flutter'),
      );
    });

    test('reports the child PATH search that found the command', () async {
      harness.environment['FVM_VERBOSE'] = '1';
      harness.fileSystem.file('/opt/pub/melos')
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\n');
      harness.environment['PATH'] = '/opt/pub';

      await runWith(harness, ['exec', 'melos', 'bootstrap'],
          processes: processes);

      final lines = verboseLines(harness.errors).join('\n');
      expect(
        lines,
        contains('looking for "melos" on the CHILD PATH: '
            '/fvm/versions/3.9.0/bin:/opt/pub'),
      );
      expect(lines, contains('found at /opt/pub/melos'));
    });

    test('an exec run without -v prints nothing on either stream', () async {
      expect(
        await runWith(harness, ['exec', 'flutter', '--version'],
            processes: processes),
        0,
      );

      expect(harness.output, isEmpty);
      expect(harness.errors, isEmpty);
    });
  });

  group('filesystem writes', () {
    test('`use` reports the .fvmrc it wrote and the link it made', () async {
      expect(await harness.run(['-v', 'use', '3.9.0']), 0);
      final lines = verboseLines(harness.errors).join('\n');

      expect(
        lines,
        contains('wrote /project/.fvmrc: {"flutter": "3.9.0"}'),
      );
      expect(
        lines,
        contains('linked /project/.fvm/flutter_sdk -> /fvm/versions/3.9.0'),
      );
    });

    test('a non-verbose `use` still prints only what it always printed',
        () async {
      final quiet = CommandHarness()..installVersion('3.9.0');
      quiet.fileSystem.file('/project/.fvmrc').writeAsStringSync('3.9.0');
      await quiet.run(['use', '3.9.0']);

      await harness.run(['--verbose', 'use', '3.9.0']);

      expect(harness.output, quiet.output);
      expect(quiet.errors, isEmpty);
    });
  });

  group('VerboseLog itself', () {
    test('a message is not built while the log is off', () async {
      // The hot path runs on every `flutter` invocation on the machine, so a
      // silent run must not pay to produce text it discards.
      var built = 0;
      VerboseLog(sink: StringBuffer()).log('resolve', () {
        built++;
        return 'expensive';
      });

      expect(built, 0);
    });

    test('enable() makes it write, and a sinkless log stays off', () {
      final sink = StringBuffer();
      final log = VerboseLog(sink: sink)..enable();
      log.log('resolve', () => 'hello');
      expect(sink.toString(), '[fvm resolve] hello\n');

      // Nowhere to write means nothing can turn it on — the shape every
      // collaborator constructed outside `lib/fvm.dart` gets by default.
      final none = VerboseLog.disabled..enable();
      expect(none.enabled, isFalse);
    });

    test('stopwatch() is null while the log is off', () {
      expect(VerboseLog.disabled.stopwatch(), isNull);
      expect(
          (VerboseLog(sink: StringBuffer())..enable()).stopwatch(), isNotNull);
    });
  });
}
