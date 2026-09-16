---
title: "fvm list-remote"
description: "List Flutter releases published for this host."
---

## Usage

```sh
fvm list-remote
fvm list-remote --channel beta --all
```

## Behavior

The default is the newest 25 stable releases. Results are sorted semantically and filtered for the host architecture. `--all` shows the full list.

## Options

```text
List the releases available from the Flutter archive.

Usage: fvm list-remote [arguments]
-h, --help       Print this usage information.
-c, --channel    Which release channel to list.
                 [stable (default), beta, dev]
    --all        Show every release instead of the newest 25.

Run "fvm help" to see global options.
```
