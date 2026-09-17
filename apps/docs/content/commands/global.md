---
title: "fvm global"
description: "Choose the Flutter version used outside pinned projects."
---

## Set your default

```sh
fvm global 3.44.0
```

FVM installs the version if needed. Directories with a `.fvmrc` keep their project version; `FVM_FLUTTER_VERSION` also takes priority.

To use the current stable release:

```sh
fvm install stable
fvm global stable
```

This saves a specific version number. Repeat both commands when you want to update the default.

## Show your default

```sh
fvm global
```

To see what will run in your current directory, use [`fvm which`](/commands/which).
