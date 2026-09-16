/// Builds `web/search-index.json`, the payload behind the docs site's ⌘K search.
///
/// The site is statically generated and served from GitHub Pages, so there is
/// no backend to answer a query. Instead this walks `content/`, splits each
/// page on its headings, and emits one searchable record per section.
/// `SearchDialog` — rendered in the header by `lib/main.server.dart` — fetches
/// the result on first use and scores it in the browser.
///
/// Run it before `jaspr build` / `jaspr serve`:
///
/// ```sh
/// dart run tool/build_search_index.dart
/// ```
///
/// Pass `--check` to verify the committed index is current without writing it.
/// That is what `test/search_index_test.dart` runs, so a content change that
/// forgot to regenerate the index fails the suite rather than shipping a search
/// box that cannot find the page you just wrote.
///
/// This exists rather than `dart run jaspr_search`, the package's bundled CLI,
/// for one reason: the CLI cannot express `groupFor`, `titleFor` and `compare`.
/// Those reach into `lib/src/navigation.dart` — they are what puts "Command
/// Reference" above a result and what makes reading order break ranking ties —
/// and a Dart closure is not something a command-line flag can carry.
library;

import 'dart:io';

import 'package:fvm_docs/src/navigation.dart';
import 'package:jaspr_search/builder.dart';

Future<void> main(List<String> args) async {
  final check = args.contains('--check');

  final root = _docsRoot();
  final output = File('${root.path}/web/search-index.json');

  // Reading order, so that — all else equal in the ranking — a page earlier in
  // the sidebar wins a tie. `Installation` beating `Troubleshooting` for a
  // query both pages answer is the reading order doing its job.
  final order = {for (final (index, item) in flatNavigation.indexed) item.href: index};

  final SearchIndexBuild build;
  try {
    build = await buildSearchIndex(
      Directory('${root.path}/content'),
      groupFor: (route) => groupFor(route)?.title ?? '',
      // The page's own front-matter title, not the sidebar label: labels are
      // shortened to fit a ~17rem column, and a search result should say what
      // the page says.
      titleFor: (route, frontMatter) => frontMatter['title'] ?? itemFor(route)?.title ?? route,
      // The sidebar summary first — it is written to describe the page in one
      // line, which is exactly what a result row wants.
      descriptionFor: (route, frontMatter) => itemFor(route)?.summary ?? frontMatter['description'] ?? '',
      compare: (a, b) => (order[a.url] ?? order.length).compareTo(order[b.url] ?? order.length),
    );
  } on ContentDirectoryNotFoundException catch (error) {
    stderr.writeln(error);
    exit(1);
  }

  if (check) {
    if (!searchIndexIsCurrent(build, output)) {
      stderr.writeln('web/search-index.json is stale. Run: dart run tool/build_search_index.dart');
      exit(1);
    }
    stdout.writeln('Search index is up to date (${build.docs.length} pages).');
    return;
  }

  writeSearchIndex(build, output);
  stdout.writeln(
    'Wrote ${output.path} — ${build.docs.length} pages, ${build.sectionCount} sections, '
    '${(build.json.length / 1024).toStringAsFixed(1)} KB.',
  );
}

/// Resolves the `apps/docs` directory whether invoked from there or from the
/// workspace root.
///
/// Both spellings happen: the tests run from `apps/docs`, and a person fixing a
/// stale index is usually standing at the repo root where `dart pub get` works.
Directory _docsRoot() {
  final cwd = Directory.current;
  if (File('${cwd.path}/content/index.md').existsSync()) return cwd;
  final nested = Directory('${cwd.path}/apps/docs');
  if (File('${nested.path}/content/index.md').existsSync()) return nested;
  stderr.writeln('Run this from apps/docs (or the workspace root).');
  exit(1);
}
