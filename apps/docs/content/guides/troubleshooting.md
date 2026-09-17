---
title: "Troubleshooting"
description: "Fix missing commands, incorrect Flutter versions, and editor setup."
---

## The fvm command is not found

With the default macOS or Linux installation, run:

```sh
"$HOME/.fvm/bin/fvm" setup --write-path-line
```

Open a new terminal and run `fvm --version`. For a custom installation, use the executable path printed by the installer. On Windows, add the directories printed by setup to your user PATH, then open a new terminal.

If the executable is missing, [install FVM](/getting-started/installation) again.

## The wrong fvm command runs

An old shell function, alias, or PATH entry may take priority. Run the installed executable by its full path with `doctor`, for example:

```sh
"$HOME/.fvm/bin/fvm" doctor
```

Remove the conflicting setup identified in the output, rerun setup, and open a new terminal.

## Flutter uses the wrong version

```sh
fvm which
fvm doctor
```

Check whether `FVM_FLUTTER_VERSION`, a parent `.fvmrc`, or your global default is selecting the version. Change the project version with `fvm use <version>`.

If `fvm flutter --version` is correct but `flutter --version` is not, repeat [Shell Setup](/getting-started/shell-setup). The FVM launcher must come first on PATH.

## The selected SDK is missing

Run the `fvm install` command printed in the error. For a new project checkout, run `fvm use <version>` with the version from `.fvmrc` to install it and create the editor link.

If FVM does not recognize `stable` or `beta`, install that channel first:

```sh
fvm install stable
fvm use stable
```

## A download fails

Check your network connection and proxy settings, then retry. FVM downloads its own updates from GitHub and Flutter SDKs from Google's Flutter storage.

For a damaged SDK, reinstall its version:

```sh
fvm install 3.44.0 --force
```

If the release is unavailable for your computer, use `fvm list-remote` to find a supported version. If a checksum mismatch persists, do not use that download.

## The editor uses another SDK

Run `fvm use <version>` again and set the editor's Flutter SDK path to `.fvm/flutter_sdk` beside `.fvmrc`. Restart the editor. See [Quick Start](/getting-started/quick-start) for the VS Code setting.

If Windows reports that it cannot create the SDK link, follow the error's instructions about permissions or Developer Mode, then rerun `fvm use`.

## Dart reports a different version

Use `fvm dart --version` to check the Dart bundled with your project's Flutter SDK. Plain `dart` may use a separate installation.

## Get more diagnostic output

```sh
fvm --verbose flutter --version
```

Use this alongside `fvm doctor` when you need more detail about a failure.
