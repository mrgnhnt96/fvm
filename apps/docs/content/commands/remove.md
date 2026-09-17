---
title: "fvm remove"
description: "Free disk space by deleting an installed Flutter SDK."
---

## Remove an unused version

```sh
fvm list
fvm remove 3.44.0
```

All projects using a version share its SDK. Check your other projects before removing it: they will need that version installed again to run.

## If FVM refuses removal

Change the project pin, global default, or alias identified in the error, then retry. FVM can check local references but cannot find every project on your disk.

To remove the SDK even when references still point to it:

```sh
fvm remove 3.44.0 --force
```

`--force` (or `-f`) leaves those references in place. Repair affected projects with `fvm use <version>` or reinstall the removed version with `fvm install <version>`.
