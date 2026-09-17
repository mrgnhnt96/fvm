---
title: "Aliases and Channels"
description: "Choose a Flutter channel or save a short name for a version."
---

## Select a Flutter channel

```sh
fvm install stable
fvm use stable
```

Install the channel first so FVM knows which release to use. `fvm use stable` pins that release's version number in your project.

To move the project to a newer stable release, run both commands again. Installing a newer release by itself does not change the project's saved version.

You can also use `beta`. Historical `dev` releases are available when listed by `fvm list-remote --channel dev`. FVM does not install `main` or `master` builds.

## Save a name for a version

```sh
fvm alias work 3.44.0
fvm use work
```

`work` is a shortcut on your computer. `fvm use work` saves the version number in `.fvmrc`, so teammates do not need your alias.

List or remove your saved names:

```sh
fvm alias list
fvm unalias work
```

Removing an alias leaves the SDK installed.

## Use names in an existing pin

If you manually put a channel or alias in `.fvmrc`, FVM looks up its saved value on your computer. A channel does not fetch a newer release when you run Flutter; refresh it with `fvm install stable` or `fvm install beta`.

Prefer the version number written by `fvm use` when sharing a project.
