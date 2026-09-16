/// Guards every link written in the body of a page under `content/`.
///
/// The failure this catches is a rename. `test/navigation_test.dart` checks the
/// sidebar table, so moving a page turns that red and gets the *structure*
/// fixed — while the prose links pointing at the old URL stay green and rot.
///
/// Nothing about the deployed site looks wrong either. The page builds, renders
/// and is served; the link just 404s when a reader clicks it.
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('content links', () {
    test('every link in content/ resolves', () {
      final result = Process.runSync('dart', ['run', 'tool/check_links.dart']);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    });

    // The checker is only as good as its ability to say no, and the cheapest
    // way for it to stop saying no is to stop finding links at all — a regex
    // that matches nothing reports "all 0 links resolve" and passes forever.
    test('the checker is actually reading links, not finding none', () {
      final result = Process.runSync('dart', ['run', 'tool/check_links.dart']);
      final reported = RegExp(r'All (\d+) internal link').firstMatch('${result.stdout}');

      // A broken link belongs to the test above; failing here too would print
      // two errors for one cause and bury the one that names the bad link.
      if (result.exitCode != 0) return;
      expect(reported, isNotNull, reason: 'unexpected output: ${result.stdout}');

      // Counted independently of the tool, so this cannot agree with it by
      // sharing its bug: a floor, not the exact number, because the grep here
      // is deliberately dumber than the real parser.
      final written = Directory('content')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.md'))
          .fold(0, (total, file) => total + RegExp(r'\]\(/').allMatches(file.readAsStringSync()).length);

      expect(int.parse(reported!.group(1)!), greaterThanOrEqualTo(written));
    });

    // Every page's URL and its sidebar entry come from its path under
    // `content/`, so front matter is the only place a title can go missing —
    // and a page with no title renders with no `<h1>` and no breadcrumb.
    test('every page has front matter with a title and a description', () {
      final incomplete = <String>[];

      for (final file in Directory('content').listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.md')) continue;
        final head = file.readAsStringSync().split('\n---').first;
        if (!head.startsWith('---\n')) {
          incomplete.add('${file.path}: no front matter');
          continue;
        }
        if (!head.contains(RegExp(r'^title:\s*\S', multiLine: true))) incomplete.add('${file.path}: no title');
        if (!head.contains(RegExp(r'^description:\s*\S', multiLine: true))) {
          incomplete.add('${file.path}: no description');
        }
      }

      expect(incomplete, isEmpty);
    });
  });
}
