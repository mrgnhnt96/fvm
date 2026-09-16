---
title: "Updating FVM"
description: "Update the manager separately from the Flutter SDKs it manages."
---

## Update the manager

```sh
fvm update
```

Official release builds can replace themselves using checksummed GitHub release assets. A source build does not self-update: pull the source and compile again, keeping the executable at the same path or rerunning setup after moving it.

## Refresh Flutter

```sh
fvm install stable
```

This refreshes the local stable-channel mapping. Projects pinned to a concrete version stay on that version; change their pin with `fvm use` when ready.

## Version notices

Release builds can show a newer-FVM notice. Use `--no-version-check` to disable that check for an invocation. Version notices concern the manager, not Flutter.
