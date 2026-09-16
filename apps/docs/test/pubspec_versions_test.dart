/// Guards the one pubspec constraint that cannot be expressed as a constraint.
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('jaspr and jaspr_builder are pinned to matching versions >= 0.23.2', () {
    // jaspr_builder pins its own jaspr dependency to an exact version per
    // release, so a caret range on either one can resolve to a pair that does
    // not build — and nothing catches it early: `dart analyze` only type-checks
    // this package's own code, and the break surfaces when dart2js
    // whole-program compiles the real client entrypoint.
    //
    // The floor is jaspr_router 0.8.3's fault: it calls `AppBinding.basePath`,
    // which first exists in jaspr 0.23.2, and its own `jaspr: ^0.23.0`
    // constraint does not say so.
    final pubspec = File('pubspec.yaml').readAsStringSync();

    final jaspr = RegExp(r'^\s*jaspr:\s*([\d.]+)\s*$', multiLine: true).firstMatch(pubspec);
    final builder = RegExp(r'^\s*jaspr_builder:\s*([\d.]+)\s*$', multiLine: true).firstMatch(pubspec);

    expect(jaspr, isNotNull, reason: 'jaspr must be pinned to an exact version');
    expect(builder, isNotNull, reason: 'jaspr_builder must be pinned to an exact version');

    expect(
      jaspr!.group(1),
      builder!.group(1),
      reason: 'jaspr_builder pins its jaspr dependency to an exact matching version — these move in lockstep',
    );
    expect(
      _atLeast(jaspr.group(1)!, const [0, 23, 2]),
      isTrue,
      reason: '${jaspr.group(1)} is older than 0.23.2, which is missing AppBinding.basePath',
    );
  });

  test('the docs app is a member of the workspace', () {
    // A workspace member cannot resolve on its own — `dart pub get` inside
    // apps/docs fails outright — so the deploy workflow resolves from the repo
    // root. That only works if the root lists this app.
    expect(File('../../pubspec.yaml').readAsStringSync(), contains('- apps/docs'));
    expect(File('pubspec.yaml').readAsStringSync(), contains('resolution: workspace'));
  });
}

bool _atLeast(String version, List<int> floor) {
  final parts = version.split('.').map(int.parse).toList();
  for (var i = 0; i < floor.length; i++) {
    final part = i < parts.length ? parts[i] : 0;
    if (part != floor[i]) return part > floor[i];
  }
  return true;
}
