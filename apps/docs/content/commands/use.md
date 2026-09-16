---
title: "fvm use"
description: "Pin a version for this project and create its IDE link."
---

## Usage

```sh
fvm use 3.44.0 --gitignore
fvm use stable --here
```

## Behavior

Missing SDKs are installed. The nearest existing project pin is updated unless `--here` is used. `--global` sets the fallback instead. Channel pins must have a local mapping; install the channel first.

## Options

```text
Pin a version for this project and write .fvmrc.

Usage: fvm use <version> [--global] [--here]
-h, --help         Print this usage information.
-g, --global       Set the machine-wide default instead of pinning this project.
    --here         Pin this directory itself, creating a .fvmrc here even when a parent directory already has one.
    --gitignore    Also add `.fvm/` to this project's .gitignore.

Run "fvm help" to see global options.
```
