# Architecture

`packages/fvm/bin/fvm.dart` is a thin entrypoint. `lib/fvm.dart` wires the
command runner and injectable filesystem, environment, release client,
installer, process runner, and updater. Commands live under `lib/src/commands`.

The implementation is adapted from the sibling DVM repository. Shared behavior
includes aliases, five-rule SDK resolution, project links, shell setup and
diagnostics, color/verbose output, subprocess exit/signal forwarding, and binary
updates. Flutter-specific behavior lives in the manifest client, extractor,
launcher paths, and bundled Dart command. There is no code generation step.

## SDK selection and execution

`core/resolver.dart` has no network dependencies. It reads `FVM_FLUTTER_VERSION`,
the nearest `.fvmrc`, and global config before considering Flutter on PATH.
Channel pins read mappings saved by installation. Missing or malformed explicit
pins fail rather than silently selecting a different SDK.

`core/paths.dart` owns storage layout. `.fvm/flutter_sdk` links to the complete
Flutter SDK. `core/runner.dart` prefixes the selected SDK's bin directory and
propagates the concrete version to nested FVM invocations. `fvm dart` invokes
that SDK's bin/dart (bin/dart.bat on Windows).

## Releases and installation

`archive/flutter_archive_client.dart` reads the official releases_<os>.json
manifest, filters by dart_sdk_arch (missing means x64), and selects archive URLs
and SHA-256 digests from matching records. A manifest is cached only within that
client invocation. No guessed download filenames are used in production.

Downloads are streamed and hashed. Extraction uses file-backed ZIP and TAR
streams for real files; XZ is decompressed into a temporary TAR. Permissions
are applied before publishing, and relative symbolic links are created last.
Escaping archive entries cannot write outside the extraction root. SDKs are
prepared in a unique cache directory and renamed into versions/<version>.
Scratch data is cleaned on failure. Force reinstall replaces an existing SDK
after successful extraction; there is no interprocess install lock.

## Distribution

The package is not published to pub.dev. GitHub Releases and install.sh are the
distribution channel. Version stamping checks the tag against pubspec.yaml.
Release binaries opt into self-update via __FVM_COMPILED__; source invocations
and ordinary local builds do not perform ambient update checks.

## Tests

Inherited DVM tests cover shared behavior. Flutter-specific tests cover release
manifest selection, missing architectures, checksum validation, bundled Dart,
tar.xz extraction, and symbolic links. Real subprocess tests cover exit codes,
arguments, working directories, environment, and signal forwarding.
