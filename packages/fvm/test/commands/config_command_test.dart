import 'package:fvm/fvm.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('saved color preference', () {
    late CommandHarness h;
    setUp(() => h = CommandHarness());

    test('reading the default does not create a config', () async {
      expect(await h.run(['config', 'color']), 0);
      expect(h.output, 'color: auto\n');
      expect(h.paths.configFile.existsSync(), isFalse);
    });

    test('persists across invocations and preserves other settings', () async {
      h.writeConfig(const FvmConfig(
        global: '3.9.0',
        aliases: {'work': '3.9.0'},
        channels: {'stable': '3.9.0'},
        unknownKeys: {'future': true},
      ));
      expect(await h.run(['config', 'color', 'always']), 0);
      h.clearOutput();
      expect(await h.run(['config', 'color']), 0);
      expect(h.output, 'color: always\n');
      expect(h.readConfig().toJson(), {
        'global': '3.9.0',
        'aliases': {'work': '3.9.0'},
        'channels': {'stable': '3.9.0'},
        'future': true,
        'color': 'always',
      });
      h.config.write(h.readConfig().copyWith(global: '3.10.0'));
      expect(h.readConfig().color, ColorMode.always);
    });

    test('saved color applies, explicit flags override without saving',
        () async {
      await h.run(['config', 'color', 'always']);
      h.clearOutput();
      expect(await h.run(['doctor']), 1);
      expect(h.output, contains('\x1b['));
      for (final mode in ['never', 'auto']) {
        h.clearOutput();
        await h.run(['--color=$mode', 'doctor']);
        expect(h.output, isNot(contains('\x1b[')));
        expect(h.readConfig().color, ColorMode.always);
      }
      await h.run(['config', 'color', 'never']);
      h.clearOutput();
      await h.run(['--color=always', 'doctor']);
      expect(h.output, contains('\x1b['));
      expect(h.readConfig().color, ColorMode.never);
    });

    test('auto restores automatic detection', () async {
      await h.run(['config', 'color', 'always']);
      await h.run(['config', 'color', 'auto']);
      h.clearOutput();
      await h.run(['doctor']);
      expect(h.output, isNot(contains('\x1b[')));
      expect(h.readConfig().color, ColorMode.auto);
    });

    test('invalid arguments do not change the preference', () async {
      await h.run(['config', 'color', 'never']);
      for (final args in [
        ['config', 'color', 'yes'],
        ['config', 'unknown'],
        ['config', 'color', 'always', 'extra'],
      ]) {
        expect(await h.run(args), isNot(0));
        expect(h.readConfig().color, ColorMode.never);
      }
    });

    test('invalid saved color is diagnosed while help remains available',
        () async {
      h.paths.configFile
        ..createSync(recursive: true)
        ..writeAsStringSync('{"color":"invalid"}');
      expect(() => h.readConfig(), throwsA(isA<ConfigException>()));
      expect(await h.run(['--help']), 0);
      expect(await h.run(['doctor']), 1);
      expect(h.output + h.errors, contains('"color" must be'));
    });
  });
}
