---
title: "fvm global"
description: "Set the fallback used outside pinned projects."
---

## Usage

```sh
fvm global 3.44.0
```

## Behavior

A project pin and `FVM_FLUTTER_VERSION` both take precedence. The command installs a missing SDK. For channels, install the channel first to record its version.

## Options

```text
Set the version used when no .fvmrc applies.

Usage: fvm global <version>
-h, --help    Print this usage information.

Run "fvm help" to see global options.
```
