---
title: "fvm config"
description: "Read or save FVM output preferences."
---

## Usage

```sh
fvm config color
fvm config color always
fvm config color auto
```

## Behavior

Color modes are `auto`, `always`, and `never`. A top-level `--color` flag overrides the saved preference for one command. Auto respects `NO_COLOR` and `TERM=dumb`. Child tool output is not changed.

## Options

```text
Read or save preferences (color: auto, always, never).

Usage: fvm config color [auto|always|never]
-h, --help    Print this usage information.

Run "fvm help" to see global options.
```
