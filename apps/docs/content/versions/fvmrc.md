---
title: "The .fvmrc File"
description: "Share your project\u2019s Flutter version with teammates."
---

## Create a project pin

From your project's root directory, run:

```sh
fvm use 3.44.0 --gitignore
```

FVM installs the SDK if needed and writes `.fvmrc`:

```json
{"flutter": "3.44.0"}
```

Commit `.fvmrc` and the `.gitignore` change. Teammates can run `fvm use 3.44.0` after cloning to install the same SDK and set up their editor link.

`fvm use stable` and `fvm use <alias>` also save a concrete version number. Install a channel with `fvm install stable` before selecting it.

## Use one version across nested directories

Commands in subdirectories use the nearest `.fvmrc` in that directory or a parent. Running `fvm use` from a subdirectory updates that same file.

To give a nested project its own version, run this from the nested project's root:

```sh
fvm use 3.44.0 --here --gitignore
```

## Connect your editor

Set your editor's Flutter SDK path to `.fvm/flutter_sdk` beside `.fvmrc`. FVM updates this link when you run `fvm use`.

Do not commit `.fvm/`: each computer creates its own link. See [Quick Start](/getting-started/quick-start) for editor settings.

## Read existing pins

FVM also accepts a bare version on one line, or a JSON `flutter` value naming a channel or alias. Those names must be available on each computer; concrete version numbers are simpler to share.

If a pin is invalid or its SDK is missing, follow the error's correction or installation command. FVM will not substitute your global version.
