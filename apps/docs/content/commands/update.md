---
title: "fvm update"
description: "Install a newer FVM release while keeping your SDKs and project pins."
---

## Check for an update

```sh
fvm update --check
```

Reports whether a newer FVM release is available without installing it.

## Update FVM

```sh
fvm update
```

To choose a specific FVM release, run `fvm update <version>` using a version from [FVM releases](https://github.com/mrgnhnt96/fvm/releases).

If updating fails, rerun the [installer](/getting-started/installation).

## Update Flutter instead

`fvm update` updates the manager. To move a project to a newer Flutter SDK, follow [Updating FVM and Flutter](/guides/updating-fvm).
