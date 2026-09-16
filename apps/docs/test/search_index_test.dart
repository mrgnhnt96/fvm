/// Exercises the committed search index and the ranking that reads it.
///
/// These run against the real `web/search-index.json`, so a content change that
/// breaks search — a stale index, a heading anchor that no longer resolves, a
/// query that stops finding its page — fails here rather than in a browser.
///
/// The scoring itself belongs to `package:jaspr_search` and is tested there.
/// What is site-specific, and therefore tested here, is whether *this* content
/// and *this* reading order produce the answers a fvm reader expects.
library;

import 'dart:convert';
import 'dart:io';

import 'package:fvm_docs/src/navigation.dart';
import 'package:jaspr_search/jaspr_search.dart';
import 'package:test/test.dart';

void main() {
  final indexFile = File('web/search-index.json');

  late List<SearchDoc> index;

  setUpAll(() {
    expect(indexFile.existsSync(), isTrue, reason: 'Run: dart run tool/build_search_index.dart');
    final payload = jsonDecode(indexFile.readAsStringSync()) as Map<String, Object?>;
    index = [for (final doc in payload['docs']! as List) SearchDoc.fromJson(doc as Map<String, Object?>)];
  });

  group('index contents', () {
    test('is current with content/', () {
      // The index is a COMMITTED artifact generated from `content/`, so it can
      // go stale in exactly one way: someone edits a page and does not rerun
      // the builder. Nothing else notices — the site builds, the page renders,
      // and search quietly answers from the old text.
      final result = Process.runSync('dart', ['run', 'tool/build_search_index.dart', '--check']);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    });

    test('covers every page in the sidebar', () {
      final indexed = {for (final doc in index) doc.url};
      final linked = {for (final item in flatNavigation) item.href};
      expect(linked.difference(indexed), isEmpty, reason: 'these pages are reachable but not searchable');
    });

    test('labels results with the group they live in', () {
      // The group is what puts "Command Reference" above a result row, and it
      // comes from `navigation.dart` rather than from the markdown — so it is
      // the one field that silently empties if the wiring is dropped.
      final install = index.firstWhere((doc) => doc.url == '/commands/install');
      expect(install.group, 'Command Reference');
      expect(index.firstWhere((doc) => doc.url == '/getting-started/installation').group, 'Get Started');
    });

    test('every page contributes at least one searchable section', () {
      expect(index.where((doc) => doc.sections.isEmpty).map((doc) => doc.url), isEmpty);
    });

    test('keeps the identifiers people actually paste into the box', () {
      // Markdown stripping must not eat dots, underscores or leading dots out
      // of the names this project is made of: a naive `replaceAll(RegExp(r'[`*_#]'), '')`
      // turns `.fvmrc` into `fvmrc` and `FVM_HOME` into `FVMHOME`, which are
      // exactly the strings someone would search for.
      final bodies = index.expand((doc) => doc.sections).map((section) => section.body).join(' ');
      expect(bodies, contains('.fvmrc'));
      expect(bodies, contains('FVM_HOME'));
      expect(bodies, contains('fvm list-remote'));
    });
  });

  group('ranking', () {
    /// The url of the top hit for [query], without its anchor.
    String top(String query) {
      final hits = searchIndex(index, query);
      expect(hits, isNotEmpty, reason: 'no hits for "$query"');
      return hits.first.href.split('#').first;
    }

    test('finds each page by the words its own readers would use', () {
      expect(top('installation'), '/getting-started/installation');
      expect(top('install script'), '/getting-started/installation');
      expect(top('install fvm'), '/getting-started/installation');
      expect(top('quick start'), '/getting-started/quick-start');
      expect(top('resolution order'), '/versions/resolution-order');
      expect(top('troubleshooting'), '/guides/troubleshooting');
    });

    test('finds a command page by the command', () {
      expect(top('fvm doctor'), '/commands/doctor');
      expect(top('list-remote'), '/commands/list-remote');
      expect(top('fvm install --force'), '/commands/install');
    });

    test('finds a page by an identifier rather than prose', () {
      // `.fvmrc` is the file this whole project is organised around, and it is
      // mentioned on most pages — so this also checks that the page ABOUT it
      // beats the pages that merely use it.
      expect(top('.fvmrc'), '/versions/fvmrc');
    });

    test('requires every token to match', () {
      // "install" matches nearly every page and "kubernetes" matches none, so
      // the conjunction must be empty rather than falling back to either term.
      expect(searchIndex(index, 'install kubernetes'), isEmpty);
    });

    test('returns no hits for an empty query', () {
      expect(searchIndex(index, ''), isEmpty);
      expect(searchIndex(index, '   '), isEmpty);
    });

    test('deep-links to a heading when the match is inside a section', () {
      final anchored = searchIndex(index, 'shim').where((hit) => hit.href.contains('#'));
      expect(anchored, isNotEmpty, reason: 'no result deep-links to a heading');
      expect(anchored.first.heading, isNotNull);
    });
  });

  group('anchors', () {
    // `jaspr_search` reproduces `package:markdown`'s heading-id hashing by
    // hand, so it is checked against the HTML this site actually renders
    // rather than against the rule it was written from. A drift here means
    // search results deep-link to nothing — which looks, in a browser, exactly
    // like a working result that scrolls to the top of the page.
    final buildDir = Directory('build/jaspr');

    test('resolve to a real id in the built HTML', () {
      if (!buildDir.existsSync()) {
        markTestSkipped('No build/jaspr — run: dart run jaspr_cli:jaspr build');
        return;
      }

      final missing = <String>[];
      for (final doc in index) {
        final page = doc.url == '/'
            ? File('${buildDir.path}/index.html')
            : File('${buildDir.path}${doc.url}/index.html');
        if (!page.existsSync()) {
          missing.add('${doc.url} (no rendered page)');
          continue;
        }
        final html = page.readAsStringSync();
        for (final section in doc.sections) {
          if (section.anchor case final anchor?) {
            if (!html.contains('id="$anchor"')) missing.add('${doc.url}#$anchor');
          }
        }
      }

      expect(missing, isEmpty, reason: 'search results would deep-link to nothing');
    });
  });
}
