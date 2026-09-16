---
title: "fvm setup"
description: "Create the Flutter shim and configure shell integration."
---

## Usage

```sh
fvm setup
fvm setup --write-path-line
```

## Behavior

Plain setup prints instructions. `--write-path-line` edits the appropriate startup file with a backup. The shim records the FVM binary’s absolute path. See [The Shim and Your PATH](/getting-started/shell-setup).

## Options

```text
Install the shims and print the PATH line to add.

Usage: fvm setup [arguments]
-h, --help                Print this usage information.
    --fvm-path=<path>     The fvm binary to bake into the shim. Defaults to the running one; needed when running from source.
    --write-path-line     Add the PATH line to your shell startup file instead of just printing it. Backs the file up first, and does nothing if the line is already there. Not available for PowerShell, which takes PATH from your environment rather than a startup file.
    --remove-path-line    Take the PATH line --write-path-line added back out, leaving the shims in place. A line you added by hand is left alone.

Run "fvm help" to see global options.
```
