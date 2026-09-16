import 'package:fvm/fvm.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late CommandHarness h;
  setUp(() {
    h = CommandHarness();
    h.executablePath = '/fvm/bin/fvm';
    h.fileSystem.file(h.executablePath!)
      ..createSync(recursive: true)
      ..writeAsStringSync('compiled fvm');
    h.environment['SHELL'] = '/bin/zsh';
    h.fileSystem.file('/home/dev/.zshrc')
      ..createSync(recursive: true)
      ..writeAsStringSync('# my shell settings\n');
  });

  for (final command in [
    ['install'],
    ['use'],
    ['global'],
    ['use', '--global'],
  ]) {
    for (final cached in [true, false]) {
      test('${command.join(' ')} creates missing shim (cached: $cached)',
          () async {
        if (cached) h.installVersion('3.9.0');
        expect(await h.run([...command, '3.9.0']), 0);
        expect(h.paths.flutterShim.readAsStringSync(),
            '#!/bin/sh\nexec "/fvm/bin/fvm" exec flutter "\$@"\n');
        expect(h.fileSystem.file('/home/dev/.zshrc').readAsStringSync(),
            '# my shell settings\n');
        expect(h.output, contains('export PATH='));
        expect(h.installer.requests.length, cached ? 0 : 1);
        h.clearOutput();
        expect(await h.run([...command, '3.9.0']), 0);
        expect(h.output, isNot(contains('Wrote /fvm/shims/flutter')));
      });
    }
  }

  test('does not overwrite an existing shim', () async {
    h.paths.flutterShim
      ..createSync(recursive: true)
      ..writeAsStringSync('custom shim');
    expect(await h.run(['install', '3.9.0']), 0);
    expect(h.paths.flutterShim.readAsStringSync(), 'custom shim');
  });

  test('does not write shims when installation fails', () async {
    h.installer.failure = const ConfigException('download failed');
    expect(await h.run(['install', '3.9.0']), 1);
    expect(h.paths.flutterShim.existsSync(), isFalse);
  });

  test('does not create a shim pointing to the Dart VM', () async {
    h.executablePath = '/sdk/bin/flutter';
    expect(await h.run(['install', '3.9.0']), 0);
    expect(h.paths.flutterShim.existsSync(), isFalse);
  });

  test('does not create a startup file when none exists', () async {
    h.fileSystem.file('/home/dev/.zshrc').deleteSync();
    expect(await h.run(['global', '3.9.0']), 0);
    expect(h.paths.flutterShim.existsSync(), isTrue);
    expect(h.fileSystem.file('/home/dev/.zshrc').existsSync(), isFalse);
  });
}
