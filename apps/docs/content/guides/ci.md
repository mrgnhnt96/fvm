---
title: "Using FVM in CI"
description: "Install your project\u2019s Flutter version and run tests in CI."
---

## Install FVM and the project SDK

Commit `.fvmrc` with a concrete Flutter version. On a macOS or Linux runner, this example installs FVM, makes it available to the current shell, and tests a project pinned to `3.44.0`:

```sh
curl -fsSL https://raw.githubusercontent.com/mrgnhnt96/fvm/main/install.sh | sh
export PATH="${FVM_HOME:-$HOME/.fvm}/bin:$PATH"
fvm install 3.44.0
fvm flutter pub get
fvm flutter test
```

Replace `3.44.0` with the version in your project's `.fvmrc`. Run the Flutter commands from the checked-out project directory. For Windows runners, use the [Windows installation steps](/getting-started/installation).

Use your CI provider's environment or PATH mechanism if installation and testing run in separate steps. A shell's `export` may not carry over to the next step.

You do not need shell setup when invoking Flutter through `fvm flutter`. Use `fvm exec <command>` for scripts that call Flutter or Dart themselves.

## Reuse downloaded SDKs

Cache `$FVM_HOME/versions` (default: `~/.fvm/versions`) between jobs. Include the operating system, CPU architecture, and pinned Flutter version in the cache key. Keep the install command so a job also works with an empty cache.

## Test another Flutter version

Install the version before overriding the project pin. In a POSIX shell:

```sh
fvm install 3.44.0
FVM_FLUTTER_VERSION=3.44.0 fvm flutter test
```

A failing Flutter command returns a failing exit status to CI.
