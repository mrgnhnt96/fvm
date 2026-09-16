import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

/// ARCHITECTURE.md: version resolution "must perform ZERO network I/O", because
/// the PATH shim pays for it on every `flutter` invocation on the machine.
///
/// A unit test cannot prove an absence of network calls — it can only show that
/// the calls it happened to exercise made none. So this asserts the stronger,
/// checkable property instead: no HTTP client is *reachable* from
/// `resolver.dart` at all. Walking the import graph is what makes a future
/// `import 'releases.dart'` in the resolver fail here rather than in
/// production, months later, on someone's cold shell prompt.
void main() {
  test('nothing reachable from resolver.dart can make a network call',
      () async {
    final closure = await _importClosure('package:fvm/src/core/resolver.dart');

    // The walk itself has to be shown to have worked: an empty or one-file
    // closure would pass every assertion below while having looked at nothing.
    expect(
      closure.keys,
      containsAll([
        'package:fvm/src/core/resolver.dart',
        'package:fvm/src/core/config.dart',
        'package:fvm/src/core/paths.dart',
        'package:fvm/src/core/channel.dart',
        'package:fvm/src/core/exceptions.dart',
      ]),
      reason: 'the import walk did not reach the files it should have',
    );

    for (final entry in closure.entries) {
      expect(
        entry.value,
        isNot(contains('package:http')),
        reason: '${entry.key} can reach an HTTP client',
      );
      expect(
        entry.value,
        isNot(contains('HttpClient')),
        reason: '${entry.key} can reach an HTTP client',
      );
      expect(
        entry.value,
        isNot(contains("import 'dart:io'")),
        reason: '${entry.key} imports dart:io, which reaches HttpClient',
      );
    }

    // releases.dart is the one seam allowed to talk to the archive. It must
    // stay out of this graph.
    expect(
      closure.keys,
      isNot(contains('package:fvm/src/core/releases.dart')),
      reason: 'the resolver can reach the release client',
    );
  });
}

/// Every library reachable from [entry] by relative import, as uri -> source.
Future<Map<String, String>> _importClosure(String entry) async {
  final sources = <String, String>{};
  final queue = <String>[entry];

  while (queue.isNotEmpty) {
    final uri = queue.removeLast();
    if (sources.containsKey(uri)) continue;

    final resolved = await Isolate.resolvePackageUri(Uri.parse(uri));
    if (resolved == null) fail('could not resolve $uri');
    final file = File.fromUri(resolved);
    if (!file.existsSync()) fail('$uri resolved to a missing file: $resolved');

    final source = file.readAsStringSync();
    sources[uri] = source;

    final directory = Uri.parse(uri).resolve('.');
    for (final match in RegExp(
      r'''^\s*(?:import|export)\s+'([^']+)';''',
      multiLine: true,
    ).allMatches(source)) {
      final target = match.group(1)!;
      if (target.startsWith('dart:') || target.startsWith('package:')) continue;
      queue.add(directory.resolve(target).toString());
    }
  }
  return sources;
}
