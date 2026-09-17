---
title: "Commands"
description: "Reference for all FVM commands and their options."
---

Run `fvm <command> --help` for usage. For `flutter`, `dart`, and `exec`, all following arguments—including `--help`—belong to the tool being run.

## fvm install

Download a Flutter SDK without changing your project pin.

```sh
fvm install stable
fvm install 3.44.0
fvm install 3.44.0 --force
```

Accepts a version, channel, or saved alias. Channels check for their current release. Already installed versions are reused; `--force` (`-f`) replaces them. Select the downloaded SDK with `fvm use`.

## fvm use

Choose a version for the current project.

```sh
fvm use 3.44.0 --gitignore
fvm install stable
fvm use stable
```

Installs a missing SDK, writes a concrete version to `.fvmrc`, and updates `.fvm/flutter_sdk`. Install a channel before selecting it.

- `--gitignore` adds `.fvm/` to the project’s `.gitignore`.
- `--here` creates a pin in this directory instead of updating the nearest parent pin.
- `--global` (`-g`) sets the global default instead of a project pin.

## fvm global

Set the default outside pinned projects, or show the current default.

```sh
fvm global 3.44.0
fvm global
```

Installs a missing SDK. For a channel, run `fvm install stable` before `fvm global stable`. Saves a concrete version number. Project pins and `FVM_FLUTTER_VERSION` take priority.

## fvm list

Show installed versions, project selection, global default, aliases, and channels.

```sh
fvm list
```

`fvm ls` is the same command.

## fvm list-remote

Find releases available for your operating system and CPU architecture.

```sh
fvm list-remote
fvm list-remote --channel beta --all
```

Requires a network connection. Defaults to the newest 25 stable releases. `--channel` (`-c`) accepts `stable`, `beta`, or `dev`; `--all` includes older releases.

## fvm remove

Delete an installed SDK to free disk space.

```sh
fvm remove 3.44.0
```

Check other projects before removing a shared version. If FVM reports references to the SDK, update those pins, defaults, or aliases first. `--force` (`-f`) removes it anyway and leaves those references in place. Reinstall it with `fvm install <version>` if needed.

## fvm alias

Save a shortcut for a version, or list saved names.

```sh
fvm alias work 3.44.0
fvm alias list
```

Creating an alias does not install an SDK. Run `fvm use work` to install and pin its version. Aliases can target channels or other aliases; avoid loops. Names are local to your computer.

## fvm unalias

Delete a saved name without deleting the SDK.

```sh
fvm unalias work
```

Concrete project pins keep working. Update any manually written pins or other aliases that refer to the removed name.

## fvm which

Explain the Flutter SDK selected for your current directory.

```sh
fvm which
fvm which --path
```

`--path` prints only the Flutter executable path for scripts. `fvm current` is another name for this command. See [resolution order](/versions#resolution-order).

## fvm flutter

Run Flutter using the selected SDK.

```sh
fvm flutter pub get
fvm flutter run
fvm flutter test
fvm flutter --help
```

Arguments and exit status pass through to Flutter. Install the selected SDK first; running Flutter does not download a missing SDK.

## fvm dart

Run the Dart bundled with the selected Flutter SDK.

```sh
fvm dart --version
fvm dart analyze
fvm dart format .
fvm dart run tool/generate.dart
```

Uses Flutter’s Dart even if another Dart SDK is on PATH. Arguments and exit status pass through to Dart.

## fvm exec

Run a tool or script with the selected Flutter and Dart first on PATH.

```sh
fvm exec dart analyze
fvm exec sh tool/check.sh
```

Replace the script path with your own. The command and tools it starts use the selected SDK. Your terminal’s PATH is unchanged afterward. All arguments belong to the child command; FVM returns its exit status.

## fvm setup

Create the Flutter launcher and configure your shell.

```sh
fvm setup
fvm setup --write-path-line
```

Plain setup prints PATH instructions. `--write-path-line` backs up and edits the shell startup file; reopen the terminal afterward. On Windows, edit user PATH manually.

- `--remove-path-line` removes the line setup added, leaving manual entries and SDKs in place.
- `--fvm-path=<path>` selects the FVM executable the launcher uses.

If `fvm` is not on PATH, use its full installed path. See [shell setup](/#shell-setup).

## fvm doctor

Check SDK selection, project pins, editor links, and shell conflicts.

```sh
fvm doctor
```

Run this from the affected project and follow the corrections it prints. To check platform build tools and devices, use `fvm flutter doctor`.

## fvm config

Read or save the color preference for FVM output.

```sh
fvm config color
fvm config color auto
```

Modes are `auto`, `always`, and `never`. Auto respects `NO_COLOR` and `TERM=dumb`. Override one invocation with `fvm --color=never list`. Flutter and Dart control their own output.

## fvm update

Update FVM while keeping installed SDKs and project pins.

```sh
fvm update --check
fvm update
```

`--check` reports availability without installing. Use `fvm update <version>` for a specific FVM release. See [updating](/updating) to update Flutter instead.
