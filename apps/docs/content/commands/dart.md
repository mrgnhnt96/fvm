---
title: "fvm dart"
description: "Run the Dart version included with your selected Flutter SDK."
---

## Run Dart commands

```sh
fvm dart --version
fvm dart analyze
fvm dart format .
fvm dart run tool/generate.dart
```

Run these from your project directory after selecting Flutter with [`fvm use`](/commands/use). This uses Flutter's bundled Dart even if a separate Dart SDK is on PATH.

## Get Dart help

```sh
fvm dart --help
```

All arguments after `fvm dart` go to Dart. Its exit status is returned unchanged.

For scripts that need to find both Flutter and Dart themselves, use [`fvm exec`](/commands/exec).
