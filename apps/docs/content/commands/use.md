---
title: "fvm use"
description: "Choose a project\u2019s Flutter version and configure its editor SDK link."
---

## Select a version

From the project directory:

```sh
fvm use 3.44.0 --gitignore
```

FVM installs the version if needed, writes its number to `.fvmrc`, and creates `.fvm/flutter_sdk` for your editor. `--gitignore` adds `.fvm/` to the project's `.gitignore`.

Commit `.fvmrc` and the `.gitignore` change. See [Quick Start](/getting-started/quick-start) for editor settings.

## Select the current stable release

```sh
fvm install stable
fvm use stable
```

Install the channel first. `use stable` saves the installed channel's version number, so later channel updates do not move this project. Saved aliases also resolve to version numbers.

## Select a version for a nested project

By default, `use` updates the nearest existing `.fvmrc` in your current directory or a parent. To give the current directory its own pin:

```sh
fvm use 3.44.0 --here --gitignore
```

## Set a default instead

`fvm use <version> --global` (or `-g`) sets the fallback for directories without a project pin. It is equivalent to [`fvm global`](/commands/global).
