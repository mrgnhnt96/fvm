@TestOn('!windows')
library;

import 'dart:io';

import 'package:fvm/fvm.dart' as fvm;
import 'package:fvm/fvm.dart';
import 'package:fvm/src/core/runner.dart';
import 'package:file/local.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The half of process forwarding that a fake cannot show.
///
/// Everything here spawns a real child. `Process.start` is where an exit code
/// gets swallowed, an argument gets re-split by a shell, or a signal goes to
/// the wrapper instead of the program the user thinks they are running, and
/// none of those are visible to a test that records the call and returns.
void main() {
  late Directory temp;

  setUp(() {
    // Resolved because macOS hands out /var/folders/... which is a symlink to
    // /private/var, and the child reports the resolved spelling back.
    temp = Directory(
      Directory.systemTemp
          .createTempSync('fvm_exec_')
          .resolveSymbolicLinksSync(),
    );
  });

  tearDown(() => temp.deleteSync(recursive: true));

  /// An executable `/bin/sh` script at [name] under [temp].
  File script(String name, String body) {
    final file = File(p.join(temp.path, name))
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\n$body');
    // package:archive does not carry the executable bit either; this is the
    // same chmod the installer has to do.
    final chmod = Process.runSync('chmod', ['+x', file.path]);
    expect(chmod.exitCode, 0, reason: 'chmod failed: ${chmod.stderr}');
    return file;
  }

  group('exit codes', () {
    test('success propagates', () async {
      expect(
        await const OsProcessRunner().run('/bin/sh', ['-c', 'exit 0']),
        0,
      );
    });

    test('failure propagates unchanged', () async {
      // The one that breaks CI silently if it is wrong: a `dart test` that
      // failed has to still look like a failure from outside fvm.
      for (final code in [1, 3, 42, 127]) {
        expect(
          await const OsProcessRunner().run('/bin/sh', ['-c', 'exit $code']),
          code,
          reason: 'exit $code did not survive the round trip',
        );
      }
    });
  });

  test('arguments reach the child exactly as written', () async {
    final record = p.join(temp.path, 'argv');
    final echo = script('echo.sh', 'printf "%s\\n" "\$@" > "$record"\n');

    const arguments = [
      'a b',
      "it's",
      'say "hi"',
      '--define=x=a b',
      r'$HOME',
      '*',
      '',
    ];
    expect(await const OsProcessRunner().run(echo.path, arguments), 0);

    // No shell sits between fvm and the child, so `$HOME` and `*` arrive as
    // the six characters the user typed rather than expanded.
    expect(File(record).readAsLinesSync(), arguments);
  });

  test('the child sees the SDK first on PATH and knows its version', () async {
    final sdkDir = Directory(p.join(temp.path, 'versions', '3.9.0'));
    final flutter = File(p.join(sdkDir.path, 'bin', 'flutter'))
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\n');
    final record = p.join(temp.path, 'env');
    final probe = script(
      'probe.sh',
      'printf "%s\\n%s\\n" "\$PATH" "\$FVM_FLUTTER_VERSION" > "$record"\n',
    );

    const fileSystem = LocalFileSystem();
    final invocation = SdkInvocation(
      fileSystem: fileSystem,
      sdk: ResolvedSdk(
        rule: ResolutionRule.fvmrc,
        sdkDir: fileSystem.directory(sdkDir.path),
        executable: fileSystem.file(flutter.path),
        version: '3.9.0',
      ),
      environment: Platform.environment,
    );

    expect(
      await const OsProcessRunner()
          .run(probe.path, const [], environment: invocation.environment),
      0,
    );

    final lines = File(record).readAsLinesSync();
    expect(lines.first.split(':').first, p.join(sdkDir.path, 'bin'));
    // The rest of the parent's PATH is still there: a child handed only the
    // SDK could not find `git`, `sh`, or anything else it needs.
    expect(lines.first, contains(Platform.environment['PATH']!));
    expect(lines[1], '3.9.0');
  });

  test('`fvm flutter` runs the pinned SDK, end to end', () async {
    // No fakes below this line except the SDK itself: the real entrypoint, the
    // real filesystem, the real resolver, the real process runner.
    final home = Directory(p.join(temp.path, 'fvm'));
    final sdkBin = Directory(p.join(home.path, 'versions', '3.9.0', 'bin'));
    final record = p.join(temp.path, 'ran');
    final flutter = File(p.join(sdkBin.path, 'flutter'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '#!/bin/sh\n'
        'printf "%s\\n%s\\n" "\$*" "\$FVM_FLUTTER_VERSION" > "$record"\n'
        'exit 5\n',
      );
    Process.runSync('chmod', ['+x', flutter.path]);

    final code = await fvm.run(
      ['flutter', '--version'],
      fileSystem: const LocalFileSystem(),
      environment: {
        // Rule 1, so the test does not depend on the directory it runs in.
        'FVM_FLUTTER_VERSION': '3.9.0',
        'FVM_HOME': home.path,
        'PATH': Platform.environment['PATH']!,
      },
      platformVersion: Platform.version,
      out: StringBuffer(),
      err: StringBuffer(),
    );

    expect(code, 5, reason: 'the SDK\'s exit code did not become fvm\'s');
    expect(File(record).readAsLinesSync(), ['--version', '3.9.0']);
  });

  group('in a process of its own', () {
    /// The driver program, run by the real `flutter` this suite is running under.
    Future<Process> spawn(List<String> arguments) async {
      final driver = p.join(
        Directory.current.path,
        'test',
        'exec',
        'runner_child.dart',
      );
      expect(
        File(driver).existsSync(),
        isTrue,
        reason: 'the driver program is missing: $driver',
      );
      return Process.start(
        Platform.resolvedExecutable,
        [driver, ...arguments],
        workingDirectory: Directory.current.path,
      );
    }

    test('the grandchild writes to the pipe the parent was given', () async {
      // `inheritStdio` means the child holds fvm's own descriptors, so its
      // output reaches whatever fvm's output was going to reach — here, this
      // test's pipe. A runner that plumbed the streams by hand would still
      // pass an exit-code test and fail this one.
      final process = await spawn(
        ['/bin/sh', '-c', 'echo hello-from-grandchild >&2; echo out; exit 7'],
      );

      expect(await process.exitCode, 7);
      expect(await process.stdout.transform(systemEncoding.decoder).join(),
          contains('out'));
      expect(await process.stderr.transform(systemEncoding.decoder).join(),
          contains('hello-from-grandchild'));
    });

    /// A child that traps [name] and exits with [code] when it arrives.
    ///
    /// Ctrl-C at a terminal already reaches the whole foreground process group,
    /// so it is the `kill` from a supervisor or a script — aimed at fvm alone —
    /// that these two cover. Without forwarding the wrapper dies of the signal
    /// and the real work is orphaned.
    Future<void> forwards(
      String name,
      ProcessSignal signal,
      int code,
    ) async {
      final marker = p.join(temp.path, 'caught-$name');
      final readyPath = p.join(temp.path, 'ready-$name');
      final waiter = script(
        'trap-$name.sh',
        'trap \'printf caught > "$marker"; exit $code\' $name\n'
            ': > "$readyPath"\n'
            'i=0\n'
            'while [ "\$i" -lt 60 ]; do sleep 1; i=\$((i + 1)); done\n'
            'exit 9\n',
      );

      final process = await spawn(['/bin/sh', waiter.path]);
      // The trap has to be installed before the signal is sent, or the child
      // dies on the default disposition and this passes for the wrong reason.
      final ready = File(readyPath);
      for (var i = 0; i < 200 && !ready.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(ready.existsSync(), isTrue, reason: 'the child never started');
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(Process.killPid(process.pid, signal), isTrue);

      // Only the trap can produce [code]: 9 means the signal never arrived and
      // the loop ran out, and a negative code means the wrapper took it.
      expect(await process.exitCode, code);
      expect(File(marker).existsSync(), isTrue);
    }

    test('SIGINT reaches the child, not just the wrapper', () async {
      await forwards('INT', ProcessSignal.sigint, 42);
    });

    test('SIGTERM reaches the child, not just the wrapper', () async {
      await forwards('TERM', ProcessSignal.sigterm, 43);
    });
  }, timeout: const Timeout(Duration(minutes: 2)));
}
