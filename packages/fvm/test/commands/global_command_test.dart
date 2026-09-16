import 'package:fvm/fvm.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late CommandHarness harness;

  setUp(() => harness = CommandHarness());

  test('sets the default and says where it was written', () async {
    harness.installVersion('3.9.0');

    expect(await harness.run(['global', '3.9.0']), 0);

    expect(harness.readConfig().global, '3.9.0');
    expect(harness.output, contains('global default'));
    expect(harness.output, contains('/fvm/config.json'));
  });

  test('the default it sets is what resolution then finds', () async {
    harness.installVersion('3.9.0');
    await harness.run(['global', '3.9.0']);
    harness.clearOutput();

    // The end setting a global exists for: a directory with no .fvmrc now
    // resolves, by rule 3.
    expect(await harness.run(['which']), 0);
    expect(harness.output, contains('rule 3 of 5'));
    expect(harness.output, contains('/fvm/versions/3.9.0/bin/flutter'));
  });

  test('installs the version if it is missing', () async {
    expect(await harness.run(['global', '3.9.0']), 0);

    expect(harness.installer.requests.single.version, '3.9.0');
    expect(harness.readConfig().global, '3.9.0');
  });

  test('records the concrete version behind a channel', () async {
    harness
      ..installVersion('3.13.2')
      ..writeConfig(const FvmConfig(channels: {'stable': '3.13.2'}));

    expect(await harness.run(['global', 'stable']), 0);

    // Not "stable": what a channel means changes at the next
    // `fvm install stable`, and a default that moves on its own is exactly
    // what a version manager is for preventing.
    expect(harness.readConfig().global, '3.13.2');
    expect(harness.output, contains('stable -> 3.13.2'));
  });

  test('reports the previous default when it changes', () async {
    harness
      ..installVersion('3.9.0')
      ..installVersion('3.13.2')
      ..writeConfig(const FvmConfig(global: '3.9.0'));

    await harness.run(['global', '3.13.2']);
    expect(harness.output, contains('was: 3.9.0'));
  });

  group('with no argument', () {
    test('says there is none when none is set', () async {
      expect(await harness.run(['global']), 0);
      expect(harness.output, contains('No global default is set'));
    });

    test('reports the one that is set', () async {
      harness
        ..installVersion('3.9.0')
        ..writeConfig(const FvmConfig(global: '3.9.0'));

      expect(await harness.run(['global']), 0);
      expect(harness.output, contains('The global default is 3.9.0'));
    });

    test('reports a default naming an SDK that is gone', () async {
      harness.writeConfig(const FvmConfig(global: '3.9.0'));

      expect(await harness.run(['global']), 1);
      expect(harness.errors, contains('It is not installed'));
    });
  });

  test('naming two versions is a usage error', () async {
    expect(await harness.run(['global', '3.9.0', '3.13.2']), usageExitCode);
    expect(harness.errors, contains('one version'));
  });
}
