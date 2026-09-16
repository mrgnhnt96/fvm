// Regenerates `test/commands/color_off_golden.txt`.
//
// The checked-in golden was produced by this same scenario set run against the
// commit BEFORE any styling existed, so it records what fvm printed with no
// colour code in the tree at all. Regenerate it only when the WORDING of an
// output line deliberately changes; if it moves because colour was added, that
// is the bug the golden exists to catch.
//
// It writes LF on every platform, which is the convention the golden is read
// with: `StringBuffer.writeln` appends `\n` and never the host's terminator,
// and `writeAsStringSync` encodes those bytes without translating them. So
// regenerating on Windows cannot produce a golden that only matches on
// Windows. `.gitattributes` pins the file to `-text` so git does not undo
// that on the way through a checkout.
//
// Usage, from `packages/fvm`:  dart run tool/generate_golden.dart
import 'dart:io';

import '../test/commands/color_scenarios.dart';

Future<void> main() async {
  const path = 'test/commands/color_off_golden.txt';
  File(path).writeAsStringSync(await renderColorScenarios());
  stdout.writeln('wrote $path');
}
