/// Verifies that every link in `content/` points at something that exists.
///
/// The sidebar's links are already covered by `test/navigation_test.dart`,
/// which does not read page *bodies* — and that is where most of these docs'
/// links live. So the failure this catches is renaming a page, fixing the
/// sidebar entry because that test goes red, and leaving a dozen prose links
/// pointing at the old URL.
///
/// ```sh
/// dart run tool/check_links.dart
/// ```
///
/// Exits 1 and prints every bad link with its `file:line` so the whole list can
/// be fixed in one pass, rather than one failure at a time.
///
/// External URLs are counted but not fetched: the network would make this
/// non-deterministic and slow, and a link rotting on someone else's server is
/// not something a commit here can cause. Pass `--list-external` to review them.
library;

import 'dart:io';

void main(List<String> args) {
  final listExternal = args.contains('--list-external');

  final root = _docsRoot();
  final contentDir = Directory('${root.path}/content');

  final files =
      contentDir.listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.md')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  // Every page's anchors up front: a link in page A can target a heading in
  // page B, so no file can be judged until all of them have been read.
  final anchors = {
    for (final file in files) _routeFor(file.path, contentDir.path): _anchorsOf(file.readAsStringSync()),
  };

  final problems = <String>[];
  final external = <String>[];
  var checked = 0;

  for (final file in files) {
    final relative = _relative(file.path, root.path);
    final from = _routeFor(file.path, contentDir.path);

    for (final link in _linksIn(file.readAsStringSync())) {
      final target = link.target;

      if (target.startsWith('http://') || target.startsWith('https://')) {
        external.add('$relative:${link.line}  $target');
        continue;
      }
      if (target.startsWith('mailto:')) continue;

      checked++;
      final problem = _problemWith(target, from: from, anchors: anchors, root: root);
      if (problem != null) {
        problems.add('$relative:${link.line}  [${link.text}]($target)\n    -> $problem');
      }
    }
  }

  if (listExternal) {
    stdout.writeln('External links (not fetched):');
    for (final line in external) {
      stdout.writeln('  $line');
    }
    stdout.writeln('');
  }

  if (problems.isEmpty) {
    stdout.writeln('All $checked internal link(s) resolve. ${external.length} external link(s) skipped.');
    return;
  }

  stderr.writeln('${problems.length} broken link(s) in content/:\n');
  for (final problem in problems) {
    stderr.writeln('  $problem');
  }
  stderr.writeln('\nChecked $checked internal link(s) across ${files.length} page(s).');
  exit(1);
}

/// Why `target` does not resolve, or null when it does.
String? _problemWith(
  String target, {
  required String from,
  required Map<String, Set<String>> anchors,
  required Directory root,
}) {
  // `[text](#a-heading)` — same page.
  if (target.startsWith('#')) {
    final anchor = target.substring(1);
    if (anchors[from]!.contains(anchor)) return null;
    return 'no heading on this page with id "$anchor"';
  }

  // Site routes are absolute. A relative link would resolve differently
  // depending on whether the page is served with a trailing slash, so the
  // docs never use one and neither should a new page. The deployed site owns
  // its domain root, so an absolute route here is what the browser requests.
  if (!target.startsWith('/')) {
    return 'relative link — write it as an absolute site path (e.g. /commands/install)';
  }

  final hash = target.indexOf('#');
  final path = hash == -1 ? target : target.substring(0, hash);
  final anchor = hash == -1 ? null : target.substring(hash + 1);
  final route = _normalize(path);

  if (!anchors.containsKey(route)) {
    // Not a page — it may still be a real file served out of web/, like an image.
    if (File('${root.path}/web$path').existsSync()) return null;
    return 'no page at content${route == '/' ? '/index' : route}.md';
  }

  if (anchor != null && !anchors[route]!.contains(anchor)) {
    return 'page exists, but it has no heading with id "$anchor"';
  }
  return null;
}

/// `/recording/testing/` and `/recording/testing` are the same page.
///
/// The sitemap's canonical URLs carry a trailing slash (GitHub Pages 301s the
/// form without one) while body links are written without, so both forms are
/// live and both have to resolve here.
String _normalize(String path) {
  if (path == '/' || path.isEmpty) return '/';
  return path.endsWith('/') ? path.substring(0, path.length - 1) : path;
}

/// One `[text](target)` occurrence, with the 1-based line it sits on.
typedef _Link = ({String text, String target, int line});

/// Every markdown link in `body`, skipping anything inside a fenced code block.
///
/// Inline code spans are masked rather than removed so that a link whose *text*
/// is code — [`picto:setup`](#generating-one-interactively), which is how most
/// of these are written — still parses, while a `](/foo)` that only appears
/// inside backticks is not mistaken for a link.
List<_Link> _linksIn(String body) {
  final links = <_Link>[];
  final pattern = RegExp(r'!?\[([^\]]*)\]\(\s*([^)\s]+)(?:\s+"[^"]*")?\s*\)');
  final lines = body.split('\n');
  var inFence = false;

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.trimLeft().startsWith('```')) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;

    final masked = _maskCodeSpans(line);
    for (final match in pattern.allMatches(masked)) {
      // Read the link back out of the unmasked line: masking preserves length,
      // so the offsets line up. Reporting the masked form would print
      // [`xxxxxxx`] and make the bad link harder to find, not easier.
      final target = line.substring(match.start, match.end);
      final parsed = pattern.firstMatch(target);
      links.add((
        text: parsed?.group(1) ?? match.group(1)!,
        target: parsed?.group(2) ?? match.group(2)!,
        line: i + 1,
      ));
    }
  }

  return links;
}

/// Replaces the contents of inline code spans with `x`, keeping the length.
String _maskCodeSpans(String line) {
  final buffer = StringBuffer();
  var index = 0;
  while (index < line.length) {
    if (line[index] != '`') {
      buffer.write(line[index]);
      index++;
      continue;
    }
    var fence = 0;
    while (index + fence < line.length && line[index + fence] == '`') {
      fence++;
    }
    final open = '`' * fence;
    final close = line.indexOf(open, index + fence);
    if (close == -1) {
      buffer.write(open);
      index += fence;
      continue;
    }
    buffer
      ..write(open)
      ..write('x' * (close - index - fence))
      ..write(open);
    index = close + fence;
  }
  return buffer.toString();
}

/// The heading ids a page offers, for the `#fragment` half of a link.
///
/// Only `##`/`###` are collected because those are the only levels the site
/// renders an `id` on.
Set<String> _anchorsOf(String body) {
  final anchors = <String>{};
  var inFence = false;
  for (final line in body.split('\n')) {
    if (line.trimLeft().startsWith('```')) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    if (RegExp(r'^(#{2,3})\s+(.*)$').firstMatch(line) case final match?) {
      anchors.add(_anchorFor(match.group(2)!));
    }
  }
  return anchors;
}

/// Reproduces the heading id that `package:markdown` generates.
String _anchorFor(String rawHeading) =>
    rawHeading.toLowerCase().trim().replaceAll(RegExp('[^a-z0-9 _-]'), '').replaceAll(RegExp(r'\s'), '-');

/// `content/commands/install.md` -> `/commands/install`, `index.md` -> `/`.
String _routeFor(String path, String contentPath) {
  var relative = path.substring(contentPath.length).replaceAll(r'\', '/');
  relative = relative.replaceFirst(RegExp(r'^/'), '').replaceFirst(RegExp(r'\.md$'), '');
  if (relative == 'index') return '/';
  return '/$relative';
}

String _relative(String path, String rootPath) =>
    path.startsWith(rootPath) ? path.substring(rootPath.length).replaceFirst(RegExp(r'^/'), '') : path;

/// Resolves the `apps/docs` directory whether invoked from there or from the
/// workspace root.
Directory _docsRoot() {
  final cwd = Directory.current;
  if (File('${cwd.path}/content/index.md').existsSync()) return cwd;
  final nested = Directory('${cwd.path}/apps/docs');
  if (File('${nested.path}/content/index.md').existsSync()) return nested;
  stderr.writeln('Run this from apps/docs (or the workspace root).');
  exit(1);
}
