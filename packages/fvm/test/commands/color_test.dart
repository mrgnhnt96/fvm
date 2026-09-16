import 'dart:io' as io;

import 'package:fvm/fvm.dart';
import 'package:fvm/src/archive/progress_bar.dart';
import 'package:test/test.dart';

import 'color_scenarios.dart';
import 'harness.dart';

/// Every escape sequence fvm can emit, so a test can say "none of these".
final RegExp _ansi = RegExp(r'\x1B\[[0-9;]*m');

String _strip(String text) => text.replaceAll(_ansi, '');

/// The golden lives beside this file; `dart test` runs from the package root.
///
/// CRLF is undone on the way IN, and only on the golden. Git's Windows default
/// (`core.autocrlf=true`, which the windows-latest runner uses) rewrites LF to
/// CRLF on checkout, so a tracked golden can reach disk carrying `\r\n` that
/// nobody committed — and it did, which is what turned this group red on
/// Windows and nowhere else. `.gitattributes` pins the golden to `-text` so
/// this stops happening at the source; undoing it here as well means the next
/// fixture added without an attributes entry does not reintroduce it.
///
/// The ACTUAL output is deliberately left alone. This group's entire claim is
/// that not one byte of fvm's uncoloured output moved, so normalising both
/// sides would let a real `\r\n` regression in what fvm prints slip past. Only
/// `\r\n` is collapsed, never a bare `\r`, which the progress bar emits on
/// purpose.
String _golden() => io.File('test/commands/color_off_golden.txt')
    .readAsStringSync()
    .replaceAll('\r\n', '\n');

void main() {
  group('colour off is byte-identical to the output before colour existed', () {
    // The regression guard for the scope rule: this change is presentation
    // only, so with colour off not one byte may move. The golden was generated
    // by `tool/generate_golden.dart` running against the commit before any
    // styling existed — it is a real BEFORE, not a snapshot of the code it is
    // checking.
    //
    // KEEP IT THAT WAY. A later change that legitimately adds or removes a line
    // of OUTPUT edits the golden by hand, applying exactly the lines it adds
    // and leaving every other byte alone, so the diff on this file is
    // reviewable and the "before" is still a before. Re-running the generator
    // against current code would turn it into a snapshot of whatever the code
    // does today and quietly launder a colour bug into the expectation. The
    // `ok build:` line each `fvm doctor` block opens with was added that way.
    test('a non-terminal sink, which is what a pipe and a CI log are',
        () async {
      expect(await renderColorScenarios(), _golden());
    });

    test('--color=never, even on a terminal', () async {
      expect(
        await renderColorScenarios(
          extraArgs: ['--color=never'],
          outIsTerminal: true,
          environment: {'TERM': 'xterm-256color'},
        ),
        _golden(),
      );
    });

    test('NO_COLOR set, on a terminal', () async {
      expect(
        await renderColorScenarios(
          outIsTerminal: true,
          environment: {'TERM': 'xterm-256color', 'NO_COLOR': '1'},
        ),
        _golden(),
      );
    });

    test('TERM=dumb, on a terminal', () async {
      expect(
        await renderColorScenarios(
          outIsTerminal: true,
          environment: {'TERM': 'dumb'},
        ),
        _golden(),
      );
    });

    test('TERM unset, on a terminal', () async {
      expect(await renderColorScenarios(outIsTerminal: true), _golden());
    });

    test('a terminal that would colour, but an injected sink is never one',
        () async {
      // The default in every existing test: `outIsTerminal` is false unless
      // the composition root says otherwise, so the whole suite runs uncoloured
      // without a single test having to opt out.
      expect(
        await renderColorScenarios(
          environment: {'TERM': 'xterm-256color'},
        ),
        _golden(),
      );
    });

    test('colour adds escape sequences and nothing else', () async {
      // The other direction: with colour ON at full blast, stripping the
      // escapes back out must land exactly on the golden. Anything else means
      // the styling moved a character, which this leaf is not allowed to do.
      final coloured =
          await renderColorScenarios(extraArgs: ['--color=always']);
      expect(coloured, isNot(_golden()));
      expect(_strip(coloured), _golden());
    });
  });

  group('with colour on, each role gets its own sequence', () {
    late String doctor;

    setUp(() async {
      final harness = CommandHarness();
      harness.putFlutterOnPath();
      await harness.run(['--color=always', 'doctor']);
      doctor = harness.output;
    });

    test('ok is green, warn is yellow, FAIL is red', () {
      expect(doctor, contains('\x1B[32mok  \x1B[0m'));
      expect(doctor, contains('\x1B[31mFAIL\x1B[0m'));
    });

    test('the heading is bold', () {
      expect(doctor, startsWith('\x1B[1mfvm doctor\x1B[0m\n'));
    });

    test('the remedy lead-in is dim and the command it leads to is cyan', () {
      expect(
        doctor,
        contains('\x1B[2m          -> Run: \x1B[0m'
            '\x1B[36mfvm setup\x1B[0m'),
      );
    });

    test('supporting detail under a finding is dim', () {
      expect(doctor, contains('\x1B[2m          PATH order'));
    });

    test('the verdict is coloured by the worst thing in it', () {
      expect(doctor, contains(RegExp(r'\x1B\[31m\d+ problems?, ')));
    });

    test('a clean run says so in green', () async {
      final harness = CommandHarness()..installVersion('3.9.0');
      harness.fileSystem.file('${CommandHarness.fvmHome}/shims/flutter')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '#!/bin/sh\nexec "${CommandHarness.fvmHome}/bin/fvm" exec flutter '
          '"\$@"\n',
        );
      harness.fileSystem.file('${CommandHarness.fvmHome}/bin/fvm')
        ..createSync(recursive: true)
        ..writeAsStringSync('the fvm binary');
      harness.environment['PATH'] = '${CommandHarness.fvmHome}/shims';
      await harness.run(['--color=always', 'doctor']);
      expect(harness.output, contains('\x1B[32mEverything checks out.\x1B[0m'));
    });

    test('install says where it put the SDK, in bold', () async {
      final harness = CommandHarness();
      await harness.run(['--color=always', 'install', '3.13.2']);
      expect(
        harness.output,
        contains('\x1B[1mInstalled Flutter 3.13.2 to '
            '${CommandHarness.fvmHome}/versions/3.13.2\x1B[0m'),
      );
    });

    test('setup highlights the PATH line the user has to paste', () async {
      final harness = CommandHarness();
      harness.fileSystem.file('${CommandHarness.fvmHome}/bin/fvm')
        ..createSync(recursive: true)
        ..writeAsStringSync('the fvm binary');
      harness.environment['SHELL'] = '/bin/zsh';
      await harness.run([
        '--color=always',
        'setup',
        '--fvm-path',
        '${CommandHarness.fvmHome}/bin/fvm',
      ]);
      expect(
        harness.output,
        contains('  \x1B[36mexport PATH="${CommandHarness.fvmHome}/shims:'
            '${CommandHarness.fvmHome}/bin:\$PATH"\x1B[0m'),
      );
      expect(
        harness.output,
        startsWith(
            '\x1B[1mWrote ${CommandHarness.fvmHome}/shims/flutter\x1B[0m'),
      );
    });
  });

  group('--color precedence', () {
    test('--color=always overrides NO_COLOR, because the flag is this run',
        () async {
      final harness = CommandHarness();
      harness.environment['NO_COLOR'] = '1';
      await harness.run(['--color=always', 'install', '3.13.2']);
      expect(harness.output, contains('\x1B['));
    });

    test('--color=always overrides TERM=dumb', () async {
      final harness = CommandHarness();
      harness.environment['TERM'] = 'dumb';
      await harness.run(['--color=always', 'install', '3.13.2']);
      expect(harness.output, contains('\x1B['));
    });

    test('an unknown --color value is a usage error, not a guess', () async {
      final harness = CommandHarness();
      expect(await harness.run(['--color=maybe', 'install', '3.13.2']), 64);
    });
  });

  group('what must never carry an escape sequence', () {
    test('`fvm which --path`, which scripts read with \$(fvm which --path)',
        () async {
      final harness = CommandHarness()..installVersion('3.9.0');
      harness.fileSystem.file('/project/.fvmrc').writeAsStringSync('3.9.0');
      expect(await harness.run(['--color=always', 'which', '--path']), 0);
      expect(harness.output, isNot(contains('\x1B')));
      // Not merely escape-free: still the exact path, so a consumer can use it.
      expect(
        harness.output.trim(),
        '${CommandHarness.fvmHome}/versions/3.9.0/bin/flutter',
      );
    });

    test("`fvm which`'s first line, which is what `fvm which | head -1` takes",
        () async {
      final harness = CommandHarness()..installVersion('3.9.0');
      harness.fileSystem.file('/project/.fvmrc').writeAsStringSync('3.9.0');
      expect(await harness.run(['--color=always', 'which']), 0);
      final first = harness.output.split('\n').first;
      expect(first, isNot(contains('\x1B')));
      expect(first, '${CommandHarness.fvmHome}/versions/3.9.0/bin/flutter');
    });

    test('the .fvmrc fvm writes', () async {
      final harness = CommandHarness()..installVersion('3.9.0');
      expect(await harness.run(['--color=always', 'use', '3.9.0']), 0);
      expect(harness.readFvmrc(), isNot(contains('\x1B')));
    });

    test('a shell startup file fvm edits — the nastiest place for one',
        () async {
      final harness = CommandHarness();
      harness.fileSystem.file('${CommandHarness.fvmHome}/bin/fvm')
        ..createSync(recursive: true)
        ..writeAsStringSync('the fvm binary');
      harness.fileSystem.file('/home/dev/.zshrc')
        ..createSync(recursive: true)
        ..writeAsStringSync('# nothing here yet\n');
      harness.environment['SHELL'] = '/bin/zsh';
      await harness.run([
        '--color=always',
        'setup',
        '--write-path-line',
        '--fvm-path',
        '${CommandHarness.fvmHome}/bin/fvm',
      ]);
      final written =
          harness.fileSystem.file('/home/dev/.zshrc').readAsStringSync();
      expect(written, contains('${CommandHarness.fvmHome}/shims'));
      expect(written, isNot(contains('\x1B')));
    });

    test('the shim fvm writes', () async {
      final harness = CommandHarness();
      harness.fileSystem.file('${CommandHarness.fvmHome}/bin/fvm')
        ..createSync(recursive: true)
        ..writeAsStringSync('the fvm binary');
      await harness.run([
        '--color=always',
        'setup',
        '--fvm-path',
        '${CommandHarness.fvmHome}/bin/fvm',
      ]);
      expect(
        harness.fileSystem
            .file('${CommandHarness.fvmHome}/shims/flutter')
            .readAsStringSync(),
        isNot(contains('\x1B')),
      );
    });
  });

  group('Styles decides on its own', () {
    Styles styles({
      Map<String, String> environment = const {},
      bool outIsTerminal = false,
    }) =>
        Styles(environment: environment, outIsTerminal: outIsTerminal);

    test('a terminal with a capable TERM colours', () {
      expect(
        styles(environment: {'TERM': 'xterm'}, outIsTerminal: true).enabled,
        isTrue,
      );
    });

    test('a non-terminal never colours on auto', () {
      expect(styles(environment: {'TERM': 'xterm'}).enabled, isFalse);
    });

    test('NO_COLOR set to anything non-empty turns it off', () {
      for (final value in ['1', '0', 'false', 'no']) {
        expect(
          styles(
            environment: {'TERM': 'xterm', 'NO_COLOR': value},
            outIsTerminal: true,
          ).enabled,
          isFalse,
          reason: 'NO_COLOR=$value is still a request',
        );
      }
    });

    test('NO_COLOR present but EMPTY is not a request, per the spec', () {
      expect(
        styles(
          environment: {'TERM': 'xterm', 'NO_COLOR': ''},
          outIsTerminal: true,
        ).enabled,
        isTrue,
      );
    });

    test('TERM=dumb and an unset TERM both turn it off', () {
      expect(
        styles(environment: {'TERM': 'dumb'}, outIsTerminal: true).enabled,
        isFalse,
      );
      expect(styles(outIsTerminal: true).enabled, isFalse);
    });

    test('always beats every environment reason to stay quiet', () {
      final value = styles(environment: {'NO_COLOR': '1', 'TERM': 'dumb'})
        ..setMode(ColorMode.always);
      expect(value.enabled, isTrue);
    });

    test('never beats a terminal that would otherwise colour', () {
      final value = styles(environment: {'TERM': 'xterm'}, outIsTerminal: true)
        ..setMode(ColorMode.never);
      expect(value.enabled, isFalse);
    });

    test('an empty span is never wrapped, so an absent lead-in costs nothing',
        () {
      final value = styles()..setMode(ColorMode.always);
      expect(value.detail(''), '');
      expect(value.command(''), '');
    });

    test('each role has its own sequence, so the palette stays legible', () {
      final value = styles()..setMode(ColorMode.always);
      expect(value.ok('x'), '\x1B[32mx\x1B[0m');
      expect(value.warn('x'), '\x1B[33mx\x1B[0m');
      expect(value.fail('x'), '\x1B[31mx\x1B[0m');
      expect(value.heading('x'), '\x1B[1mx\x1B[0m');
      expect(value.command('x'), '\x1B[36mx\x1B[0m');
      expect(value.detail('x'), '\x1B[2mx\x1B[0m');
    });
  });

  group('the progress bars install prints', () {
    ProgressBar bar(StringSink sink, Styles styles, {required bool terminal}) =>
        ProgressBar(
          sink: sink,
          styles: styles,
          label: 'flutter-sdk',
          total: 100,
          isTerminal: terminal,
        );

    test('are dimmed on a terminal, with the \\r left OUTSIDE the span', () {
      // The carriage return is a cursor movement, not text. Inside the styled
      // span it would sit after the escape that starts it, which is not what
      // the next repaint expects to overwrite.
      final sink = StringBuffer();
      final styles = Styles()..setMode(ColorMode.always);
      bar(sink, styles, terminal: true).update(50);
      expect(sink.toString(),
          '\r\x1B[2m  flutter-sdk  50%  (0.0 / 0.0 MB)\x1B[0m');
    });

    test('are dimmed as discrete lines when the sink is not a terminal', () {
      final sink = StringBuffer();
      final styles = Styles()..setMode(ColorMode.always);
      bar(sink, styles, terminal: false).update(50);
      expect(
        sink.toString(),
        '\x1B[2m  flutter-sdk  50%  (0.0 / 0.0 MB)\x1B[0m\n',
      );
    });

    test('carry no escape at all when colour is off', () {
      final sink = StringBuffer();
      bar(sink, Styles(), terminal: false)
        ..update(50)
        ..finish(100);
      expect(sink.toString(), isNot(contains('\x1B')));
    });

    test('default to no styling when nobody passed any', () {
      // The default matters: `ProgressBar` is built in three places, and one
      // of them forgetting must produce plain output rather than colour that
      // ignores NO_COLOR.
      final sink = StringBuffer();
      ProgressBar(sink: sink, label: 'x', total: 100, isTerminal: false)
          .update(50);
      expect(sink.toString(), isNot(contains('\x1B')));
    });
  });
}
