---
title: "fvm which"
description: "Print the selected SDK and explain which rule chose it."
---

## Usage

```sh
fvm which
fvm which --path
fvm current
```

## Behavior

Use `--path` for scripting. The normal output includes the version and the source of the selection. See [Resolution Order](/versions/resolution-order).

## Options

```text
Print the resolved SDK and which rule chose it. (alias: current)

Usage: fvm which [arguments]
-h, --help    Print this usage information.
    --path    Print only the path to the flutter executable, for scripting.

Run "fvm help" to see global options.
```
