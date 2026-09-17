---
title: "fvm list-remote"
description: "Find Flutter releases available for your computer."
---

## List stable releases

```sh
fvm list-remote
```

Shows the newest 25 stable releases available for your operating system and CPU architecture. This command requires a network connection.

## Choose a channel or show all releases

```sh
fvm list-remote --channel beta
fvm list-remote --all
fvm list-remote --channel dev --all
```

`--channel` (or `-c`) accepts `stable`, `beta`, or `dev`. `--all` includes older releases. Historical dev releases may be available; `main` and `master` builds are not supported.

## Install a listed release

Run `fvm use <version>` to install it and select it for your project, or `fvm install <version>` to download it without changing your project.
