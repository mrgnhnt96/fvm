---
title: "fvm unalias"
description: "Delete a saved name without deleting its Flutter SDK."
---

## Remove an alias

```sh
fvm unalias work
```

The SDK remains installed. Projects pinned to a concrete version keep working.

If you manually put this alias in `.fvmrc`, replace it by running `fvm use <version>`. Other aliases that refer to the removed name also need updating.

To remove the SDK itself, use [`fvm remove`](/commands/remove).
