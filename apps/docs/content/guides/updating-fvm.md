---
title: "Updating FVM"
description: "Update the manager separately from the Flutter SDKs it manages."
---

## Update the manager

```sh
fvm update
```

FVM replaces its executable using checksummed GitHub release assets. Your installed Flutter SDKs and project pins remain in place.

## Refresh Flutter

```sh
fvm install stable
```

This refreshes the local stable-channel mapping. Projects pinned to a concrete version stay on that version; change their pin with `fvm use` when ready.

## Version notices

Release builds can show a newer-FVM notice. Use `--no-version-check` to disable that check for an invocation. Version notices concern the manager, not Flutter.
