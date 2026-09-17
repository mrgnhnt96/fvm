---
title: "fvm alias"
description: "Save a short name for a Flutter version."
---

## Create or change an alias

```sh
fvm alias work 3.44.0
fvm use work
```

The alias is saved on your computer. `fvm use work` writes the version number to `.fvmrc`, so teammates do not need to create the same alias.

Creating an alias does not install the SDK. Selecting it with `fvm use` installs the version if needed.

## List aliases

```sh
fvm alias list
```

An alias can also name a channel or another alias. Install a channel before using it, and avoid aliases that point back to each other.

Remove a name with [`fvm unalias`](/commands/unalias).
