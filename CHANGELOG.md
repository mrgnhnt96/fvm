# Changelog

## 0.0.3

- Add `fvm migrate` to move from leoafarias/fvm: migrates the current project, every project it tracked, and its global version, then offers to uninstall it. Supports `--dry-run` and `--[no-]uninstall`.
- `fvm setup` detects leoafarias/fvm and offers to migrate.
- Document using plain `flutter` through the shim, and how this FVM differs from leoafarias/fvm.
- Consolidate the documentation into six guides with flat navigation.

## 0.0.2

- Highlight installer success messages, warnings, headings, and commands with terminal colors.
- Shorten post-install guidance and place PATH instructions and the recommended setup command at the bottom.
- Keep redirected output and `NO_COLOR` output free of ANSI escape sequences.
- Add a distinct FVM logo and favicon to the documentation.

## 0.0.1

First public release.

- Install and share Flutter SDKs in a central cache, with SHA-256 verification.
- Pin projects with `.fvmrc` and an IDE link at `.fvm/flutter_sdk`.
- Select SDKs using environment overrides, project pins, aliases, or a global default.
- Run Flutter and its bundled Dart, or forward commands with `fvm exec`.
- Set up a Flutter PATH shim alongside DVM and inspect configuration with `fvm doctor`.
- Install standalone binaries on macOS (arm64/x64), Linux (arm64/x64), and Windows (x64).
- Browse searchable documentation at https://fvm.mrgnhnt.com.
