// Not a test: the program the platform-independent process tests spawn.
//
// A Flutter program rather than a shell script, because the point of those tests
// is that they run on Windows too, and `/bin/sh` does not.
//
//     probe_child.dart <record path or -> <exit code> [arguments to echo...]
import 'dart:io';

void main(List<String> arguments) {
  final record = arguments[0];
  final code = int.parse(arguments[1]);

  if (record != '-') {
    File(record).writeAsStringSync(
      <String>[
        ...arguments.sublist(2),
        // A separator, so a test can tell an empty trailing argument from the
        // end of the list.
        '--',
        Platform.environment['FVM_FLUTTER_VERSION'] ?? '',
        Platform.environment['PATH'] ?? '',
      ].join('\n'),
    );
  }

  stdout.writeln('probe-stdout');
  stderr.writeln('probe-stderr');
  exit(code);
}
