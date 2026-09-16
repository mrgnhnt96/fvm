---
title: "fvm alias"
description: "Give a version a name, or list saved names."
---

## Usage

```sh
fvm alias work 3.44.0
fvm alias list
```

## Behavior

Aliases live in the machine-local config. They may target versions, channels, or other aliases. Concrete pins are easier to share with teammates.

## Options

```text
Give a version a name, or list the names you have.

Usage: fvm alias <name> <version> | alias list
-h, --help    Print this usage information.

Run "fvm help" to see global options.
```
