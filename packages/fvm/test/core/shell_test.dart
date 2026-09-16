import 'package:fvm/src/core/path_line.dart';
import 'package:fvm/src/core/shell.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

void main() {
  late MemoryFileSystem fileSystem;

  ShellFacts factsFor(Map<String, String> environment) => ShellFacts(
        fileSystem: fileSystem,
        environment: {'HOME': '/home/dev', ...environment},
      );

  void writeRc(String path, String contents) => fileSystem.file(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);

  setUp(() => fileSystem = MemoryFileSystem.test());

  group('shell detection', () {
    test(r'names the rc file for the shell in $SHELL', () {
      expect(factsFor({'SHELL': '/bin/zsh'}).primaryRcFile?.path,
          '/home/dev/.zshrc');
      expect(factsFor({'SHELL': '/bin/bash'}).primaryRcFile?.path,
          '/home/dev/.bashrc');
      expect(
        factsFor({'SHELL': '/opt/homebrew/bin/fish'}).primaryRcFile?.path,
        '/home/dev/.config/fish/config.fish',
      );
    });

    test('falls back to .profile when the environment does not say', () {
      final facts = factsFor(const {});

      expect(facts.shellPath, isNull);
      expect(facts.kind, ShellKind.posix);
      expect(facts.primaryRcFile?.path, '/home/dev/.profile');
    });

    test('an unset SHELL is a GUESS, not an answer', () {
      final facts = factsFor(const {});

      expect(facts.kind, ShellKind.posix);
      expect(facts.kindIsAssumed, isTrue);
    });

    test('an unrecognised SHELL is a guess too', () {
      final facts = factsFor({'SHELL': '/usr/local/bin/nu'});

      expect(facts.kind, ShellKind.posix);
      expect(facts.kindIsAssumed, isTrue);
    });

    test('a SHELL that names a real POSIX shell is NOT a guess', () {
      // `.profile` is genuinely what these read. Nagging the user whose setup
      // is right is the other way to get this wrong.
      for (final path in const ['/bin/sh', '/bin/dash', '/bin/ksh']) {
        final facts = factsFor({'SHELL': path});
        expect(facts.kind, ShellKind.posix, reason: path);
        expect(facts.kindIsAssumed, isFalse, reason: path);
      }
    });

    test('a guessed shell plus another shell\'s rc file is an ambiguity', () {
      writeRc('/home/dev/.zshrc', 'export EDITOR=vim\n');
      final facts = factsFor(const {});

      expect(facts.primaryRcFile?.path, '/home/dev/.profile');
      expect(facts.rcFileIsGuessed, isTrue);
      expect(
        facts.otherShellRcFiles.map((other) => other.file.path),
        ['/home/dev/.zshrc'],
      );
      expect(facts.otherShellRcFiles.single.shell, ShellKind.zsh);
    });

    test('a guessed shell with an empty home is NOT an ambiguity', () {
      // The ordinary CI case. There is no startup file at all, so `.profile`
      // is as good an answer as any and there is nothing to warn about.
      expect(factsFor(const {}).rcFileIsGuessed, isFalse);
    });

    test('a KNOWN shell is never an ambiguity, whatever else is lying around',
        () {
      // The ordinary developer case: $SHELL said zsh, and a stale .bashrc is
      // none of fvm's business.
      writeRc('/home/dev/.bashrc', 'export EDITOR=vim\n');
      writeRc('/home/dev/.profile', 'export EDITOR=vim\n');
      final facts = factsFor({'SHELL': '/bin/zsh'});

      expect(facts.rcFileIsGuessed, isFalse);
      expect(facts.primaryRcFile?.path, '/home/dev/.zshrc');
    });

    test('only rc files that EXIST count as evidence', () {
      expect(factsFor(const {}).otherShellRcFiles, isEmpty);
    });

    test('has no rc file to name without a home directory', () {
      final facts = ShellFacts(
        fileSystem: fileSystem,
        environment: const {'SHELL': '/bin/zsh'},
      );

      expect(facts.home, isNull);
      expect(facts.primaryRcFile, isNull);
    });

    test('prepends the shims directory, in the shell being used', () {
      final shims = fileSystem.directory('/fvm/shims');

      expect(
        factsFor({'SHELL': '/bin/zsh'}).pathLine([shims]),
        r'export PATH="/fvm/shims:$PATH"',
      );
      expect(
        factsFor({'SHELL': '/usr/bin/fish'}).pathLine([shims]),
        'fish_add_path --prepend /fvm/shims',
      );
    });

    test('covers several directories with ONE line, in the order given', () {
      final shims = fileSystem.directory('/fvm/shims');
      final bin = fileSystem.directory('/fvm/bin');

      expect(
        factsFor({'SHELL': '/bin/zsh'}).pathLine([shims, bin]),
        r'export PATH="/fvm/shims:/fvm/bin:$PATH"',
      );
      expect(
        factsFor({'SHELL': '/usr/bin/fish'}).pathLine([shims, bin]),
        'fish_add_path --prepend /fvm/shims /fvm/bin',
      );
    });

    // THE REGRESSION GUARD. A startup file that assigns an EXPANDED absolute
    // PATH throws away everything PATH held before the line runs — including
    // whatever the user's own earlier lines added — silently, on every login.
    // The raw string is the point: it asserts the six characters `$PATH` are
    // in the file, not the value they expand to here.
    test(r'leaves $PATH literal, whatever the line covers', () {
      final line = factsFor({'SHELL': '/bin/zsh'}).pathLine([
        fileSystem.directory('/fvm/shims'),
        fileSystem.directory('/fvm/bin'),
      ]);

      expect(line, endsWith(r':$PATH"'));
      expect(line, contains(r'$PATH'));
      // The failure this rules out: the absolute PATH of the process that
      // wrote the line, baked in where the variable belongs.
      expect(line, isNot(contains('/usr/bin:')));
    });
  });

  group('on Windows', () {
    late MemoryFileSystem windows;

    /// The environment a Windows terminal really presents: `USERPROFILE` and
    /// no `SHELL` at all.
    ShellFacts windowsFacts([Map<String, String> environment = const {}]) =>
        ShellFacts(
          fileSystem: windows,
          environment: {
            'USERPROFILE': r'C:\Users\dev',
            ...environment,
          },
        );

    setUp(() {
      windows = MemoryFileSystem.test(style: FileSystemStyle.windows);
    });

    test('an unset SHELL means PowerShell, not sh', () {
      final facts = windowsFacts();

      expect(facts.shellPath, isNull);
      expect(facts.kind, ShellKind.powershell);
      // The POSIX fallback would name C:\Users\dev\.profile here, a file
      // no Windows shell has ever read.
      expect(facts.primaryRcFile, isNull);
    });

    test('the PATH line edits the user environment', () {
      final line =
          windowsFacts().pathLine([windows.directory(r'C:\fvm\shims')]);

      expect(line, contains('SetEnvironmentVariable'));
      expect(line, contains(r'C:\fvm\shims;'));
      expect(line, contains("'User'"));
      // The POSIX line is the bug this replaces: `export` is not a command on
      // Windows and `:` is not its PATH separator.
      expect(line, isNot(contains('export')));
      expect(line, isNot(contains(r'$PATH')));
    });

    test('a quote in the path is escaped rather than ending the string', () {
      final line = windowsFacts()
          .pathLine([windows.directory(r"C:\Users\o'brien\.fvm\shims")]);

      expect(line, contains(r"C:\Users\o''brien\.fvm\shims;"));
    });

    test('says to run the line rather than to file it', () {
      expect(windowsFacts().pathLineAction, contains('Run'));
      expect(
        factsFor({'SHELL': '/bin/zsh'}).pathLineAction,
        contains('startup file'),
      );
    });

    test('a Windows user inside Git Bash gets the POSIX line', () {
      // Git Bash and MSYS both set $SHELL. Someone who typed `fvm setup` in
      // one of those is in a shell that really does read .bashrc, and telling
      // them to run a PowerShell command would be telling them to leave.
      final facts = windowsFacts({'SHELL': '/usr/bin/bash'});

      expect(facts.kind, ShellKind.bash);
      expect(
        facts.pathLine([windows.directory(r'C:\fvm\shims')]),
        startsWith('export PATH='),
      );
    });
  });

  group('shadow scan', () {
    test('finds the line that sources the older cbracken fvm', () {
      writeRc(
        '/home/dev/.zshrc',
        'export EDITOR=vim\n'
            '[ -s "\$HOME/.fvm/scripts/fvm" ] && . "\$HOME/.fvm/scripts/fvm"\n',
      );

      final scan = factsFor({'SHELL': '/bin/zsh'}).scanForShadows();

      expect(scan.shadows, hasLength(1));
      expect(scan.shadows.single.kind, ShadowKind.legacySource);
      expect(scan.shadows.single.line, 2);
      expect(scan.shadows.single.describe(), startsWith('/home/dev/.zshrc:2:'));
    });

    test('finds a fvm function and a fvm alias', () {
      writeRc('/home/dev/.bashrc', 'fvm() {\n  echo old\n}\n');
      writeRc('/home/dev/.profile', 'alias fvm="/opt/old/fvm"\n');

      final scan = factsFor({'SHELL': '/bin/bash'}).scanForShadows();

      expect(
        scan.shadows.map((shadow) => shadow.kind),
        containsAll([ShadowKind.function, ShadowKind.alias]),
      );
    });

    test('finds fish function syntax too', () {
      writeRc(
          '/home/dev/.config/fish/config.fish', 'function fvm\n  old\nend\n');

      final scan = factsFor({'SHELL': '/usr/bin/fish'}).scanForShadows();

      expect(scan.shadows.single.kind, ShadowKind.function);
    });

    test('scans every shell\'s startup files, not just the current one', () {
      // $SHELL is the variable that is wrong inside an editor terminal or a
      // CI runner; a function left in .zshrc still breaks the next login.
      writeRc('/home/dev/.zshrc', 'fvm() { echo old; }\n');

      final scan = factsFor({'SHELL': '/bin/bash'}).scanForShadows();

      expect(scan.shadows.single.file.path, '/home/dev/.zshrc');
    });

    test('ignores commented-out definitions', () {
      writeRc(
        '/home/dev/.zshrc',
        '# fvm() { echo old; }\n'
            '#[ -s "\$HOME/.fvm/scripts/fvm" ] && . "\$HOME/.fvm/scripts/fvm"\n',
      );

      expect(factsFor({'SHELL': '/bin/zsh'}).scanForShadows().isClean, isTrue);
    });

    test('finds the PATH line, in whichever file it is, when asked to', () {
      writeRc(
          '/home/dev/.profile',
          '# >>> fvm >>>\n'
              'export PATH="/home/dev/.fvm/shims:\$PATH"\n'
              '# <<< fvm <<<\n');
      final scan = factsFor({'SHELL': '/bin/zsh'}).scanForShadows(
        shimsLine: ShimsPathLine(
          shimsPath: '/home/dev/.fvm/shims',
          homePath: '/home/dev',
        ),
      );

      expect(scan.pathLines, hasLength(1));
      expect(scan.pathLines.single.file.path, '/home/dev/.profile');
      expect(scan.pathLines.single.line, 2);
      expect(scan.pathLines.single.describe(), '/home/dev/.profile:2');
    });

    test('finds a hand-written PATH line spelled with \$HOME', () {
      writeRc(
          '/home/dev/.zprofile',
          r'export PATH="$HOME/.fvm/shims:$PATH"'
              '\n');
      final scan = factsFor({'SHELL': '/bin/zsh'}).scanForShadows(
        shimsLine: ShimsPathLine(
          shimsPath: '/home/dev/.fvm/shims',
          homePath: '/home/dev',
        ),
      );

      expect(scan.pathLines.single.file.path, '/home/dev/.zprofile');
    });

    test('reports no PATH lines when it was given nothing to match', () {
      writeRc(
          '/home/dev/.profile',
          r'export PATH="/home/dev/.fvm/shims:$PATH"'
              '\n');

      expect(factsFor(const {}).scanForShadows().pathLines, isEmpty);
    });

    test('says nothing about a machine with clean startup files', () {
      writeRc('/home/dev/.zshrc', 'export PATH="/fvm/shims:\$PATH"\n');

      final scan = factsFor({'SHELL': '/bin/zsh'}).scanForShadows();

      expect(scan.shadows, isEmpty);
      expect(scan.unreadable, isEmpty);
    });
  });
}
