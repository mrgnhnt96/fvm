---
title: "fvm dart"
description: "Run Dart bundled with the selected Flutter SDK."
---

## Usage

```sh
fvm dart --version
fvm dart run tool/generate.dart
```

## Behavior

This uses the selected Flutter SDK’s `bin/dart` launcher (`dart.bat` on Windows), independently of any DVM-managed Dart on PATH. Arguments, exit status, and signals are forwarded.
