---
title: "fvm install"
description: "Download a Flutter SDK without changing your project\u2019s selected version."
---

## Install Flutter

```sh
fvm install stable
```

This downloads the current stable release. Select it for your project afterward with `fvm use stable`.

To download a particular version:

```sh
fvm install 3.44.0
```

Already installed versions are reused. Find available releases with [`fvm list-remote`](/commands/list-remote).

## Reinstall an SDK

```sh
fvm install 3.44.0 --force
```

Use `--force` (or `-f`) to replace an installed SDK, for example after its files are damaged.

## Install another channel or alias

You can pass `beta` or a saved alias instead of a version. Each `fvm install stable` or `fvm install beta` checks for that channel's current release. It does not change an existing project's version; run [`fvm use`](/commands/use) to do that.
