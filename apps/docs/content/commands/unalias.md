---
title: "fvm unalias"
description: "Remove a saved alias."
---

## Usage

```sh
fvm unalias work
```

## Behavior

Removing an alias does not delete its SDK. Project pins that name the alias need to be changed or the alias recreated.

## Options

```text
Remove a named version.

Usage: fvm unalias <name>
-h, --help    Print this usage information.

Run "fvm help" to see global options.
```
