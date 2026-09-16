/// The version this build of fvm reports, and whether it is a release build.
///
/// GENERATED-ISH: `tool/stamp_version.sh` rewrites [kVersion] during the
/// release build so the binary reports the tag it was published under. It is
/// committed rather than produced by a build step because ARCHITECTURE.md
/// rules out codegen — `dart run bin/fvm.dart` from a fresh checkout has to
/// work with nothing generated first.
///
/// The value here must match `version:` in `packages/fvm/pubspec.yaml`;
/// `test/release/version_stamp_test.dart` fails when they drift, and the
/// release build refuses a tag that disagrees with either.
library;

/// The version of this build of fvm.
const String kVersion = '0.0.2';

/// Whether this process is an AOT binary produced by the release build.
///
/// The release workflow passes `-D__FVM_COMPILED__=true` to `dart compile
/// exe`; nothing else does, so this is false under `dart test`, under `flutter
/// run`, and for a binary someone compiled by hand. Everything that replaces
/// the binary on disk or talks to the GitHub releases API is gated on it:
/// there is no installed binary to update when fvm is running from source,
/// and a version notice comparing a checkout against published releases would
/// be noise at best.
const bool kIsCompiled = bool.fromEnvironment('__FVM_COMPILED__');
