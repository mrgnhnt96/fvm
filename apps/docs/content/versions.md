---
title: "Managing Versions"
description: "Select Flutter with project pins, defaults, channels, and aliases."
---

## Project pins

From your project's root directory:

```sh
fvm use 3.44.0 --gitignore
```

FVM installs the version if needed, writes `.fvmrc`, and updates `.fvm/flutter_sdk` for your editor:

```json
{"flutter": "3.44.0"}
```

Commit `.fvmrc` and the `.gitignore` change; keep `.fvm/` out of Git. Teammates run `fvm use` with that version after cloning. See [editor setup](/#editor-setup).

### Nested projects

Commands use the nearest `.fvmrc` in your current directory or a parent. Running `fvm use` in a subdirectory updates that same pin.

To give a nested project its own version, run this from its root:

```sh
fvm use 3.44.0 --here --gitignore
```

### Existing .fvmrc formats

FVM also accepts a bare version on one line, or a JSON `flutter` value naming a channel or alias. Those names must be available on every computer. Prefer the concrete version number written by `fvm use` for shared projects.

## Channels and aliases

To select the current stable release:

```sh
fvm install stable
fvm use stable
```

Install the channel first so FVM knows its version. `use stable` saves the version number, so later channel updates do not move the project. Repeat both commands when you want to upgrade.

`beta` works the same way. Historical `dev` releases may appear in `fvm list-remote --channel dev`; `main` and `master` builds are not supported.

### Save a version shortcut

```sh
fvm alias work 3.44.0
fvm use work
fvm alias list
fvm unalias work
```

Aliases are local to your computer. `fvm use work` saves the version number in `.fvmrc`, so teammates do not need your alias. Removing the alias leaves the SDK installed.

If you manually put a channel or alias in `.fvmrc`, FVM uses its saved value on your computer. It does not fetch a new release when you run Flutter. Refresh a channel with `fvm install stable` or `fvm install beta`.

## Global default

Choose a version for directories without a project pin:

```sh
fvm global 3.44.0
```

FVM installs the version if needed. Run `fvm global` without an argument to view the default. To choose stable, run `fvm install stable` followed by `fvm global stable`; this also saves a specific version number.

## Resolution order

Run `fvm which` to see which SDK will run and why. FVM uses the first selection that applies:

1. The `FVM_FLUTTER_VERSION` environment variable.
2. The nearest `.fvmrc` in your current directory or a parent.
3. Your global default.
4. Another Flutter installation on PATH.

An invalid or missing explicit selection produces an error. Follow its correction or installation command; FVM does not substitute another version.

### Override a version temporarily

Install the version first. In a POSIX shell:

```sh
fvm install 3.44.0
FVM_FLUTTER_VERSION=3.44.0 fvm flutter test
```

In PowerShell:

```powershell
fvm install 3.44.0
$env:FVM_FLUTTER_VERSION = "3.44.0"
fvm flutter test
Remove-Item Env:FVM_FLUTTER_VERSION
```

The PowerShell variable lasts until you remove it. Neither example changes `.fvmrc`.

## Remove unused SDKs

```sh
fvm list
fvm remove 3.44.0
```

Projects share installed SDKs, so check your other projects before removing a version. FVM reports references it can detect but cannot discover every project on disk. See [removal options](/commands#fvm-remove).
