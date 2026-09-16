---
title: "Quick Start"
description: "Install Flutter, pin a project, and run its bundled tools."
---

## Install and pin

From your project directory:

```sh
fvm install stable
fvm use stable --gitignore
fvm flutter --version
```

For a reproducible team pin, use a concrete release version instead of a moving channel:

```sh
fvm use 3.44.0 --gitignore
```

Commit `.fvmrc` and the `.gitignore` change. Keep `.fvm/` out of Git.

## Configure your editor

Point VS Code's `dart.flutterSdkPath` at `.fvm/flutter_sdk`. In Android Studio or IntelliJ, use that directory as the Flutter SDK path. The link changes when you select another version.

## Use the tools

```sh
fvm flutter pub get
fvm flutter test
fvm dart --version
fvm exec dart analyze
```

Run `fvm setup --write-path-line` and restart your shell to make plain `flutter` follow the pin. Run `fvm global stable` to select a fallback outside pinned projects.

## Clone another project

Read its `.fvmrc`, then install and select the version it names with `fvm use <version>`. FVM does not download an SDK during a normal Flutter invocation: missing versions produce an installation instruction.
