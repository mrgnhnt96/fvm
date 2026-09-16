---
title: "fvm install"
description: "Download and verify a Flutter SDK."
---

## Usage

```sh
fvm install stable
fvm install 3.44.0
fvm install 3.44.0 --force
```

## Behavior

A channel fetches its current release and updates the local mapping. An already installed concrete version is reused unless `--force` is set. Downloads are verified against the manifest SHA-256 before extraction.

## Options

```text
Download, verify and install a Flutter SDK.

Usage: fvm install <version|channel|alias>
-h, --help     Print this usage information.
-f, --force    Reinstall even if the version is already present.

Run "fvm help" to see global options.
```
