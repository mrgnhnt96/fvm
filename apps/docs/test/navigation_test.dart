/// Structural checks on the sidebar's information architecture.
///
/// The sidebar is generated from `lib/src/navigation.dart`, and this file is
/// what makes that generation trustworthy: without the second test here, adding
/// a page under `content/` and forgetting to list it fails nothing at all — the
/// page builds, renders, and is reachable by nobody.
library;

import 'dart:io';

import 'package:fvm_docs/src/navigation.dart';
import 'package:test/test.dart';

void main() {
  test('every link points at a page that exists', () {
    final missing = [
      for (final item in flatNavigation)
        if (!File('content${item.href == '/' ? '/index' : item.href}.md').existsSync()) item.href,
    ];
    expect(missing, isEmpty);
  });

  test('every page is reachable from the sidebar', () {
    final linked = {for (final item in flatNavigation) item.href};
    final orphans = <String>[];

    for (final file in Directory('content').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.md')) continue;
      var route = file.path.substring('content'.length).replaceFirst(RegExp(r'\.md$'), '');
      if (route == '/index') route = '/';
      if (!linked.contains(route) && !unlistedRoutes.contains(route)) orphans.add(route);
    }

    expect(orphans, isEmpty, reason: 'add these to lib/src/navigation.dart or unlistedRoutes');
  });

  test('no page is listed twice', () {
    final seen = <String>{};
    final duplicates = [
      for (final item in flatNavigation)
        if (!seen.add(item.href)) item.href,
    ];
    expect(duplicates, isEmpty);
  });

  test('groups are non-empty, titled and iconed', () {
    for (final group in navigation) {
      expect(group.items, isNotEmpty, reason: group.title);
      expect(group.title.trim(), isNotEmpty);
      expect(group.icon, startsWith('<svg'), reason: group.title);
    }
  });

  test('prev/next spans the whole reading order exactly once', () {
    final flat = flatNavigation;
    expect(neighborsOf(flat.first.href).previous, isNull);
    expect(neighborsOf(flat.last.href).next, isNull);

    // Walking `next` from the first page must visit every page, in order.
    final walked = <String>[flat.first.href];
    var current = neighborsOf(flat.first.href).next;
    while (current != null) {
      walked.add(current.href);
      current = neighborsOf(current.href).next;
    }
    expect(walked, flat.map((item) => item.href).toList());
  });

  test('groupFor and itemFor agree with the table', () {
    for (final group in navigation) {
      for (final item in group.items) {
        expect(groupFor(item.href), same(group), reason: item.href);
        expect(itemFor(item.href), same(item), reason: item.href);
      }
    }
    expect(groupFor('/nothing-here'), isNull);
    expect(itemFor('/nothing-here'), isNull);
  });

  // ARCHITECTURE.md is the contract the CLI is written against, and this site
  // documents that contract. A command that exists and has no reference section is a hole in
  // the docs that nothing else would report.
  test('every command registered by the CLI has a reference section', () {
    final commands = RegExp(
      r'addCommand\((\w+)Command\(',
    ).allMatches(File('../../packages/fvm/lib/fvm.dart').readAsStringSync()).map((match) => match.group(1)!).toList();

    expect(commands, isNotEmpty, reason: 'found no addCommand() calls — did lib/fvm.dart move?');

    final reference = File('content/commands.md').readAsStringSync();
    final documented = RegExp(
      r'^## fvm (.+)$',
      multiLine: true,
    ).allMatches(reference).map((match) => match.group(1)!).toSet();
    final undocumented = [
      for (final command in commands)
        if (!documented.contains(_routeName(command))) command,
    ];

    expect(undocumented, isEmpty, reason: 'these commands have no section in content/commands.md');
  });
}

/// `ListRemote` -> `list-remote`, `Install` -> `install`.
String _routeName(String className) =>
    className.replaceAllMapped(RegExp('(?<=.)([A-Z])'), (m) => '-${m.group(1)}').toLowerCase();
