---
title: "Resolution Order"
description: "Find which Flutter version will run in your current directory."
---

## Check the selected version

```sh
fvm which
```

The output shows which Flutter SDK FVM selected and why. For only the executable path, use `fvm which --path`.

## How FVM chooses Flutter

FVM uses the first selection that applies:

1. `FVM_FLUTTER_VERSION`, if you set this environment variable.
2. The nearest `.fvmrc` in your current directory or a parent directory.
3. The default you set with `fvm global`.
4. Another Flutter installation on your PATH.

If none applies, install and select an SDK with `fvm use <version>`. If an explicit selection is invalid or missing, fix that selection; FVM does not skip it to use another SDK.

## Choose a default outside projects

```sh
fvm global 3.44.0
```

A project's `.fvmrc` still takes priority.

## Override the version for one command

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

The PowerShell variable applies to the session until you remove it. Neither example changes `.fvmrc`.

If plain `flutter` chooses a different SDK from `fvm flutter`, check [Shell Setup](/getting-started/shell-setup).
