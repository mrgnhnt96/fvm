---
title: "The Shim and Your PATH"
description: "Make plain flutter use the SDK pinned by the current directory."
---

## Create the shim

```sh
fvm setup
```

Setup writes `~/.fvm/shims/flutter`, or `flutter.bat` on Windows. The shim calls the absolute FVM binary path with `exec flutter`, preserving your arguments and exit status.

Plain setup prints instructions without changing startup files. To write the PATH line:

```sh
fvm setup --write-path-line
```

The compiled CLI also creates a missing shim after `install`, `use`, or `global` makes an SDK available. Automatic setup prints instructions but does not edit shell startup files.

## PATH order

The shims directory must precede other Flutter installations. Setup prints a line appropriate for your shell, typically:

```sh
export PATH="$HOME/.fvm/bin:$HOME/.fvm/shims:$PATH"
```

Restart your shell. `fvm doctor` checks PATH order and identifies earlier entries that win. A later `export PATH=...` that discards the old PATH can undo your setup.

## Dart and DVM

No Dart shim is installed. Plain `dart` keeps its existing meaning. Use `fvm dart` or `fvm exec dart` to select Flutter's bundled Dart. See [Using FVM alongside DVM](/guides/dvm).

## Move or remove setup

If you move the FVM executable, run setup again so the shim names its new path. `fvm setup --remove-path-line` removes the managed PATH line. Run `fvm setup --help` for backup and shell-file options.
