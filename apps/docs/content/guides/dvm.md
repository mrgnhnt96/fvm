---
title: "Using FVM alongside DVM"
description: "Choose the right Dart command when you also use standalone Dart."
---

## Use Flutter's Dart for Flutter projects

```sh
fvm flutter --version
fvm dart --version
fvm dart analyze
```

`fvm dart` uses the Dart included with your selected Flutter SDK. Plain `dart` continues to use your existing Dart setup, including DVM if you have installed it.

For a script that calls both tools, run it with `fvm exec` so it finds the selected Flutter SDK's Flutter and Dart commands.

## Configure a Flutter project

Use `.fvmrc` to select Flutter and set the editor's Flutter SDK path to `.fvm/flutter_sdk`. A `.dvmrc` selects standalone Dart; it does not select Flutter.

FVM's shell setup adds a `flutter` launcher. It can coexist with DVM's `dart` launcher. See [Shell Setup](/getting-started/shell-setup).

## If you already have another FVM installed

These instructions are for `mrgnhnt96/fvm`, which is separate from the pub.dev package named `fvm`. Use the [installation instructions](/getting-started/installation) here.

Choose which `fvm` executable your PATH should use. If you keep both managers, give this one a separate `FVM_HOME`. Existing SDK caches are not imported; install the versions you need with `fvm install`.

If commands reach the wrong manager, follow [Troubleshooting](/guides/troubleshooting).
