---
title: "fvm setup"
description: "Make fvm and your project\u2019s flutter command available in the terminal."
---

## Configure your shell

On macOS or Linux:

```sh
fvm setup --write-path-line
```

Setup creates the Flutter launcher and adds the required PATH entries to your shell startup file, backing it up first. Open a new terminal afterward.

If `fvm` is not on PATH yet, use its full installed path. For the default macOS or Linux installation:

```sh
"$HOME/.fvm/bin/fvm" setup --write-path-line
```

## View instructions without editing your shell

```sh
fvm setup
```

This creates the launcher and prints the PATH instructions. On Windows, add the printed directories to your user PATH manually; PowerShell does not support `--write-path-line`.

## Remove an automatic PATH entry

```sh
fvm setup --remove-path-line
```

This removes the line added by setup, leaving your SDKs and manually added lines alone. Restart the terminal afterward.

If you move the FVM executable, run setup from its new location. `--fvm-path=<path>` lets you explicitly select the executable the launcher should use.

See [Shell Setup](/getting-started/shell-setup) to verify the result.
