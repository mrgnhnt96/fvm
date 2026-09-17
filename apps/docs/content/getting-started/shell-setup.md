---
title: "Shell Setup"
description: "Make the flutter command use your project\u2019s selected SDK."
---

## Enable the flutter command

Shell setup lets you type `flutter` instead of `fvm flutter`. If you already ran setup during installation and reopened your terminal, you can skip this step.

On macOS or Linux with the default installation:

```sh
"$HOME/.fvm/bin/fvm" setup --write-path-line
```

Setup backs up your shell startup file and adds the required PATH entries. Open a new terminal afterward.

On Windows, run `fvm setup` and add the printed directories to your user PATH in Environment Variables. See [Installation](/getting-started/installation) if `fvm` is not yet available.

## Check your setup

From a project where you have run `fvm use`:

```sh
flutter --version
fvm which
fvm doctor
```

FVM's launcher, called a shim, must come before other Flutter installations on PATH. If the wrong Flutter runs, follow the corrections printed by `fvm doctor`.

## Set up PATH manually

Run `fvm setup` to create the launcher and print the PATH instructions for your shell. Follow those instructions instead of using `--write-path-line` if you manage your startup file yourself.

Keep the FVM executable in its installed location. If you move it, run setup again using its new path.

## Run Dart

Use `fvm dart` for the Dart version included with your selected Flutter SDK:

```sh
fvm dart --version
```

Setup does not change plain `dart`. If you use DVM, see [Using FVM alongside DVM](/guides/dvm).

## Remove the automatic PATH change

```sh
fvm setup --remove-path-line
```

Open a new terminal afterward. This removes the line added by `--write-path-line`; it leaves manually added PATH entries, FVM, and your SDKs in place.
