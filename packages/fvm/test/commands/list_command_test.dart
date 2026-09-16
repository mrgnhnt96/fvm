import 'package:fvm/fvm.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late CommandHarness harness;

  setUp(() => harness = CommandHarness());

  test('says how to install one when nothing is installed', () async {
    expect(await harness.run(['list']), 0);
    expect(harness.output, contains('No Flutter SDKs are installed'));
    expect(harness.output, contains('fvm install'));
  });

  test('lists installed versions newest first', () async {
    harness
      ..installVersion('3.9.0')
      ..installVersion('3.13.2')
      ..installVersion('2.19.6');

    expect(await harness.run(['list']), 0);

    final versions = harness.output
        .split('\n')
        .where((line) => RegExp(r'^[* ] \d').hasMatch(line))
        .map((line) => line.substring(2).trim().split(' ').first)
        .toList();
    expect(versions, ['3.13.2', '3.9.0', '2.19.6']);
  });

  test('marks the global default and what this project resolves to', () async {
    harness
      ..installVersion('3.9.0')
      ..installVersion('3.13.2')
      ..writeConfig(const FvmConfig(global: '3.13.2'));
    harness.fileSystem.file('/project/.fvmrc').writeAsStringSync('3.9.0');

    expect(await harness.run(['list']), 0);

    expect(harness.output, contains(RegExp(r'\* 3\.9\.0.*this project')));
    expect(harness.output, contains(RegExp(r'  3\.13\.2.*global default')));
    // Under the working directory, so relative.
    expect(harness.output, contains('pinned by .fvmrc'));
    expect(harness.output, isNot(contains('/project/.fvmrc')));
  });

  test('shows the aliases and channels pointing at each version', () async {
    harness
      ..installVersion('3.9.0')
      ..installVersion('3.13.2')
      ..writeConfig(
        const FvmConfig(
          aliases: {'work': '3.9.0', 'latest': 'stable'},
          channels: {'stable': '3.13.2'},
        ),
      );

    expect(await harness.run(['list']), 0);

    expect(harness.output, contains(RegExp(r'3\.9\.0.*alias: work')));
    // `latest` points at `stable`, which points at 3.13.2, so it belongs on
    // that row rather than on a row of its own.
    expect(harness.output, contains(RegExp(r'3\.13\.2.*channel: stable')));
    expect(harness.output, contains(RegExp(r'3\.13\.2.*alias: latest')));
  });

  test('a directory with no bin/flutter is listed as broken', () async {
    harness
      ..installVersion('3.9.0')
      ..breakVersion('3.10.0');

    expect(await harness.run(['list']), 0);
    expect(harness.output, contains(RegExp(r'3\.10\.0.*BROKEN')));
  });

  test('says so when this directory falls through to PATH', () async {
    harness.installVersion('3.9.0');
    harness.putFlutterOnPath();

    expect(await harness.run(['list']), 0);
    expect(harness.output, contains('falls through to /usr/bin/flutter'));
    expect(harness.output, isNot(contains('this project')));
  });

  test('says so when nothing resolves at all', () async {
    harness.installVersion('3.9.0');

    expect(await harness.run(['list']), 0);
    expect(harness.output, contains('does not resolve to an installed SDK'));
  });

  test('warns when the global default is not installed', () async {
    harness
      ..installVersion('3.9.0')
      ..writeConfig(const FvmConfig(global: '3.13.2'));

    expect(await harness.run(['list']), 0);
    expect(harness.errors, contains('global default names 3.13.2'));
  });

  test('`ls` is the same command', () async {
    harness.installVersion('3.9.0');

    expect(await harness.run(['ls']), 0);
    expect(harness.output, contains('3.9.0'));
  });

  test('a non-semver directory is listed rather than hidden', () async {
    harness
      ..installVersion('3.9.0')
      ..installVersion('29803');

    expect(await harness.run(['list']), 0);
    expect(harness.output, contains('29803'));
  });
}
