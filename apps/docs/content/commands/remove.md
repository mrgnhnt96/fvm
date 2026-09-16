---
title: "fvm remove"
description: "Remove an SDK from the shared cache."
---

## Usage

```sh
fvm remove 3.44.0
```

## Behavior

Removal refuses references it can detect unless `--force` is used. FVM cannot discover every project elsewhere on disk, so check your projects before removing a shared SDK.

## Options

```text
Delete an installed SDK.

Usage: fvm remove <version> [--force]
-h, --help     Print this usage information.
-f, --force    Remove it even if something still points at it.

Run "fvm help" to see global options.
```
