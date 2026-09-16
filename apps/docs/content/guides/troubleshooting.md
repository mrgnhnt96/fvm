---
title: "Troubleshooting"
description: "Find why Flutter selected the wrong SDK or failed to start."
---

## Start with the explanation

```sh
fvm which
fvm doctor
fvm --verbose flutter --version
```

## The wrong Flutter runs

Check for `FVM_FLUTTER_VERSION`, a parent `.fvmrc`, or a global default. If `fvm flutter` is correct but plain `flutter` is not, the shim is missing or a different PATH entry wins. Run setup and restart the shell.

## The selected SDK is missing

Run the installation command printed in the error. Explicit missing pins do not fall back silently. A channel needs a recorded mapping from `fvm install stable` or `fvm install beta`.

## Download or checksum failure

Check connectivity to Google's Flutter release storage, then retry. A checksum mismatch prevents extraction. A release unavailable for the host architecture is reported rather than replaced with another architecture.

## The editor uses another SDK

Run `fvm use <version>` to refresh `.fvm/flutter_sdk`, then configure the editor to use that Flutter SDK directory. On Windows, creating links can require Developer Mode or elevated privileges.

## Setup says this is a source invocation

Compile the CLI before setup. A shim needs the standalone FVM executable, not the Dart VM running a source file. See [Installation](/getting-started/installation).

## Dart differs from Flutter's Dart

That is expected when DVM or another standalone Dart is on PATH. Use `fvm dart` when you need the runtime bundled with Flutter.
