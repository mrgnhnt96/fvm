import 'package:fvm/fvm.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late CommandHarness harness;

  setUp(() => harness = CommandHarness());

  group('defining an alias', () {
    test('writes it to the config', () async {
      harness.installVersion('3.9.0');

      expect(await harness.run(['alias', 'work', '3.9.0']), 0);

      expect(harness.readConfig().aliases, {'work': '3.9.0'});
      expect(harness.output, contains('"work" now means 3.9.0'));
    });

    test('an alias may point at a channel', () async {
      harness
        ..installVersion('3.13.2')
        ..writeConfig(const FvmConfig(channels: {'stable': '3.13.2'}));

      expect(await harness.run(['alias', 'latest', 'stable']), 0);
      expect(harness.readConfig().aliases, {'latest': 'stable'});
      expect(harness.output, contains('stable -> 3.13.2'));
    });

    test('redefining reports what it used to mean', () async {
      harness.writeConfig(const FvmConfig(aliases: {'work': '3.8.0'}));

      expect(await harness.run(['alias', 'work', '3.9.0']), 0);
      expect(harness.readConfig().aliases, {'work': '3.9.0'});
      expect(harness.output, contains('was: 3.8.0'));
    });

    test('a target that is not installed is a note, not a refusal', () async {
      expect(await harness.run(['alias', 'work', '3.9.0']), 0);
      expect(harness.readConfig().aliases, {'work': '3.9.0'});
      expect(harness.output, contains('is not installed'));
    });
  });

  group('names it refuses', () {
    test('refuses to shadow the stable channel', () async {
      expect(await harness.run(['alias', 'stable', '3.9.0']), 1);

      expect(harness.errors, contains('"stable" is a Flutter release channel'));
      expect(harness.readConfig().aliases, isEmpty,
          reason: 'a refused alias must not be written');
    });

    test('refuses to shadow beta and dev too', () async {
      for (final channel in ['beta', 'dev']) {
        harness.clearOutput();
        expect(await harness.run(['alias', channel, '3.9.0']), 1);
        expect(harness.errors, contains('release channel'));
      }
      expect(harness.readConfig().aliases, isEmpty);
    });

    test('refuses a literal version string', () async {
      expect(await harness.run(['alias', '3.9.0', '3.13.2']), 1);
      expect(harness.errors, contains('looks like a version'));
      expect(harness.readConfig().aliases, isEmpty);
    });

    test('refuses `list`, which already means something', () async {
      expect(await harness.run(['alias', 'list', '3.9.0']), 1);
      expect(harness.errors, contains('cannot be an alias'));
    });

    test('refuses an alias that points at itself', () async {
      expect(await harness.run(['alias', 'work', 'work']), 1);
      expect(harness.errors, contains('cannot point at itself'));
      expect(harness.readConfig().aliases, isEmpty);
    });

    test('refuses a loop through another alias', () async {
      harness.writeConfig(const FvmConfig(aliases: {'a': 'b'}));

      expect(await harness.run(['alias', 'b', 'a']), 1);
      expect(harness.errors, contains('would make a loop'));
      expect(harness.readConfig().aliases, {'a': 'b'});
    });
  });

  group('alias list', () {
    test('says how to make one when there are none', () async {
      expect(await harness.run(['alias', 'list']), 0);
      expect(harness.output, contains('No aliases yet'));
    });

    test('bare `fvm alias` lists too', () async {
      harness.writeConfig(const FvmConfig(aliases: {'work': '3.9.0'}));

      expect(await harness.run(['alias']), 0);
      expect(harness.output, contains('work'));
      expect(harness.output, contains('3.9.0'));
    });

    test('shows what each alias resolves to and whether it is installed',
        () async {
      harness
        ..installVersion('3.13.2')
        ..writeConfig(
          const FvmConfig(
            aliases: {'work': '3.9.0', 'latest': 'stable'},
            channels: {'stable': '3.13.2'},
          ),
        );

      expect(await harness.run(['alias', 'list']), 0);

      expect(harness.output, contains('work'));
      expect(harness.output, contains('NOT installed'));
      expect(harness.output, contains('latest'));
      expect(harness.output, contains('stable -> 3.13.2  (installed)'));
      expect(harness.output, contains('Channels, as recorded by fvm install'));
    });

    test('a broken alias is shown as broken rather than crashing the list',
        () async {
      harness.writeConfig(const FvmConfig(aliases: {'work': 'work'}));

      expect(await harness.run(['alias', 'list']), 0);
      expect(harness.output, contains('broken'));
    });
  });

  group('unalias', () {
    test('removes the alias and leaves the SDK alone', () async {
      harness
        ..installVersion('3.9.0')
        ..writeConfig(
          const FvmConfig(aliases: {'work': '3.9.0', 'other': '3.13.2'}),
        );

      expect(await harness.run(['unalias', 'work']), 0);

      expect(harness.readConfig().aliases, {'other': '3.13.2'});
      expect(harness.fileSystem.directory('/fvm/versions/3.9.0').existsSync(),
          isTrue);
    });

    test('an unknown alias lists the ones that exist', () async {
      harness.writeConfig(const FvmConfig(aliases: {'work': '3.9.0'}));

      expect(await harness.run(['unalias', 'nope']), 1);
      expect(harness.errors, contains('There is no alias "nope"'));
      expect(harness.errors, contains('work'));
    });

    test('warns when the global default still names it', () async {
      harness.writeConfig(
        const FvmConfig(global: 'work', aliases: {'work': '3.9.0'}),
      );

      expect(await harness.run(['unalias', 'work']), 0);
      expect(harness.errors, contains('The global default still says "work"'));
    });

    test('warns when this project still pins it', () async {
      harness.writeConfig(const FvmConfig(aliases: {'work': '3.9.0'}));
      harness.fileSystem.file('/project/.fvmrc').writeAsStringSync('work');

      expect(await harness.run(['unalias', 'work']), 0);
      expect(harness.errors, contains('.fvmrc still pins "work"'));
      expect(harness.errors, isNot(contains('/project/.fvmrc')));
    });

    test('naming nothing is a usage error', () async {
      expect(await harness.run(['unalias']), usageExitCode);
      expect(harness.errors, contains('Name the alias to remove'));
    });
  });
}
