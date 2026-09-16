import 'package:test/test.dart';

import '../commands/harness.dart';
import 'support.dart';

void main() {
  test('runs bundled Dart with exact arguments and the selected SDK PATH',
      () async {
    final harness = CommandHarness()..installVersion('3.44.0');
    harness.fileSystem.file('/fvm/versions/3.44.0/bin/dart')
      ..createSync(recursive: true)
      ..writeAsStringSync('');
    harness.fileSystem.file('/code/app/.fvmrc')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"flutter":"3.44.0"}');
    harness.fileSystem.currentDirectory = '/code/app';
    final processes = FakeProcessRunner()..result = 17;
    expect(
        await runWith(harness, ['dart', '--', 'run', 'a b.dart', '--help'],
            processes: processes),
        17);
    expect(processes.only.executable, '/fvm/versions/3.44.0/bin/dart');
    expect(processes.only.arguments, ['run', 'a b.dart', '--help']);
    expect(processes.only.environment!['PATH'],
        startsWith('/fvm/versions/3.44.0/bin'));
    expect(processes.only.environment!['FVM_FLUTTER_VERSION'], '3.44.0');
  });

  test('missing bundled Dart produces a useful error without spawning',
      () async {
    final harness = CommandHarness()..installVersion('3.44.0');
    harness.environment['FVM_FLUTTER_VERSION'] = '3.44.0';
    final processes = FakeProcessRunner();
    expect(
        await runWith(harness, ['dart', '--version'], processes: processes), 1);
    expect(harness.errors, contains('no Dart launcher'));
    expect(processes.calls, isEmpty);
  });
}
