---
title: "fvm exec"
description: "Run a tool or script with your selected Flutter and Dart on PATH."
---

## Run a command

```sh
fvm exec dart analyze
fvm exec flutter test
```

The command and any tools it starts find your selected Flutter SDK's `flutter` and `dart` first on PATH. Your terminal's PATH is unchanged after it finishes.

## Run a script

For a shell script that calls Flutter or Dart:

```sh
fvm exec sh tool/check.sh
```

Replace the script path with your own. All arguments after `fvm exec` belong to the command being run, including `--help`. FVM returns that command's exit status.

Choose an SDK with [`fvm use`](/commands/use) before running the command.
