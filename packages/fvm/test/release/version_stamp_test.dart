import 'dart:io';

import 'package:fvm/fvm.dart';
import 'package:test/test.dart';

/// The version this build reports has to be the one the release is cut at.
///
/// Three files carry it and all three have to agree: `pubspec.yaml`'s
/// `version:`, `kVersion` in `lib/src/gen/version.dart`, and the `v*` tag the
/// release workflow runs on. The workflow refuses a tag that disagrees with
/// the pubspec (`tool/stamp_version.sh`); this test catches the same drift on
/// a laptop, before anyone tags anything.
void main() {
  test('kVersion matches the version in pubspec.yaml', () {
    // `dart test` runs with the package root as the working directory.
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match =
        RegExp(r'^version:\s*(\S+)\s*$', multiLine: true).firstMatch(pubspec);

    expect(match, isNotNull, reason: 'pubspec.yaml has no version:');
    expect(
      kVersion,
      match!.group(1),
      reason: 'lib/src/gen/version.dart and pubspec.yaml disagree. '
          'Change both, or let tool/stamp_version.sh do it.',
    );
  });

  test('the CLI reports kVersion', () {
    expect(version(), kVersion);
  });
}
