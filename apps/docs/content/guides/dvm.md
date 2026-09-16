---
title: "Using FVM alongside DVM"
description: "Keep standalone Dart and Flutter SDK selection independent."
---

## Two managers, two shims

DVM owns a `dart` shim under `~/.dvm/shims`. FVM owns a `flutter` shim under `~/.fvm/shims`. Both can be on PATH because their launcher names differ.

```sh
dvm dart --version
fvm flutter --version
fvm dart --version
```

Plain `dart` follows your DVM setup. `fvm dart` always uses Dart bundled with the selected Flutter SDK. Within `fvm exec`, the Flutter SDK bin directory comes first, so child processes use its Dart launcher too.

## Pins and IDEs

`.dvmrc` selects standalone Dart. `.fvmrc` selects Flutter. A Flutter project's editor should point to `.fvm/flutter_sdk`.

## Existing FVM installations

This project is independent from the pub.dev FVM package. It does not import another manager's cache or configuration. Keep caches separate with `FVM_HOME` if needed, and use `fvm doctor` to identify command or PATH conflicts. Avoid placing two different executables named `fvm` on PATH without choosing which should win.
