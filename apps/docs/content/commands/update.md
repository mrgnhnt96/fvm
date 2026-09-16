---
title: "fvm update"
description: "Update the FVM executable from GitHub Releases."
---

## Usage

```sh
fvm update
```

## Behavior

Self-update is available for official release-built binaries. Source invocations and ordinary local builds do not perform ambient version checks. For a source build, pull the repository and compile again. See [Updating FVM](/guides/updating-fvm).

## Options

```text
Update fvm itself to the newest release.

Usage: fvm update [version]
-h, --help     Print this usage information.
    --check    Report whether a newer fvm exists, without installing anything.

Run "fvm help" to see global options.
```
