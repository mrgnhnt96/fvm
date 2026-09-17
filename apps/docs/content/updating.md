---
title: "Updating"
description: "Update FVM and choose when projects move to a newer Flutter SDK."
---

## Update FVM

```sh
fvm update --check
fvm update
```

`--check` reports whether an update is available. `fvm update` installs it. Your Flutter SDKs and project pins stay in place.

You can also rerun the [installer](/#installation). To install a specific FVM release, use `fvm update <version>` with a version from [FVM releases](https://github.com/mrgnhnt96/fvm/releases).

## Update a project's Flutter SDK

From your project directory:

```sh
fvm install stable
fvm use stable
fvm flutter --version
fvm flutter pub get
fvm flutter test
```

The first command downloads the current stable release. The second updates `.fvmrc` and your editor's SDK link. Commit the changed `.fvmrc` after checking your app.

For a specific release, use `fvm use <version>` instead. Other projects keep their saved versions.

## Update the default for unpinned directories

```sh
fvm install stable
fvm global stable
```

## Hide FVM update notices

Use `--no-version-check` for a command where you do not want FVM update notices:

```sh
fvm --no-version-check flutter test
```
